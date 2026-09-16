// SPDX-License-Identifier: AGPL-3.0-only

import ExtensionsFeature
import SwiftUI
import TsuyomiCore
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
    public let openRepositories: () -> Void
    public let openPublisherKeys: () -> Void

    public init(
        openHome: @escaping (SourceId) -> Void,
        openSearch: @escaping (SourceId) -> Void,
        openRemoteLibrary: @escaping (SourceId) -> Void,
        openSignIn: @escaping (SourceId) -> Void,
        openRepositories: @escaping () -> Void,
        openPublisherKeys: @escaping () -> Void
    ) {
        self.openHome = openHome
        self.openSearch = openSearch
        self.openRemoteLibrary = openRemoteLibrary
        self.openSignIn = openSignIn
        self.openRepositories = openRepositories
        self.openPublisherKeys = openPublisherKeys
    }
}

public enum BrowseSegment: String, CaseIterable, Hashable, Sendable {
    case installed
    case available

    public var title: LocalizedStringKey {
        switch self {
        case .installed: return "已安装"
        case .available: return "可安装"
        }
    }
}

/// The source tab: what is installed and what could be. Entering 可安装 reads caches; only the
/// refresh control reaches a repository, and only an approval installs anything.
public struct BrowseScreen: View {
    @ObservedObject private var model: BrowseModel
    @ObservedObject private var catalog: CatalogModel
    @ObservedObject private var market: ExtensionsModel
    private let actions: BrowseActions
    @State private var segment: BrowseSegment = .installed
    @State private var isImporting = false
    @State private var detail: BrowseSourceRow?
    @State private var uninstalling: BrowseSourceRow?

    public init(
        model: BrowseModel,
        catalog: CatalogModel,
        market: ExtensionsModel,
        actions: BrowseActions,
        initialSegment: BrowseSegment = .installed
    ) {
        self.model = model
        self.catalog = catalog
        self.market = market
        self.actions = actions
        _segment = State(initialValue: initialSegment)
    }

