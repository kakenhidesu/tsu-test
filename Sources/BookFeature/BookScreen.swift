// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct BookScreen: View {
    @ObservedObject private var model: BookModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openChapter: (SourceChapter) -> Void
    @State private var isSummaryExpanded = false

    public init(
        model: BookModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openChapter: @escaping (SourceChapter) -> Void
    ) {
        self.model = model
        self.coverState = coverState
        self.openChapter = openChapter
    }

    /// A plain list, not grouped cards: the directory is the body of this screen and everything above
    /// it is a masthead, so the chapters read as one continuous run rather than as a boxed section.
    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            List {
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
        .task { await model.load() }
    }

    private var title: String {
        if case .content(let content) = model.state { return content.detail.summary.title }
        return "书籍"
    }

    private func masthead(_ content: BookDetailState) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
            HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.gutter) {
                CoverImage(coverState(content.detail.summary))
                    .frame(width: 110)
                    .clipShape(RoundedRectangle(cornerRadius: TsuyomiTheme.Metrics.cornerRadius))
                VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
                    Text(content.detail.summary.title)
                        .font(TsuyomiTheme.Typography.sectionTitle)
                        .lineLimit(3)
                    if let author = content.detail.summary.author {
                        Text(author)
                            .font(TsuyomiTheme.Typography.supporting)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                            .lineLimit(2)
                    }
                    HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                        if let status = content.detail.status {
                            TsuyomiTagBadge(status)
                        }
                        if content.isStaleOffline {
                            TsuyomiStatusBadge("离线缓存", tone: .warning)
                        }
                    }
                    Spacer(minLength: 0)
                    shelfActions(content)
                }
            }
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

    /// The shelf and 稍后再读 are icon-sized because they are not why this screen is open; 开始阅读 is.
    /// Nothing here can produce a remote write.
    private func shelfActions(_ content: BookDetailState) -> some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            Button {
                Task { content.inLibrary ? await model.removeFromLibrary() : await model.addToLibrary() }
            } label: {
                Image(systemName: content.inLibrary ? "bookmark.fill" : "bookmark")
                    .frame(
                        width: TsuyomiTheme.Metrics.minimumTouchTarget,
                        height: TsuyomiTheme.Metrics.minimumTouchTarget
                    )
            }
            .accessibilityLabel(content.inLibrary ? "移出书架" : "加入书架")
            Button {
                Task { await model.toggleReadLater() }
            } label: {
                Image(systemName: content.readLater ? "clock.fill" : "clock")
                    .frame(
                        width: TsuyomiTheme.Metrics.minimumTouchTarget,
                        height: TsuyomiTheme.Metrics.minimumTouchTarget
                    )
            }
            .accessibilityLabel(content.readLater ? "取消稍后再读" : "稍后再读")
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
    }

    private func startReading(_ content: BookDetailState) -> some View {
        Group {
            if let chapter = startingChapter(content) {
                Button(content.resumeChapterId == nil ? "开始阅读" : "继续阅读") { openChapter(chapter) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
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
                .animation(.default, value: isSummaryExpanded)
            Button(isSummaryExpanded ? "收起" : "展开") { isSummaryExpanded.toggle() }
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
            .padding(.vertical, 4)
            /// Without this the row is only tappable where the text is: a `Spacer` and the padding
            /// around it carry no hit area of their own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
