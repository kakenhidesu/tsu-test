// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public struct BookDetailState: Sendable {
    public let detail: SourceBookDetail
    public let chapters: [SourceChapter]
    public let isStaleOffline: Bool
    public let inLibrary: Bool
    public let readLater: Bool
    public let resumeChapterId: String?
    public let readChapterIds: Set<String>
}

/// The detail page and its directory are one screen backed by one identity. Everything it writes is
/// local: `加入书架` never reaches the site, whatever the source declares.
@MainActor
public final class BookModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<BookDetailState> = .loading
    @Published public private(set) var isBusy = false
    @Published public var isDescending = false

    public let identity: BookIdentity
    private let registry: SourceRegistry
    private let library: LibraryRepository
    private let progressStore: ReadingProgressStore
    private let clock: () -> Date
    private var detail: SourceBookDetail?
    private var chapters: [SourceChapter] = []
    private var stale = false

    public init(
        identity: BookIdentity,
        registry: SourceRegistry,
        library: LibraryRepository,
        progressStore: ReadingProgressStore,
        clock: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.registry = registry
        self.library = library
        self.progressStore = progressStore
        self.clock = clock
    }

    public func load(offlineOnly: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        state = .loading
        do {
            let client = try await registry.client(for: try SourceId(identity.sourceId))
            detail = try await client.detail(
                remoteBookId: identity.remoteBookId,
                offlineOnly: offlineOnly
            )
            chapters = try await client.directory(
                remoteBookId: identity.remoteBookId,
                offlineOnly: offlineOnly
            ).chapters
            stale = offlineOnly
            try? await library.recordBrowsingVisit(identity, at: clock())
            await publish()
        } catch let failure as SourceException where failure.code == .networkOffline && !offlineOnly {
            await load(offlineOnly: true)
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法载入这本书的信息。")
        }
    }

    /// Local shelf write. There is no remote counterpart on this path by construction.
    public func addToLibrary() async {
        guard let detail, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let now = clock()
        do {
            _ = try await library.addToLibrary(
                LibraryBook(
                    identity: detail.summary.identity,
                    title: detail.summary.title,
                    addedAt: now,
                    metadataUpdatedAt: now,
                    authors: detail.summary.author.map { [$0] } ?? [],
                    coverUrl: detail.summary.coverUrl,
                    canonicalUrl: detail.summary.canonicalUrl,
                    status: detail.status,
                    remoteTags: Set(detail.tags)
                )
            )
            await publish()
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法写入本地书架。")
        }
    }

    public func removeFromLibrary() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        _ = try? await library.removeFromLibrary(identity)
        await publish()
    }

    public func toggleReadLater() async {
        guard let entry = try? await library.libraryEntry(identity) else { return }
        try? await library.setReadLater(identity, readLater: !entry.readLater)
        await publish()
    }

    private func publish() async {
        guard let detail else { return }
        let entry = try? await library.libraryEntry(identity)
        let progress = try? await progressStore.progress(identity)
        state = .content(
            BookDetailState(
                detail: detail,
                chapters: chapters,
                isStaleOffline: stale,
                inLibrary: entry != nil,
                readLater: entry?.readLater ?? false,
                resumeChapterId: progress?.locator.document.contentId,
                readChapterIds: readChapterIds(upTo: progress?.locator.document.contentId)
            )
        )
    }

    /// Everything before the furthest recorded position counts as read; the app keeps one position
    /// per book, so a per-chapter read flag would be a second, disagreeing source of truth.
    private func readChapterIds(upTo contentId: String?) -> Set<String> {
        guard let contentId, let index = chapters.firstIndex(where: { $0.chapterId == contentId }) else {
            return []
        }
        return Set(chapters[..<index].map(\.chapterId))
    }
}
