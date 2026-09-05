// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

public struct SearchResults: Sendable {
    public let query: String
    public let page: Int
    public let items: [SourceBookSummary]
    public let isStaleOffline: Bool
}

/// One session, one in-flight request, one result stream. A later submission always wins: results
/// belonging to an abandoned query are discarded rather than merged into the visible list.
@MainActor
public final class SearchModel: ObservableObject {
    @Published public var query: String = ""
    @Published public private(set) var state: TsuyomiScreenState<SearchResults> = .empty(
        title: "输入书名开始搜索",
        detail: "搜索只在你提交时才会发出请求。"
    )
    @Published public private(set) var isBusy = false
    @Published public private(set) var history: [String] = []

    private let sourceId: SourceId
    private let registry: SourceRegistry
    private let library: LibraryRepository
    private let clock: () -> Date
    private var generation = 0
    private var submitted = ""

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

    public func loadHistory() async {
        history = (try? await library.searchHistory(sourceId: sourceId.value)) ?? []
    }

    public func submit() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submitted = trimmed
        await run(page: 1)
    }

    public func loadPage(_ page: Int) async {
        guard !submitted.isEmpty, page >= 1 else { return }
        await run(page: page)
    }

    public func useHistory(_ value: String) async {
        query = value
        await submit()
    }

    public func clearHistory() async {
        try? await library.clearSearchHistory(sourceId: sourceId.value)
        history = []
    }

    private func run(page: Int) async {
        generation += 1
        let current = generation
        let term = submitted
        isBusy = true
        state = .loading
        do {
            let client = try await registry.client(for: sourceId)
            let items = try await client.search(query: term, page: page)
            guard current == generation else { return }
            try? await library.recordSearch(sourceId: sourceId.value, query: term, at: clock())
            await loadHistory()
            guard current == generation else { return }
            publish(term: term, page: page, items: items, stale: false)
        } catch let failure as SourceException where failure.code == .networkOffline {
            await fallBackOffline(term: term, page: page, current: current)
        } catch {
            guard current == generation else { return }
            state = .failed(code: SafeErrorCode.of(error), detail: "搜索没有完成。")
        }
        if current == generation { isBusy = false }
    }

    /// Offline results come from the host cache and are labelled stale; they are never presented as
    /// a fresh answer to the query.
    private func fallBackOffline(term: String, page: Int, current: Int) async {
        guard current == generation else { return }
        do {
            let client = try await registry.client(for: sourceId)
            let items = try await client.search(query: term, page: page, offlineOnly: true)
            guard current == generation else { return }
            publish(term: term, page: page, items: items, stale: true)
        } catch {
            guard current == generation else { return }
            state = .offline(detail: "没有可用的离线结果。")
        }
    }

    private func publish(term: String, page: Int, items: [SourceBookSummary], stale: Bool) {
        guard !items.isEmpty else {
            state = .empty(title: "没有匹配的结果", detail: "换一个关键词再试。")
            return
        }
        state = .content(
            SearchResults(query: term, page: page, items: items, isStaleOffline: stale)
        )
    }
}
