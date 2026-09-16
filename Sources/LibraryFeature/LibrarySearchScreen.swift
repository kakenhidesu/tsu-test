// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

/// Search over the local shelf. Nothing here reaches a source; a blank field shows what the reader
/// is most likely to reopen.
public struct LibrarySearchScreen: View {
    @StateObject private var model: LibrarySearchModel
    private let coverState: (LibraryBook) -> CoverUiState
    private let openBook: (BookIdentity) -> Void
    private let openCollection: (LibraryCollection) -> Void

    public init(
        model: @autoclosure @escaping () -> LibrarySearchModel,
        coverState: @escaping (LibraryBook) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void,
        openCollection: @escaping (LibraryCollection) -> Void
    ) {
        _model = StateObject(wrappedValue: model())
        self.coverState = coverState
        self.openBook = openBook
        self.openCollection = openCollection
    }

    public var body: some View {
        List {
            if model.hits.isEmpty {
                Text(model.isRecommending ? "书架上还没有可以推荐的内容。" : "没有匹配的书或收藏夹。")
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
            }
            let collections = model.hits.compactMap { hit -> LibraryCollection? in
                if case .collection(let collection) = hit { return collection }
                return nil
            }
            let books = model.hits.compactMap { hit -> LibraryEntry? in
                if case .book(let entry) = hit { return entry }
                return nil
            }
            if model.isRecommending {
                bookSection(books, title: "最近")
                collectionSection(collections)
            } else {
                collectionSection(collections)
                bookSection(books, title: "书")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书架")
        .onSubmit(of: .search) { model.submit() }
        .navigationTitle("搜索书架")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func collectionSection(_ collections: [LibraryCollection]) -> some View {
        if !collections.isEmpty {
            Section("收藏夹") {
                ForEach(collections, id: \.collectionId) { collection in
                    Button {
                        openCollection(collection)
                    } label: {
                        Label(collection.title, systemImage: collection.kind == .smart ? "sparkles" : "folder")
                            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bookSection(_ books: [LibraryEntry], title: LocalizedStringKey) -> some View {
        if !books.isEmpty {
            Section(title) {
                ForEach(books, id: \.book.identity) { entry in
                    Button {
                        openBook(entry.book.identity)
                    } label: {
                        HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                            CoverImage(coverState(entry.book))
                                .frame(width: 48, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.book.title)
                                    .font(TsuyomiTheme.Typography.body)
                                    .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                                if !entry.book.authors.isEmpty {
                                    Text(entry.book.authors.sorted(by: CanonicalOrder.precedes).joined(separator: "、"))
                                        .font(TsuyomiTheme.Typography.caption)
                                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
