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

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            List {
                Section { header(content) }
                if let description = content.detail.description {
                    Section("简介") { summary(description) }
                }
                if !content.detail.tags.isEmpty {
                    Section("标签") { tags(content.detail.tags) }
                }
                Section {
                    ForEach(ordered(content), id: \.chapterId) { chapter in
                        chapterRow(chapter, content: content)
                    }
                } header: {
                    directoryHeader(content)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var title: String {
        if case .content(let content) = model.state { return content.detail.summary.title }
        return "书籍"
    }

    private func header(_ content: BookDetailState) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
            HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.gutter) {
                CoverImage(coverState(content.detail.summary))
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
                    Text(content.detail.summary.title)
                        .font(TsuyomiTheme.Typography.sectionTitle)
                    if let author = content.detail.summary.author {
                        Text(author)
                            .font(TsuyomiTheme.Typography.supporting)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                    if let status = content.detail.status {
                        Text(status)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                    }
                    if content.isStaleOffline {
                        TsuyomiStatusBadge("离线缓存内容", tone: .warning)
                    }
                }
            }
            actions(content)
        }
    }

    /// `加入书架` writes only to this device. Nothing on this screen can produce a remote write.
    private func actions(_ content: BookDetailState) -> some View {
        VStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            if let chapter = startingChapter(content) {
                Button(content.resumeChapterId == nil ? "开始阅读" : "继续阅读") { openChapter(chapter) }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            }
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                if content.inLibrary {
                    Button("移出书架", role: .destructive) { Task { await model.removeFromLibrary() } }
                        .buttonStyle(.bordered)
                } else {
                    Button("加入书架") { Task { await model.addToLibrary() } }
                        .buttonStyle(.bordered)
                }
                Button(content.readLater ? "取消稍后再读" : "稍后再读") {
                    Task { await model.toggleReadLater() }
                }
                .buttonStyle(.bordered)
            }
            .disabled(model.isBusy)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
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
    @ViewBuilder
    private func summary(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            Text(description)
                .font(TsuyomiTheme.Typography.body)
                .lineLimit(isSummaryExpanded ? nil : 4)
                .animation(.default, value: isSummaryExpanded)
            Button(isSummaryExpanded ? "收起" : "展开") {
                isSummaryExpanded.toggle()
            }
            .font(TsuyomiTheme.Typography.caption)
        }
    }

    private func tags(_ values: [String]) -> some View {
        TsuyomiWrappingRow(spacing: TsuyomiTheme.Metrics.tightGutter) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(TsuyomiTheme.Typography.badge)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(TsuyomiTheme.Palette.raisedSurface, in: Capsule())
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            }
        }
    }

    private func directoryHeader(_ content: BookDetailState) -> some View {
        HStack {
            Text("目录（\(content.chapters.count)）")
            Spacer()
            Button(model.isDescending ? "正序" : "倒序") {
                model.isDescending.toggle()
            }
            .font(TsuyomiTheme.Typography.caption)
        }
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
                    if let volume = chapter.volumeTitle {
                        Text(volume)
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.tertiaryText)
                    }
                    Text(chapter.title)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(
                            content.readChapterIds.contains(chapter.chapterId)
                                ? TsuyomiTheme.Palette.secondaryText
                                : TsuyomiTheme.Palette.primaryText
                        )
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
    }
}
