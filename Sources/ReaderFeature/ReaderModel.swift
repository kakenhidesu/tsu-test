// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiReader
import TsuyomiSource
import TsuyomiUI

public struct ReaderContent {
    public let chapterTitle: String
    public let layout: ReaderTextLayout
    public let pageCount: Int
    public let hasPrevious: Bool
    public let hasNext: Bool
}

/// One book, one open chapter, one semantic position. Only the immediately adjacent chapters are
/// reachable from here; anything further is a directory choice, so paging can never start a
/// background walk of the whole book.
@MainActor
public final class ReaderModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<ReaderContent> = .loading
    @Published public private(set) var pageIndex = 0
    @Published public var isChromeVisible = false
    @Published public var isSettingsPresented = false
    @Published public var isDirectoryPresented = false
    @Published public var settings: ReaderSettings

    @Published public private(set) var chapters: [SourceChapter] = []

    public let bookTitle: String
    public let preview = ReaderPreviewController()

    public let identity: BookIdentity
    private let registry: SourceRegistry
    private let progressStore: ReadingProgressStore
    private let documents = ReaderDocumentCache()
    private let clock: () -> Date
    private let startChapterId: String
    private var chapterIndex = 0
    private var session: ReaderDocumentSession?
    private var textLayout: ReaderTextLayout?
    private var viewport: CGSize = .zero
    private var sessionEpoch: Int64 = 0
    private var layoutEpoch: Int64 = 0
    private var navigationEpoch: Int64 = 0
    private var lastFlushed: ReaderLocator?

    public init(
        identity: BookIdentity,
        bookTitle: String,
        startChapterId: String,
        settings: ReaderSettings,
        registry: SourceRegistry,
        progressStore: ReadingProgressStore,
        clock: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.bookTitle = bookTitle
        self.startChapterId = startChapterId
        self.settings = settings
        self.registry = registry
        self.progressStore = progressStore
        self.clock = clock
    }

    public var chapter: SourceChapter? {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
    }

    public var visiblePageIndex: Int { preview.previewPageIndex ?? pageIndex }

    /// The reader loads its own directory so a cold launch straight into a chapter still knows what
    /// the adjacent chapters are; the second read is served by the host cache.
    public func open() async {
        state = .loading
        do {
            let client = try await registry.client(for: try SourceId(identity.sourceId))
            if chapters.isEmpty {
                chapters = try await client.directory(remoteBookId: identity.remoteBookId).chapters
                chapterIndex = chapters.firstIndex { $0.chapterId == startChapterId } ?? 0
            }
            guard let chapter else {
                state = .failed(code: "CHAPTER_MISSING", detail: "这一章不在目录里。")
                return
            }
            let document = try await client.chapter(chapter, remoteBookId: identity.remoteBookId)
            documents.put(document)
            sessionEpoch += 1
            navigationEpoch += 1
            let stored = try? await progressStore.progress(identity)
            session = try ReaderDocumentSession(
                document: document,
                initialLocator: stored?.locator,
                initialPresentation: settings.flow,
                clock: clock
            )
            textLayout = try ReaderTextLayout(document: document, settings: settings)
            try relayout()
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法载入这一章。")
        }
    }

    public func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewport else { return }
        viewport = size
        try? relayout()
    }

    public func apply(_ updated: ReaderSettings) {
        settings = updated
        session?.switchPresentation(updated.flow)
        try? relayout()
    }

    public func tapped(_ zone: ReaderTapZone) {
        switch zone {
        case .toggleChrome: isChromeVisible.toggle()
        case .previous: step(-1)
        case .next: step(1)
        }
    }

    /// Paging past either end of a chapter moves to the neighbouring chapter and nowhere else.
    public func step(_ delta: Int) {
        guard let textLayout else { return }
        let next = pageIndex + delta
        if next < 0 {
            Task { await openAdjacent(-1) }
            return
        }
        if next >= textLayout.pages.count {
            Task { await openAdjacent(1) }
            return
        }
        move(toPage: next)
    }

    public func openAdjacent(_ delta: Int) async {
        let target = chapterIndex + delta
        guard chapters.indices.contains(target) else { return }
        await flush()
        chapterIndex = target
        pageIndex = 0
        await open()
    }

    public func open(chapterId: String) async {
        guard let target = chapters.firstIndex(where: { $0.chapterId == chapterId }),
              target != chapterIndex else { return }
        await flush()
        chapterIndex = target
        pageIndex = 0
        isDirectoryPresented = false
        await open()
    }

    public func beginScrub() {
        guard let session, let textLayout, let epochs = currentEpochs() else { return }
        var locators: [Int: ReaderLocator] = [:]
        for page in textLayout.pages.indices {
            guard let position = textLayout.position(atPageIndex: page),
                  let locator = try? session.locator(
                      atBlock: position.blockIndex,
                      characterOffset: position.characterOffset
                  ) else { continue }
            locators[page] = locator
        }
        try? preview.begin(epochs: epochs, locators: locators)
    }

    public func scrub(_ fraction: Double) {
        guard let textLayout, !textLayout.pages.isEmpty else { return }
        let last = textLayout.pages.count - 1
        let page = min(max(Int((fraction * Double(last)).rounded()), 0), last)
        try? preview.offer(pageIndex: page)
    }

    public func endScrub() {
        guard let epochs = currentEpochs() else {
            preview.cancel()
            return
        }
        guard let page = preview.release(epochs: epochs) else { return }
        move(toPage: page)
    }

    public func pageDrawn(_ index: Int) {
        guard let epochs = currentEpochs() else { return }
        try? preview.pageDrawn(index, epochs: epochs)
    }

    /// Persists the semantic position, measured from the page that is actually on screen rather than
    /// from the resolver's starting guess, so a restored position is exact even if nothing was paged.
    /// Called on chapter change, on leaving the reader, and when the scene leaves the foreground;
    /// nothing else writes progress, and nothing is written before a layout has committed.
    public func flush() async {
        guard let session, let textLayout,
              let position = textLayout.position(atPageIndex: pageIndex),
              let locator = try? session.locator(
                  atBlock: position.blockIndex,
                  characterOffset: position.characterOffset
              ),
              locator != lastFlushed,
              let progress = try? ReadingProgress(identity: identity, locator: locator) else { return }
        if (try? await progressStore.saveProgress(progress)) != nil {
            lastFlushed = locator
        }
    }

    private func move(toPage page: Int) {
        guard let session, let textLayout,
              let position = textLayout.position(atPageIndex: page) else { return }
        _ = try? session.navigateToBlock(position.blockIndex, characterOffset: position.characterOffset)
        navigationEpoch += 1
        pageIndex = page
    }

    private func relayout() throws {
        guard let session, let textLayout, viewport.width > 0, viewport.height > 0 else { return }
        layoutEpoch += 1
        _ = try textLayout.layout(width: viewport.width, height: viewport.height, settings: settings)
        preview.cancel()
        let position = session.position
        pageIndex = textLayout.page(
            forBlockIndex: position.blockIndex,
            characterOffset: position.characterOffset
        )?.index ?? 0
        state = .content(
            ReaderContent(
                chapterTitle: chapter?.title ?? session.document.title,
                layout: textLayout,
                pageCount: textLayout.pages.count,
                hasPrevious: chapterIndex > 0,
                hasNext: chapterIndex + 1 < chapters.count
            )
        )
    }

    private func currentEpochs() -> ReaderEpochs? {
        guard let session, let textLayout else { return nil }
        return try? ReaderEpochs(
            document: session.document.identity,
            documentRevision: session.document.revision,
            contentDigest: session.document.contentDigest,
            documentEpoch: 0,
            sessionEpoch: sessionEpoch,
            layoutKey: textLayout.layoutKey,
            layoutEpoch: layoutEpoch,
            navigationEpoch: navigationEpoch
        )
    }
}
