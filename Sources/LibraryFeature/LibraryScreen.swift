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
    @State private var insertionIndex: Int?
    @State private var isCreatingCollection = false

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
                    LibraryShortcutBar(model: model)
                    books(model.project(content.entries))
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
        .sheet(isPresented: $isCreatingCollection) {
            CollectionEditorScreen(model: model)
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
            Button("新建收藏夹") { isCreatingCollection = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(model.isArranging ? "完成排序" : "排序整理") {
                Task { await model.setArranging(!model.isArranging) }
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


    @ViewBuilder
    private func books(_ entries: [LibraryEntry]) -> some View {
        if entries.isEmpty {
            Text("这个筛选下还没有书。")
                .font(TsuyomiTheme.Typography.supporting)
                .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        } else {
            switch model.layout {
            case .grid:
                InsertionGridLayout(
                    columns: 3,
                    spacing: TsuyomiTheme.Metrics.gutter,
                    insertionIndex: insertionIndex
                ) {
                    ForEach(Array(entries.enumerated()), id: \.element.book.identity) { index, entry in
                        gridCard(entry, at: index)
                    }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
                .animation(.easeInOut(duration: 0.2), value: insertionIndex)
            case .list, .compact:
                LazyVStack(spacing: 0) {
                    ForEach(entries, id: \.book.identity) { entry in
                        row(entry, compact: model.layout == .compact)
                    }
                }
            }
        }
    }

    /// While arranging, a drop lands the book in this slot; otherwise it puts the two books in a new
    /// collection. The mode decides, so one gesture never has to mean two things at once.
    private func gridCard(_ entry: LibraryEntry, at index: Int) -> some View {
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
            insertionIndex = nil
            let dropped = items.compactMap { try? $0.identity }
            guard !dropped.isEmpty else { return false }
            if model.isArranging {
                guard let moved = dropped.first else { return false }
                Task { await model.move(moved, to: index) }
                return true
            }
            let others = dropped.filter { $0 != entry.book.identity }
            guard !others.isEmpty else { return false }
            pendingPair = others + [entry.book.identity]
            return true
        } isTargeted: { targeted in
            insertionIndex = targeted && model.isArranging ? index : nil
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
