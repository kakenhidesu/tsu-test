// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

/// Everything the home screen draws for one loaded page, plus the pending selection the reader is
/// building. Selection is local until an explicit apply: changing a capsule never fetches.
public struct SourceHomeState: Sendable {
    public let page: SourceHomePage
    public let pendingFilters: [String: String]
    public let loadedCursors: [String]
}

@MainActor
public final class SourceHomeModel: ObservableObject {
    @Published public private(set) var state: TsuyomiScreenState<SourceHomeState> = .empty(
        title: "尚未载入",
        detail: "首页内容只在你明确要求时才会请求。"
    )
    @Published public private(set) var isBusy = false
    @Published public private(set) var pendingFilters: [String: String] = [:]

    private let sourceId: SourceId
    private let registry: SourceRegistry
    private var loaded: SourceHomePage?
    private var cursors: [String] = []

    public init(sourceId: SourceId, registry: SourceRegistry) {
        self.sourceId = sourceId
        self.registry = registry
    }

    /// The only place a home request is issued. Every caller is an explicit user action.
    public func load(cursor: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if cursor == nil { state = .loading }
        do {
            let client = try await registry.client(for: sourceId)
            let page = try await client.home(selectedFilters: pendingFilters, cursor: cursor)
            loaded = page
            if let cursor { cursors.append(cursor) } else { cursors = [] }
            state = .content(
                SourceHomeState(page: page, pendingFilters: pendingFilters, loadedCursors: cursors)
            )
        } catch {
            state = .failed(
                code: SafeErrorCode.of(error),
                detail: SourceFailureGuidance.detail(for: error, fallback: "无法载入来源首页。")
            )
        }
    }

    /// Records a capsule choice. It becomes a request only when `load` is called.
    public func select(filterId: String, optionValue: String) {
        pendingFilters[filterId] = optionValue
        if let loaded {
            state = .content(
                SourceHomeState(page: loaded, pendingFilters: pendingFilters, loadedCursors: cursors)
            )
        }
    }

    public func applyFeature(_ feature: SourceHomeFeature) async {
        pendingFilters = feature.selectedFilters
        await load()
    }

    public var hasPendingChanges: Bool {
        guard let loaded else { return !pendingFilters.isEmpty }
        return loaded.selectedFilters != pendingFilters
    }

    public var nextCursor: String? { loaded?.nextCursor }

}
