// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiUI

public struct BookScreen: View {
    @ObservedObject private var model: BookModel
    @ObservedObject private var remote: BookRemoteShelfModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openChapter: (SourceChapter) -> Void
    private let openAuthorSearch: ((String) -> Void)?
    @State private var isSummaryExpanded = false
    @State private var isConfirmingLocalRemoval = false

    public init(
        model: BookModel,
        remote: BookRemoteShelfModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openChapter: @escaping (SourceChapter) -> Void,
        openAuthorSearch: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.remote = remote
        self.coverState = coverState
        self.openChapter = openChapter
        self.openAuthorSearch = openAuthorSearch
    }

    /// A plain list, not grouped cards: the directory is the body of this screen and everything above
    /// it is a masthead, so the chapters read as one continuous run rather than as a boxed section.
    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            List {
                if let banner = remote.banner {
                    Section { remoteBanner(banner) }
                } else if let continuation = remote.state?.pendingContinuation {
                    Section {
                        HStack {
                            Text("已加入默认书架，目标移动尚未完成")
                                .font(TsuyomiTheme.Typography.caption)
                            Spacer()
                            Button("继续移至\(continuation.targetName ?? continuation.targetId)") {
                                Task { await remote.moveOnWebsite(targetId: continuation.targetId, targetName: continuation.targetName) }
                            }
                            .disabled(remote.isBusy)
                        }
                    }
                }
                Section {
                    masthead(content)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .padding(.vertical, TsuyomiTheme.Metrics.tightGutter)
                }
                Section {
                    ForEach(ordered(content), id: \.chapterId) { chapter in
                        chapterRow(chapter, content: content)
                    }
                } header: {
                    directoryHeader(content)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { overflow }
        .confirmationDialog("从书架移除", isPresented: $isConfirmingLocalRemoval, titleVisibility: .visible) {
            Button("移除", role: .destructive) { Task { await model.removeFromLibrary() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只从本地书架移除。评分、标签、稍后再读和阅读进度都会保留，网站收藏不受影响。")
        }
        .confirmationDialog("从网站书架移除", isPresented: Binding(
            get: { remote.isConfirmingRemoval },
            set: { if !$0 { remote.cancelRemoveFromWebsite() } }
        ), titleVisibility: .visible) {
            Button("移除", role: .destructive) { Task { await remote.confirmRemoveFromWebsite() } }
            Button("取消", role: .cancel) { remote.cancelRemoveFromWebsite() }
        } message: {
            Text("此操作只修改网站收藏；本地书架、稍后再读、评分、标签和阅读进度均保留。")
        }
        .alert(authorizationTitle, isPresented: Binding(
            get: { remote.pendingAuthorization != nil },
            set: { if !$0 { remote.cancelPendingOperation() } }
        )) {
            Button("授权并执行") { Task { await remote.authorizePendingOperation() } }
            Button("取消", role: .cancel) { remote.cancelPendingOperation() }
        } message: {
            Text("这个来源将以你的登录身份修改网站上的书架。授权只对这个来源、这种操作有效。")
        }
        .task {
            await model.load()
            await remote.load()
        }
    }

    private var authorizationTitle: String {
        switch remote.pendingAuthorization {
        case .add?: return "授权加入网站书架"
        case .move?: return "授权移动网站书籍"
        case .remove?, nil: return "授权从网站书架移除"
        }
    }

    @ToolbarContentBuilder
    private var overflow: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("刷新详情", systemImage: "arrow.clockwise")
                }
                if case .content(let content) = model.state, content.inLibrary {
                    Button(role: .destructive) {
                        isConfirmingLocalRemoval = true
                    } label: {
                        Label("从书架移除", systemImage: "bookmark.slash")
                    }
                }
                if case .content(let content) = model.state {
                    Button {
                        Task { await model.setUpdateChecksExcluded(!content.updateChecksExcluded) }
                    } label: {
                        Label(
                            content.updateChecksExcluded ? "恢复检查更新" : "停止检查更新",
                            systemImage: content.updateChecksExcluded ? "bell" : "bell.slash"
                        )
                    }
                }
                if let shelf = remote.state, shelf.canMove {
                    Menu {
                        ForEach(shelf.liveTargets, id: \.targetId) { target in
                            Button {
                                Task { await remote.moveOnWebsite(targetId: target.targetId, targetName: target.displayName) }
                            } label: {
                                if target.targetId == shelf.currentTargetId {
                                    Label(target.displayName, systemImage: "checkmark")
                                } else {
                                    Text(target.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("移至网站分类", systemImage: "folder")
                    }
                }
                if let shelf = remote.state, shelf.canRemove {
                    Button(role: .destructive) {
                        Task { await remote.requestRemoveFromWebsite() }
                    } label: {
                        Label("从网站书架移除", systemImage: "trash")
                    }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .disabled(model.isBusy || remote.isBusy)
        }
    }

    private func remoteBanner(_ banner: RemoteShelfBanner) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            Text(bannerText(banner))
                .font(TsuyomiTheme.Typography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch banner {
            case .unresolved(let operation):
                Button("重试\(operationVerb(operation))") { Task { await remote.retryUnresolved() } }
                if operation != .add {
                    Button("仅解除锁定") { Task { await remote.acknowledgeUnresolved() } }
                }
            case .partialMove(let targetId, let targetName, _):
                Button("继续移至\(targetName ?? targetId)") {
                    Task { await remote.moveOnWebsite(targetId: targetId, targetName: targetName) }
                }
            case .added, .result:
                Button("关闭") { remote.dismissBanner() }
            }
        }
        .disabled(remote.isBusy)
    }

    private func operationVerb(_ operation: RemoteWriteOperation) -> String {
        switch operation {
        case .add: return "加入"
        case .move: return "移动"
        case .remove: return "移除"
        }
    }

    private func bannerText(_ banner: RemoteShelfBanner) -> String {
        switch banner {
        case .added(let targetName):
            return "已加入网站收藏" + (targetName.map { "「\($0)」" } ?? "")
        case .partialMove:
            return "已加入默认书架，目标移动尚未完成"
        case .unresolved(let operation):
            return "\(operationVerb(operation))结果待确认"
        case .result(let operation, let result):
            let verb = operationVerb(operation)
            switch result {
            case .confirmed: return "\(verb)已完成"
            case .unresolved: return "\(verb)结果待确认"
            case .cancelled: return "\(verb)已取消"
            case .consentRequired: return "\(verb)需要授权"
            case .loginRequired: return "网站要求登录后才能\(verb)"
            case .verificationRequired: return "网站要求先完成验证"
            case .failure(let failure, let code):
                return "\(verb)失败：\(failure == .sourceFailure ? code : failure.rawValue)"
            }
        }
    }

    private var title: String {
        if case .content(let content) = model.state { return content.detail.summary.title }
        return "书籍"
    }

    private func masthead(_ content: BookDetailState) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
            HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.gutter) {
                /// Both dimensions, not just the width: left to find its own height the placeholder
                /// grows to whatever the title inside it needs, and the row grows with it.
                CoverImage(coverState(content.detail.summary))
                    .frame(width: 110, height: 110 / TsuyomiTheme.Metrics.coverAspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
                VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
                    /// The whole group is set against the cover's bottom edge, not its top: title,
                    /// author, badges and actions read downwards to that line, and the slack falls
                    /// above the title where a short title simply leaves the cover taller.
                    Spacer(minLength: 0)
                    Text(content.detail.summary.title)
                        .font(TsuyomiTheme.Typography.sectionTitle)
                        .lineLimit(3)
                    if let author = content.detail.summary.author {
                        if let openAuthorSearch {
                            Button {
                                openAuthorSearch(author)
                            } label: {
                                Text(author)
                                    .font(TsuyomiTheme.Typography.supporting)
                                    .foregroundStyle(TsuyomiTheme.Palette.accent)
                                    .lineLimit(2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("搜索作者：\(author)")
                        } else {
                            Text(author)
                                .font(TsuyomiTheme.Typography.supporting)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                        if let status = content.detail.status {
                            TsuyomiTagBadge(status)
                        }
                        if let date = content.detail.lastUpdatedDate {
                            Text("更新于 \(date)")
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        }
                        if content.isStaleOffline {
                            TsuyomiStatusBadge("离线缓存", tone: .warning)
                        }
                    }
                    shelfActions(content)
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
            /// The row is at least as tall as the cover, so the column has a bottom to reach; a fixed
            /// height on the column alone positions it without stretching it, and the spacer inside
            /// then has nothing to push against — which is why the actions kept floating mid-row.
            .frame(minHeight: 110 / TsuyomiTheme.Metrics.coverAspectRatio)
            if let description = content.detail.description {
                summary(description)
            }
            if !content.detail.tags.isEmpty {
                tags(content.detail.tags)
            }
            startReading(content)
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
    }

    /// The shelf and 稍后再读 are two square icon buttons the size of a touch target and no larger:
    /// they are not why this screen is open. They hug the leading edge rather than stretching, which
    /// is what a bordered button in a wide column does if left to itself.
    private func shelfActions(_ content: BookDetailState) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            iconAction(
                symbol: content.inLibrary ? "bookmark.fill" : "bookmark",
                label: content.inLibrary ? "移出书架" : "加入书架",
                isOn: content.inLibrary
            ) {
                Task { content.inLibrary ? await model.removeFromLibrary() : await model.addToLibrary() }
            }
            iconAction(
                symbol: content.readLater ? "clock.fill" : "clock",
                label: content.readLater ? "取消稍后再读" : "稍后再读",
                isOn: content.readLater
            ) {
                Task { await model.toggleReadLater() }
            }
            destinationMenu(content)
            Spacer(minLength: 0)
        }
        .disabled(model.isBusy)
    }

    /// `更多加入选项`: read-later, then the site's own shelf, then local collections, in that order.
    /// The website section is read from the mirror; the folder list is fetched only when the menu
    /// opens on a source whose folders were never read.
    private func destinationMenu(_ content: BookDetailState) -> some View {
        Menu {
            Button {
                Task { await model.toggleReadLater() }
            } label: {
                Label("稍后再读", systemImage: content.readLater ? "checkmark" : "clock")
            }
            if let shelf = remote.state, shelf.canAdd {
                Divider()
                Section("网站收藏") {
                    websiteDestinations(content, shelf: shelf)
                }
            }
            if !content.collections.isEmpty {
                Divider()
                Section("本地收藏夹") {
                    ForEach(content.collections, id: \.collectionId) { collection in
                        Button {
                            Task { await model.addToCollection(collection.collectionId) }
                        } label: {
                            if content.memberCollectionIds.contains(collection.collectionId) {
                                Label(collection.title, systemImage: "checkmark")
                            } else {
                                Text(collection.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .frame(width: 36, height: 36)
                .background(TsuyomiTheme.Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .frame(
                    width: TsuyomiTheme.Metrics.minimumTouchTarget,
                    height: TsuyomiTheme.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多加入选项")
        .disabled(remote.isBusy)
    }

    @ViewBuilder
    private func websiteDestinations(_ content: BookDetailState, shelf: RemoteShelfState) -> some View {
        if shelf.grouped, shelf.supportsTargets {
            switch shelf.destinations {
            case .idle, .loading:
                Text("正在读取网站目标…")
                    .onAppear { Task { await remote.openDestinations() } }
            case .unavailable:
                Text("没有可用的网站目标")
            case .loaded:
                ForEach(shelf.liveTargets, id: \.targetId) { target in
                    Button {
                        Task { await remote.addToWebsite(content.detail, targetId: target.targetId, targetName: target.displayName) }
                    } label: {
                        if target.targetId == shelf.currentTargetId {
                            Label(target.displayName, systemImage: "checkmark")
                        } else {
                            Text(target.displayName)
                        }
                    }
                }
            }
        } else {
            Button {
                Task { await remote.addToWebsite(content.detail, targetId: nil, targetName: nil) }
            } label: {
                if shelf.inMirror {
                    Label("全部网站收藏", systemImage: "checkmark")
                } else {
                    Text("全部网站收藏")
                }
            }
        }
    }

    private func iconAction(
        symbol: String,
        label: LocalizedStringKey,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            /// The tile is 36pt and the touch target is the full 44: the reference draws a small
            /// square, and shrinking the target with it would put the button under the minimum.
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? TsuyomiTheme.Palette.accent : TsuyomiTheme.Palette.secondaryText)
                .frame(width: 36, height: 36)
                .background(TsuyomiTheme.Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .frame(
                    width: TsuyomiTheme.Metrics.minimumTouchTarget,
                    height: TsuyomiTheme.Metrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The label carries the width, not the frame around the button: a bordered button draws its
    /// background around its label, so widening the frame alone leaves a small button in a wide box.
    private func startReading(_ content: BookDetailState) -> some View {
        Group {
            if let chapter = startingChapter(content) {
                Button {
                    openChapter(chapter)
                } label: {
                    /// The height is drawn here rather than left to a button style: a style adds its
                    /// own padding around whatever it is given, so asking for a height through one
                    /// gets that height plus the padding, which is how this became a slab twice.
                    Text(content.resumeChapterId == nil ? "开始阅读" : "继续阅读")
                        .font(TsuyomiTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: TsuyomiTheme.Metrics.minimumTouchTarget
                        )
                        .background(
                            TsuyomiTheme.Palette.accent,
                            in: RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Where 开始阅读 goes: the chapter last left off in, or the first one in reading order. Reading
    /// order is the source's own, not whichever way the directory happens to be sorted right now.
    private func startingChapter(_ content: BookDetailState) -> SourceChapter? {
        if let resume = content.resumeChapterId,
           let chapter = content.chapters.first(where: { $0.chapterId == resume }) {
            return chapter
        }
        return content.chapters.first
    }

    /// A synopsis can run for paragraphs and it is not why anyone opened this screen; the directory
    /// is. It is clamped until asked for, and the control says which way it will go.
    private func summary(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(description)
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .lineLimit(isSummaryExpanded ? nil : 3)
                /// Lifting the line limit is not enough on its own: inside a row that is being handed
                /// a height, the text still truncates to fit it. This makes it ask for the height it
                /// needs, which is what "展开" is supposed to mean.
                .fixedSize(horizontal: false, vertical: true)
            /// Borderless, because a list row hands its whole area to a button in the default style —
            /// and the tags share this row, so a tap on one of them was landing here.
            Button(isSummaryExpanded ? "收起" : "展开") { isSummaryExpanded.toggle() }
                .buttonStyle(.borderless)
                .font(TsuyomiTheme.Typography.caption)
        }
    }

    private func tags(_ values: [String]) -> some View {
        TsuyomiWrappingRow(spacing: TsuyomiTheme.Metrics.tightGutter) {
            ForEach(values, id: \.self) { value in
                TsuyomiTagBadge(value)
            }
        }
    }

    private func directoryHeader(_ content: BookDetailState) -> some View {
        HStack {
            Text("共 \(content.chapters.count) 章")
                .font(TsuyomiTheme.Typography.sectionTitle)
                .foregroundStyle(TsuyomiTheme.Palette.primaryText)
            Spacer()
            Button {
                model.isDescending.toggle()
            } label: {
                Image(systemName: model.isDescending
                    ? "arrow.up.arrow.down.circle.fill"
                    : "arrow.up.arrow.down.circle")
            }
            .accessibilityLabel(model.isDescending ? "改为正序" : "改为倒序")
        }
        .textCase(nil)
    }

    private func ordered(_ content: BookDetailState) -> [SourceChapter] {
        model.isDescending ? Array(content.chapters.reversed()) : content.chapters
    }

    private func chapterRow(_ chapter: SourceChapter, content: BookDetailState) -> some View {
        Button {
            openChapter(chapter)
        } label: {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(
                            content.readChapterIds.contains(chapter.chapterId)
                                ? TsuyomiTheme.Palette.secondaryText
                                : TsuyomiTheme.Palette.primaryText
                        )
                    if let volume = chapter.volumeTitle {
                        Text(volume)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                    }
                }
                Spacer()
                if chapter.chapterId == content.resumeChapterId {
                    TsuyomiStatusBadge("继续", tone: .positive)
                }
            }
            /// Without this the row is only tappable where the text is: a `Spacer` and the padding
            /// around it carry no hit area of their own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        /// A directory is a list to run an eye down. The rows carry their own leading inset and a
        /// tight vertical one, so a long list stays compact instead of a screenful holding four.
        .listRowInsets(
            EdgeInsets(
                top: 10,
                leading: TsuyomiTheme.Metrics.gutter,
                bottom: 10,
                trailing: TsuyomiTheme.Metrics.gutter
            )
        )
    }
}
