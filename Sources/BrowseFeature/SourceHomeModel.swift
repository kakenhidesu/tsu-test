// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
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
        } catch let failure as SourceException {
            state = .failed(code: failure.code.rawValue, detail: detail(for: failure.code))
        } catch {
            state = .failed(code: BrowseModel.safeCode(error), detail: "无法载入来源首页。")
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

    private func detail(for code: SourceErrorCode) -> LocalizedStringKey {
        switch code {
        case .sessionRequired: return "需要先在受控浏览器中登录。"
        case .verificationRequired: return "站点要求人工验证，请在受控浏览器中完成。"
        case .networkOffline: return "当前离线，只显示已缓存的内容。"
        default: return "来源返回的页面无法解析。"
        }
    }
}
