// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public struct RemoteLibraryState: Sendable {
    public let items: [SourceBookSummary]
    public let nextCursor: String?
    public let complete: Bool
}

/// Reading a site's own shelf is a read. Copying entries into the local library writes only to this
/// device: nothing on this screen can produce a remote write, which is why it needs no add token.
@MainActor
public final class RemoteLibraryModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<RemoteLibraryState> = .empty(
        title: "尚未拉取",
        detail: "网站收藏只在你明确要求时才会请求，且永远只读。"
    )
    @Published public private(set) var isBusy = false
    @Published public private(set) var selected: Set<BookIdentity> = []
    @Published public private(set) var copiedCount = 0

    private let sourceId: SourceId
    private let registry: SourceRegistry
    private let library: LibraryRepository
    private let clock: () -> Date
    private var items: [SourceBookSummary] = []

    public init(
        sourceId: SourceId,
        registry: SourceRegistry,
        library: LibraryRepository,
        clock: @escaping () -> Date = Date.init
    ) {
        self.sourceId = sourceId
        self.registry = registry
        self.library = library
        self.clock = clock
    }

    public func load(cursor: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if cursor == nil {
            state = .loading
            items = []
        }
        do {
            let client = try await registry.client(for: sourceId)
            let page = try await client.listRemoteLibrary(cursor: cursor)
            items.append(contentsOf: page.items)
            state = .content(
                RemoteLibraryState(items: items, nextCursor: page.nextCursor, complete: page.complete)
            )
        } catch let failure as SourceException {
            state = .failed(code: failure.code.rawValue, detail: "无法读取网站收藏。")
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法读取网站收藏。")
        }
    }

    public func toggle(_ identity: BookIdentity) {
        if selected.contains(identity) {
            selected.remove(identity)
        } else {
            selected.insert(identity)
        }
    }

    public func selectAll() {
        selected = Set(items.map(\.identity))
    }

    public func clearSelection() {
        selected = []
    }

    /// Copies into the local library only. `加入书架` is unconditionally local (§2 invariants).
    public func copySelectedToLibrary() async {
        await copy(items.filter { selected.contains($0.identity) })
    }

    public func copyAllToLibrary() async {
        await copy(items)
    }

    private func copy(_ summaries: [SourceBookSummary]) async {
        guard !summaries.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        let now = ProtocolTimestamp.now(clock())
        var added = 0
        do {
            for summary in summaries {
                let inserted = try await library.addToLibrary(
                    LibraryBook(
                        identity: summary.identity,
                        title: summary.title,
                        addedAt: now,
                        metadataUpdatedAt: now,
                        authors: summary.author.map { [$0] } ?? [],
                        coverUrl: summary.coverUrl,
                        canonicalUrl: summary.canonicalUrl
                    )
                )
                if inserted { added += 1 }
            }
            copiedCount = added
            selected = []
        } catch {
            state = .failed(code: SafeErrorCode.of(error), detail: "无法写入本地书架。")
        }
    }
}