    public var body: some View {
        Group {
            if let pending = market.pendingPublisherKey {
                PublisherKeyCard(pending: pending, model: market)
            } else {
                content
            }
        }
        .background {
            ArchivePicker(isPresented: $isImporting) { url in
                Task { await market.importPackage(at: url) }
            }
        }
        .navigationTitle("来源")
        .toolbar { toolbar }
        .sheet(item: $detail) { row in InstalledSourceDetailSheet(row: row) }
        .sheet(isPresented: Binding(
            get: { market.pendingInstall != nil || catalog.pendingInstall != nil },
            set: { presented in
                guard !presented else { return }
                market.discardPendingInstall()
                catalog.discardPendingInstall()
            }
        )) {
            if let pending = market.pendingInstall {
                InstallReviewScreen(
                    prepared: pending.prepared,
                    consent: $market.installConsent,
                    isBusy: market.isBusy,
                    onApprove: { Task { await market.approvePendingInstall(); await model.load() } },
                    onCancel: { market.discardPendingInstall() }
                )
            } else if let prepared = catalog.pendingInstall {
                InstallReviewScreen(
                    prepared: prepared,
                    consent: $catalog.installConsent,
                    isBusy: catalog.isBusy,
                    onApprove: { Task { await catalog.approvePendingInstall(); await model.load() } },
                    onCancel: { catalog.discardPendingInstall() }
                )
            }
        }
        .confirmationDialog("卸载此来源？", isPresented: Binding(
            get: { uninstalling != nil },
            set: { if !$0 { uninstalling = nil } }
        ), titleVisibility: .visible) {
            Button("卸载来源", role: .destructive) {
                guard let row = uninstalling else { return }
                uninstalling = nil
                Task {
                    await market.uninstall(row.source.sourceId)
                    await model.load()
                    await catalog.loadCached()
                }
            }
            Button("取消", role: .cancel) { uninstalling = nil }
        } message: {
            Text("卸载“\(uninstalling?.source.displayName ?? "")”后，书架中的书籍与阅读进度会保留；该来源的在线内容将暂时不可用。")
        }
        .task {
            await model.load()
            await catalog.loadCached()
        }
        .onChange(of: segment) { selected in
            guard selected == .available, catalog.status == .idle, market.pendingInstall == nil else { return }
            Task { await catalog.refresh() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            SegmentedSelector(
                label: "来源分区",
                options: BrowseSegment.allCases.map { (value: $0, title: $0.title) },
                selection: $segment
            )
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
            banners
            switch segment {
            case .installed: installed
            case .available: available
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let status = market.importStatus {
            notice(status, tone: .neutral)
        }
        if let code = market.failureCode {
            notice("上一步没有完成（\(code)）。", tone: .danger)
        }
        if let failed = catalog.installFailure {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Text(failed.failure.message)
                    .font(TsuyomiTheme.Typography.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch failed.failure.kind {
                case .download:
                    Button("重试下载") { Task { await catalog.retryFailedInstall() } }
                case .repository:
                    Button("返回目录") { catalog.dismissInstallFailure() }
                case .verification, .storage, .install, .fileAccess:
                    Button("关闭") { catalog.dismissInstallFailure() }
                }
            }
            .font(TsuyomiTheme.Typography.caption)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
        }
    }

    private func notice(_ text: String, tone: TsuyomiStatusTone) -> some View {
        Text(text)
            .font(TsuyomiTheme.Typography.caption)
            .foregroundStyle(tone == .danger ? TsuyomiTheme.Palette.danger : TsuyomiTheme.Palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    isImporting = true
                } label: {
                    Label("导入内容源包", systemImage: "square.and.arrow.down")
                }
                Button {
                    actions.openRepositories()
                } label: {
                    Label("管理仓库", systemImage: "tray.full")
                }
                Button {
                    actions.openPublisherKeys()
                } label: {
                    Label("发布者", systemImage: "person.badge.key")
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .disabled(market.isBusy)
        }
    }

    // MARK: Installed

    private var installed: some View {
        StateView(installedState, retry: { Task { await model.load() } }) { rows in
            List(rows) { row in
                installedRow(row)
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.load() }
        }
    }

    /// The empty state names the one thing that always works without a repository: a local import.
    private var installedState: TsuyomiScreenState<[BrowseSourceRow]> {
        if case .empty = model.state {
            return .empty(title: "尚无可用内容源", detail: "从“可安装”里安装一个，或导入内容源包。")
        }
        return model.state
    }

    private func installedRow(_ row: BrowseSourceRow) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.source.displayName)
                    .font(TsuyomiTheme.Typography.body)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    .lineLimit(2)
                HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                    Text(row.source.version.original)
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    if !row.isAvailable {
                        TsuyomiStatusBadge("休眠", tone: .warning)
                    } else if row.source.supportsWebLogin {
                        TsuyomiStatusBadge(row.isSignedIn ? "已登录" : "未登录", tone: row.isSignedIn ? .positive : .neutral)
                    }
                }
            }
            Spacer(minLength: TsuyomiTheme.Metrics.tightGutter)
            HStack(spacing: 0) {
                Button("进入") { enter(row) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!row.isAvailable)
                Menu {
                    Button {
                        actions.openSearch(row.source.sourceId)
                    } label: {
                        Label("搜索此来源", systemImage: "magnifyingglass")
                    }
                    if row.source.supportsRemoteRead {
                        Button {
                            actions.openRemoteLibrary(row.source.sourceId)
                        } label: {
                            Label("网站收藏", systemImage: "bookmark")
                        }
                    }
                    if row.source.supportsWebLogin {
                        Button {
                            actions.openSignIn(row.source.sourceId)
                        } label: {
                            Label(row.isSignedIn ? "重新登录" : "登录", systemImage: "person.badge.key")
                        }
                    }
                    Button {
                        detail = row
                    } label: {
                        Label("来源详情", systemImage: "info.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        uninstalling = row
                    } label: {
                        Label("卸载来源", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作：\(row.source.displayName)")
            }
        }
        .padding(.vertical, 4)
    }

    private func enter(_ row: BrowseSourceRow) {
        if row.source.supportsHome {
            actions.openHome(row.source.sourceId)
        } else {
            actions.openSearch(row.source.sourceId)
        }
    }

    // MARK: Available

    private var available: some View {
        List {
            Section {
                Button {
                    actions.openRepositories()
                } label: {
                    Label("管理仓库", systemImage: "tray.full")
                }
                catalogNotice
            }
            if catalog.filtered.isEmpty {
                Section {
                    Text(catalog.hasRepositories ? "目录里没有匹配的来源。" : "暂无可用插件仓库。可添加仓库订阅，已安装来源和本地导入仍可使用。")
                        .font(TsuyomiTheme.Typography.supporting)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            } else {
                Section("来源目录") {
                    ForEach(catalog.filtered) { item in
                        catalogRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $catalog.query, prompt: "搜索来源目录")
        .refreshable { await catalog.refresh() }
    }

    @ViewBuilder
    private var catalogNotice: some View {
        switch catalog.status {
        case .loading:
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                ProgressView()
                Text("正在读取仓库目录…")
            }
            .font(TsuyomiTheme.Typography.caption)
            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        case .failed(let code):
            HStack {
                Text("读取目录失败（\(code)）。")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.danger)
                Spacer()
                Button("重试") { Task { await catalog.refresh() } }
            }
        case .unavailable:
            HStack {
                Text(catalog.isStale ? "当前显示的是可能已过期的已验证目录。" : "仓库目录暂不可用。")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.warning)
                Spacer()
                Button("刷新") { Task { await catalog.refresh() } }
            }
        case .idle, .ready:
            if catalog.isStale {
                Text("当前显示的是可能已过期的已验证目录。")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.warning)
            }
        }
    }

    private func catalogRow(_ item: CatalogItem) -> some View {
        HStack(alignment: .center, spacing: TsuyomiTheme.Metrics.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.package.displayName)
                    .font(TsuyomiTheme.Typography.body)
                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                Text("\(item.package.version.original) · \(item.package.language) · \(item.repositoryName)")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                Text(item.package.summary)
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: TsuyomiTheme.Metrics.tightGutter)
            catalogAction(item)
        }
        .padding(.vertical, 4)
    }

    /// One control, whose label says why it does what it does.
    @ViewBuilder
    private func catalogAction(_ item: CatalogItem) -> some View {
        if catalog.preparing == item.id {
            Button("正在准备") {}
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(true)
        } else if !item.isInstallable {
            Button("仓库暂不可用") {}
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(true)
        } else {
            switch item.status {
            case .incompatible:
                Button("不兼容") {}
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(true)
            case .revoked:
                Button("已撤销") {}
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(true)
            case .available:
                Button("安装") { Task { await catalog.prepare(item) } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!catalog.installationAllowed)
            case .updatable:
                Button("更新") { Task { await catalog.prepare(item) } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(!catalog.installationAllowed)
            case .installed:
                Button("已安装") {}
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(true)
            }
        }
    }
}
