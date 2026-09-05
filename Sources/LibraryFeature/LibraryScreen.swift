// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct LibraryScreen: View {
    @ObservedObject private var model: LibraryModel
    private let coverState: (LibraryBook) -> CoverUiState
    private let openBook: (BookIdentity) -> Void
    @State private var newCollectionTitle = ""
    @State private var pendingPair: [BookIdentity] = []

    public init(
        model: LibraryModel,
        coverState: @escaping (LibraryBook) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
                    systemNodes
                    if !content.collections.isEmpty {
                        collectionRow(content.collections)
                    }
                    books
                }
                .padding(.vertical, TsuyomiTheme.Metrics.gutter)
            }
        }
        .navigationTitle(model.activeCollection?.title ?? "书架")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .alert("新建收藏夹", isPresented: Binding(
            get: { !pendingPair.isEmpty },
            set: { if !$0 { pendingPair = [] } }
        )) {
            TextField("名称", text: $newCollectionTitle)
            Button("取消", role: .cancel) { pendingPair = [] }
            Button("创建") {
                let books = pendingPair
                let title = newCollectionTitle
                pendingPair = []
                newCollectionTitle = ""
                Task { await model.createCollection(named: title, from: books) }
            }
        } message: {
            Text("把这 \(pendingPair.count) 本书放进一个新的收藏夹。")
        }
        .task { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.activeCollection != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回书架") { Task { await model.open(collection: nil) } }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(model.layout.title) { model.cycleLayout() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("排序") {
                Picker("排序方式", selection: $model.sort) {
                    ForEach(LibrarySortMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("倒序", isOn: $model.sortDescending)
            }
        }
    }

    private var systemNodes: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                ForEach(model.visibleSystemNodes, id: \.self) { node in
                    Button(node.title) { model.filter = node }
                        .buttonStyle(.bordered)
                        .tint(model.filter == node ? TsuyomiTheme.Palette.accent : nil)
                        .contextMenu {
                            if node != .all {
                                Button("隐藏此入口") { model.setSystemNode(node, hidden: true) }
                            }
                            ForEach(SystemLibraryFilter.allCases.filter(model.hiddenSystemNodes.contains), id: \.self) { hidden in
                                Button("恢复\(hidden.title)") { model.setSystemNode(hidden, hidden: false) }
                            }
                        }
                }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
    }

    private func collectionRow(_ collections: [LibraryCollection]) -> some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.tightGutter) {
            Text("收藏夹")
                .font(TsuyomiTheme.Typography.sectionTitle)
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                    ForEach(collections, id: \.collectionId) { collection in
                        collectionChip(collection)
                    }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
        }
    }

    private func collectionChip(_ collection: LibraryCollection) -> some View {
        Button {
            if model.selectionKind == .collections {
                model.toggle(collection: collection.collectionId)
            } else if model.selectionKind == .books {
                let selected = Array(model.selectedBooks)
                Task { await model.addBooks(selected, to: collection.collectionId) }
            } else {
                Task { await model.open(collection: collection) }
            }
        } label: {
            Label(collection.title, systemImage: collection.kind == .smart ? "wand.and.stars" : "folder")
                .font(TsuyomiTheme.Typography.supporting)
                .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        }
        .buttonStyle(.bordered)
        .tint(model.selectedCollections.contains(collection.collectionId) ? TsuyomiTheme.Palette.accent : nil)
        .onLongPressGesture { model.beginSelection(collection: collection.collectionId) }
        .dropDestination(for: BookIdentityTransfer.self) { items, _ in
            let identities = items.compactMap { try? $0.identity }
            guard !identities.isEmpty else { return false }
            Task { await model.addBooks(identities, to: collection.collectionId) }
            return true
        }
    }

    @ViewBuilder
    private var books: some View {
        let entries = model.visibleEntries
        if entries.isEmpty {
            Text("这个筛选下还没有书。")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        } else {
            switch model.layout {
            case .grid:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: TsuyomiTheme.Metrics.gutter), count: 3),
                          spacing: TsuyomiTheme.Metrics.gutter) {
                    ForEach(entries, id: \.book.identity) { entry in
                        gridCard(entry)
                    }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            case .list, .compact:
                LazyVStack(spacing: 0) {
                    ForEach(entries, id: \.book.identity) { entry in
                        row(entry, compact: model.layout == .compact)
                    }
                }
            }
        }
    }

    private func gridCard(_ entry: LibraryEntry) -> some View {
        TsuyomiCoverGridCard(
            title: entry.book.title,
            cover: coverState(entry.book),
            badge: badge(entry),
            isSelected: model.selectedBooks.contains(entry.book.identity),
            action: { activate(entry) }
        )
        .onLongPressGesture { model.beginSelection(book: entry.book.identity) }
        .draggable(BookIdentityTransfer(identity: entry.book.identity))
        .dropDestination(for: BookIdentityTransfer.self) { items, _ in
            let dropped = items.compactMap { try? $0.identity }.filter { $0 != entry.book.identity }
            guard !dropped.isEmpty else { return false }
            pendingPair = dropped + [entry.book.identity]
            return true
        }
    }

    private func row(_ entry: LibraryEntry, compact: Bool) -> some View {
        Button {
            activate(entry)
        } label: {
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                if !compact {
                    CoverImage(coverState(entry.book))
                        .frame(width: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.book.title)
                        .font(TsuyomiTheme.Typography.body)
                        .foregroundStyle(TsuyomiTheme.Palette.primaryText)
                    if !compact, !entry.book.authors.isEmpty {
                        Text(entry.book.authors.sorted(by: CanonicalOrder.precedes).joined(separator: "、"))
                            .font(TsuyomiTheme.Typography.caption)
                            .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    }
                }
                Spacer()
                if let badge = badge(entry) {
                    TsuyomiStatusBadge(badge.text, tone: badge.tone)
                }
                if model.selectedBooks.contains(entry.book.identity) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TsuyomiTheme.Palette.accent)
                }
            }
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .buttonStyle(.plain)
        .onLongPressGesture { model.beginSelection(book: entry.book.identity) }
        .draggable(BookIdentityTransfer(identity: entry.book.identity))
    }

    private func badge(_ entry: LibraryEntry) -> (text: LocalizedStringKey, tone: TsuyomiStatusTone)? {
        if !entry.sourceAvailable { return ("来源休眠", .warning) }
        if entry.book.hasUnreadUpdate { return ("有更新", .positive) }
        if entry.readLater { return ("稍后再读", .neutral) }
        return nil
    }

    private func activate(_ entry: LibraryEntry) {
        if model.isSelecting {
            model.toggle(book: entry.book.identity)
        } else {
            openBook(entry.book.identity)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let kind = model.selectionKind {
            HStack(spacing: TsuyomiTheme.Metrics.gutter) {
                Text(kind == .books ? "已选 \(model.selectedBooks.count) 本" : "已选 \(model.selectedCollections.count) 个")
                Spacer()
                Button("全选") { model.selectAll() }
                Button("清空") { model.endSelection() }
                if kind == .books {
                    Button("移出书架", role: .destructive) { Task { await model.removeSelectedBooks() } }
                } else {
                    Button("删除", role: .destructive) { Task { await model.deleteSelectedCollections() } }
                }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .background(.bar)
        }
    }
}
