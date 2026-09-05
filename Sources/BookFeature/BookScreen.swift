// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct BookScreen: View {
    @ObservedObject private var model: BookModel
    private let cover: CoverUiState
    private let openChapter: (SourceChapter) -> Void

    public init(
        model: BookModel,
        cover: CoverUiState,
        openChapter: @escaping (SourceChapter) -> Void
    ) {
        self.model = model
        self.cover = cover
        self.openChapter = openChapter
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            List {
                Section { header(content) }
                if let description = content.detail.description {
                    Section("简介") {
                        Text(description)
                            .font(TsuyomiTheme.Typography.body)
                    }
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
                CoverImage(cover)
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
        HStack(spacing: TsuyomiTheme.Metrics.gutter) {
            if content.inLibrary {
                Button("移出书架", role: .destructive) { Task { await model.removeFromLibrary() } }
                    .buttonStyle(.bordered)
            } else {
                Button("加入书架") { Task { await model.addToLibrary() } }
                    .buttonStyle(.borderedProminent)
            }
            Button(content.readLater ? "取消稍后再读" : "稍后再读") {
                Task { await model.toggleReadLater() }
            }
            .buttonStyle(.bordered)
        }
        .disabled(model.isBusy)
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
    }

    private func tags(_ values: [String]) -> some View {
        Text(values.joined(separator: "、"))
            .font(TsuyomiTheme.Typography.supporting)
            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
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
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        }
        .buttonStyle(.plain)
    }
}
