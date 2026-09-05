// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

/// What the app can navigate to from the source list. Every action here has a destination; the
/// screen shows no entry it cannot open.
public struct BrowseActions {
    public let openHome: (SourceId) -> Void
    public let openSearch: (SourceId) -> Void
    public let openRemoteLibrary: (SourceId) -> Void
    public let openSignIn: (SourceId) -> Void
    public let openExtensions: () -> Void

    public init(
        openHome: @escaping (SourceId) -> Void,
        openSearch: @escaping (SourceId) -> Void,
        openRemoteLibrary: @escaping (SourceId) -> Void,
        openSignIn: @escaping (SourceId) -> Void,
        openExtensions: @escaping () -> Void
    ) {
        self.openHome = openHome
        self.openSearch = openSearch
        self.openRemoteLibrary = openRemoteLibrary
        self.openSignIn = openSignIn
        self.openExtensions = openExtensions
    }
}

public struct BrowseScreen: View {
    @ObservedObject private var model: BrowseModel
    private let actions: BrowseActions

    public init(model: BrowseModel, actions: BrowseActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { rows in
            List(rows) { row in
                Section {
                    sourceRow(row)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("来源")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("扩展市场") { actions.openExtensions() }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func sourceRow(_ row: BrowseSourceRow) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Text(row.source.displayName)
                    .font(TsuyomiTheme.Typography.sectionTitle)
                Text(row.source.version.original)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                Spacer(minLength: 0)
                if !row.isAvailable {
                    TsuyomiStatusBadge("休眠", tone: .warning)
                } else if row.source.supportsWebLogin {
                    TsuyomiStatusBadge(row.isSignedIn ? "已登录" : "未登录", tone: row.isSignedIn ? .positive : .neutral)
                }
            }
            Text(row.source.summary)
                .font(TsuyomiTheme.Typography.caption)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)

            if row.source.supportsHome {
                TsuyomiNavigationCard(
                    title: "来源首页",
                    supporting: "浏览分类与栏目",
                    systemImage: "square.grid.2x2",
                    action: { actions.openHome(row.source.sourceId) }
                )
            }
            TsuyomiNavigationCard(
                title: "搜索",
                supporting: "在该来源内检索书名",
                systemImage: "magnifyingglass",
                action: { actions.openSearch(row.source.sourceId) }
            )
            if row.source.supportsRemoteRead {
                TsuyomiNavigationCard(
                    title: "网站收藏",
                    supporting: "只读拉取，复制到本地书架",
                    systemImage: "bookmark",
                    action: { actions.openRemoteLibrary(row.source.sourceId) }
                )
            }
            if row.source.supportsWebLogin {
                TsuyomiNavigationCard(
                    title: row.isSignedIn ? "重新登录" : "登录",
                    supporting: "在受控浏览器中由你本人完成",
                    systemImage: "person.badge.key",
                    action: { actions.openSignIn(row.source.sourceId) }
                )
            }
        }
        .padding(.vertical, 4)
    }
}
