// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiSource
import TsuyomiUI

/// The mirror of a site's shelf. Opening it costs nothing; the toolbar's refresh is the one read.
public struct RemoteLibraryScreen: View {
    @ObservedObject private var model: RemoteLibraryModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openBook: (BookIdentity) -> Void
    private let openSignIn: (SourceId) -> Void
    private let openFolder: (SourceId, String) -> Void

    public init(
        model: RemoteLibraryModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void,
        openSignIn: @escaping (SourceId) -> Void,
        openFolder: @escaping (SourceId, String) -> Void = { _, _ in }
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
        self.openSignIn = openSignIn
        self.openFolder = openFolder
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.refresh() } }) { content in
            List {
                if model.targetId == nil, content.grouped, !content.liveTargets.isEmpty {
                    Section("网站分类") {
                        ForEach(content.liveTargets, id: \.targetId) { target in
                            Button {
                                openFolder(model.sourceId, target.targetId)
                            } label: {
                                HStack {
                                    Text(target.displayName)
                                    Spacer()
                                    Text("\(RemoteMirrorTargets.items(in: content.mirror, targetId: target.targetId).count)")
                                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(content.items, id: \.identity) { item in
                        row(item)
                    }
                } header: {
                    Text(subtitle(content))
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top) { noticeBanner }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .alert("复制网站收藏到本地书架", isPresented: Binding(
            get: { model.pendingCopy != nil },
            set: { if !$0 { model.cancelCopy() } }
        )) {
            Button("确认复制到本地书架") { Task { await model.confirmCopy() } }
            Button("取消", role: .cancel) { model.cancelCopy() }
        } message: {
            Text("只写本地书架：网站上的收藏不会被改动。之后从这个来源复制时不再询问。")
        }
        .alert("授权远端回写操作", isPresented: Binding(
            get: { model.pendingAuthorization != nil },
            set: { if !$0 { model.cancelPendingAction() } }
        )) {
            Button("授权并执行") { Task { await model.authorizePendingAction() } }
            Button("取消", role: .cancel) { model.cancelPendingAction() }
        } message: {
            Text(authorizationText(model.pendingAuthorization?.operation))
        }
        .confirmationDialog("从网站收藏移除", isPresented: Binding(
            get: { model.pendingRemoveConfirmation != nil },
            set: { if !$0 { model.cancelPendingAction() } }
        ), titleVisibility: .visible) {
            Button("移除", role: .destructive) { Task { await model.confirmRemove() } }
            Button("取消", role: .cancel) { model.cancelPendingAction() }
        } message: {
            Text("确定要从网站收藏中移除《\(pendingRemovalTitle)》吗？此操作只修改网站收藏；本地书架、稍后再读、评分、标签和阅读进度均保留。")
        }
        .task { await model.load() }
    }

    private var title: String {
        if let targetId = model.targetId, let target = model.content?.target(targetId) { return target.displayName }
        return model.content?.grouped == true ? (model.content?.mirror.binding.displayName ?? "网站收藏") : "网站收藏"
    }

    private func subtitle(_ content: RemoteMirrorContent) -> String {
        if model.targetId != nil || content.grouped {
            return "\(content.mirror.binding.displayName) · \(content.items.count) 本"
        }
        return "网站收藏 · 共 \(content.items.count) 项"
    }

    private var pendingRemovalTitle: String {
        guard let action = model.pendingRemoveConfirmation else { return "" }
        return model.content?.books[action.identity]?.title ?? ""
    }

    private func authorizationText(_ operation: RemoteWriteOperation?) -> String {
        let verb: String
        switch operation {
        case .add?: verb = "加入"
        case .move?: verb = "移动"
        case .remove?, nil: verb = "删除"
        }
        return "这个来源将以你的登录身份在网站上执行远端书架\(verb)操作。是否授权并继续？"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("刷新列表", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    model.cycleLayout()
                } label: {
                    Label("切换布局", systemImage: "square.grid.2x2")
                }
                if model.supportsGrouping || model.isGroupingEnabled {
                    Button {
                        Task { await model.setGrouping(!model.isGroupingEnabled) }
                    } label: {
                        Label(model.isGroupingEnabled ? "停用网站分组" : "启用网站分组", systemImage: "folder")
                    }
                }
                Button {
                    Task { await model.copyAllToLibrary() }
                } label: {
                    Label("全部复制到本地书架", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(model.content == nil || model.isBusy)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = model.notice {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Text(noticeText(notice))
                    .font(TsuyomiTheme.Typography.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch notice {
                case .loginRequired, .verificationRequired:
                    Button("前往登录验证") { openSignIn(model.sourceId) }
                case .cancelled, .failed:
                    Button("重试读取") { Task { await model.refresh() } }
                case .copied, .mutation:
                    Button("关闭") { model.dismissNotice() }
                }
            }
            .font(TsuyomiTheme.Typography.caption)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
            .background(.bar)
        }
    }

    private func noticeText(_ notice: RemoteMirrorNotice) -> String {
        switch notice {
        case .loginRequired: return "网站要求登录后才能读取收藏。"
        case .verificationRequired: return "网站要求先完成验证。"
        case .cancelled: return "读取已取消。"
        case .copied(let count): return "已复制 \(count) 本到本地书架。"
        case .failed(let code): return "读取失败：\(code)"
        case .mutation(let operation, let result):
            let verb = operation == .remove ? "移除" : "移动"
            switch result {
            case .confirmed: return "\(verb)已完成。"
            case .unresolved: return "\(verb)结果待确认。"
            case .cancelled: return "\(verb)已取消。"
            case .consentRequired: return "\(verb)需要授权。"
            case .loginRequired: return "网站要求登录后才能\(verb)。"
            case .verificationRequired: return "网站要求先完成验证。"
            case .failure(let failure, let code):
                return "\(verb)失败：\(failure == .sourceFailure ? code : failure.rawValue)"
            }
        }
    }

    private func row(_ item: RemoteMirrorItem) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.gutter) {
            Button {
                model.toggle(item.identity)
            } label: {
                Image(systemName: model.selected.contains(item.identity) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(TsuyomiTheme.Palette.accent)
                    .frame(
                        minWidth: TsuyomiTheme.Metrics.minimumTouchTarget,
                        minHeight: TsuyomiTheme.Metrics.minimumTouchTarget
                    )
            }
            .buttonStyle(.plain)
            if let summary = model.summary(item) {
                CoverImage(coverState(summary))
                    .frame(width: 44)
            }
            Button {
                openBook(item.identity)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.content?.book(item)?.title ?? item.identity.remoteBookId)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    if let author = model.content?.book(item)?.author {
                        Text(author)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let content = model.content, !content.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !model.selected.isEmpty {
                    Text("已选择 \(model.selected.count) 项 · 批量复制；网站移动/移除仅限单本")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
                HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                    Button(model.selected.count == content.items.count ? "取消全选" : "全选") {
                        model.selected.count == content.items.count ? model.clearSelection() : model.selectAll()
                    }
                    Spacer()
                    Button("复制所选到本地书架") { Task { await model.copySelectedToLibrary() } }
                        .disabled(model.selected.isEmpty || model.isBusy)
                    if model.singleSelection != nil, content.grouped, !content.liveTargets.isEmpty {
                        Menu("移至网站分类") {
                            ForEach(content.liveTargets, id: \.targetId) { target in
                                Button(target.displayName) { Task { await model.requestMoveSelected(to: target) } }
                            }
                        }
                        .disabled(model.isBusy)
                    }
                    if model.singleSelection != nil {
                        Button("从网站收藏移除", role: .destructive) { Task { await model.requestRemoveSelected() } }
                            .disabled(model.isBusy)
                    }
                }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
            .background(.bar)
        }
    }
}
