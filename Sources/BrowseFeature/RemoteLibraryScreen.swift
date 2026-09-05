// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct RemoteLibraryScreen: View {
    @ObservedObject private var model: RemoteLibraryModel
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openBook: (BookIdentity) -> Void

    public init(
        model: RemoteLibraryModel,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            List {
                Section {
                    Text("这里只读取网站上的收藏，永远不会替你在网站上增删任何内容。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
                ForEach(content.items, id: \.identity) { item in
                    row(item)
                }
                if let cursor = content.nextCursor {
                    Button("载入下一页") {
                        Task { await model.load(cursor: cursor) }
                    }
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                }
                if model.copiedCount > 0 {
                    Text("已复制 \(model.copiedCount) 本到本地书架。")
                        .font(TsuyomiTheme.Typography.caption)
                        .foregroundStyle(TsuyomiTheme.Palette.success)
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("网站收藏")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("拉取") { Task { await model.load() } }
                    .disabled(model.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) { selectionBar }
    }

    private func row(_ item: SourceBookSummary) -> some View {
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
            .accessibilityLabel(model.selected.contains(item.identity) ? "取消选择 \(item.title)" : "选择 \(item.title)")

            CoverImage(coverState(item))
                .frame(width: 44)

            Button {
                openBook(item.identity)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    if let author = item.author {
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
        if case .content(let content) = model.state, !content.items.isEmpty {
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                Text("已选 \(model.selected.count)")
                    .font(TsuyomiTheme.Typography.caption)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                Spacer()
                Button("全选") { model.selectAll() }
                Button("清空") { model.clearSelection() }
                    .disabled(model.selected.isEmpty)
                Button("复制选中") { Task { await model.copySelectedToLibrary() } }
                    .disabled(model.selected.isEmpty || model.isBusy)
                Button("全部复制") { Task { await model.copyAllToLibrary() } }
                    .disabled(model.isBusy)
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .background(.bar)
        }
    }
}
