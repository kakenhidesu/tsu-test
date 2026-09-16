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
    @State private var isTitleExpanded = false
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

    /// The identity module: cover on the left, and beside it the title, author, metadata, rating and
    /// the one shelf action, top-aligned with the cover's top and ending at its bottom when they fit.
    private func masthead(_ content: BookDetailState) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
            HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.gutter) {
                CoverImage(coverState(content.detail.summary))
                    .frame(width: 120, height: 120 / TsuyomiTheme.Metrics.coverAspectRatio)
                    .clipShape(RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
                VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
                    Button {
                        isTitleExpanded.toggle()
                    } label: {
                        Text(content.detail.summary.title)
                            .font(TsuyomiTheme.Typography.sectionTitle)
                            .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                            .lineLimit(isTitleExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isTitleExpanded ? "完整标题已展开" : "展开完整标题")
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
                            Text(status)
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        }
                        if let date = content.detail.lastUpdatedDate {
                            Text("上次更新：\(date)")
                                .font(TsuyomiTheme.Typography.caption)
                                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                        }
                        if content.isStaleOffline {
                            TsuyomiStatusBadge("离线缓存", tone: .warning)
                        }
                    }
                    Spacer(minLength: 0)
                    ratingRow(content)
                    shelfActions(content)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            /// The row is at least as tall as the cover, so the column has a bottom to reach: the
            /// split action sits on the cover's bottom edge whenever the blocks above it leave room.
            .frame(minHeight: 120 / TsuyomiTheme.Metrics.coverAspectRatio)
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

    /// Five borderless stars, live only for a shelf book. Tapping the current star clears it.
    private func ratingRow(_ content: BookDetailState) -> some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    Task { await model.setRating(content.rating == star ? nil : star) }
                } label: {
                    Image(systemName: star <= (content.rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: 18))
                        .foregroundStyle(content.inLibrary ? TsuyomiTheme.Palette.accent : TsuyomiTheme.Palette.tertiaryText)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) 星")
            }
        }
        .disabled(!content.inLibrary || model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.rating.map { "评分 \($0) 星" } ?? "未评分")
    }

    /// One split action: the primary half adds, or shows the book is on the shelf and asks before
    /// removing it; the trailing half opens the destination menu. Never full width.
    private func shelfActions(_ content: BookDetailState) -> some View {
        HStack(spacing: 0) {
            Button {
                if content.inLibrary {
                    isConfirmingLocalRemoval = true
                } else {
                    Task { await model.addToLibrary() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: content.inLibrary ? "checkmark" : "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text(content.inLibrary ? "已在书架" : "加入书架")
                        .font(TsuyomiTheme.Typography.body.weight(.semibold))
                }
                    .padding(.horizontal, 14)
                    .frame(height: TsuyomiTheme.Metrics.minimumTouchTarget)
                    .foregroundStyle(content.inLibrary ? TsuyomiTheme.Palette.accent : Color.white)
                    .background(
                        content.inLibrary ? TsuyomiTheme.Palette.accent.opacity(0.16) : TsuyomiTheme.Palette.accent,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: TsuyomiTheme.Metrics.cornerRadius, bottomLeadingRadius: TsuyomiTheme.Metrics.cornerRadius,
                            bottomTrailingRadius: 0, topTrailingRadius: 0
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityAddTraits(content.inLibrary ? [.isSelected, .isButton] : .isButton)
            Rectangle()
                .fill(Color.white.opacity(content.inLibrary ? 0 : 0.35))
                .frame(width: 1, height: TsuyomiTheme.Metrics.minimumTouchTarget - 12)
            destinationMenu(content)
        }
        .fixedSize()
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
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(content.inLibrary ? TsuyomiTheme.Palette.accent : Color.white)
                .frame(width: 40, height: TsuyomiTheme.Metrics.minimumTouchTarget)
                .background(
                    content.inLibrary ? TsuyomiTheme.Palette.accent.opacity(0.16) : TsuyomiTheme.Palette.accent,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 0,
                        bottomTrailingRadius: TsuyomiTheme.Metrics.cornerRadius, topTrailingRadius: TsuyomiTheme.Metrics.cornerRadius
                    )
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
