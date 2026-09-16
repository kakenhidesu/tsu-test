// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public struct LibraryScreen: View {
    @ObservedObject private var model: LibraryModel
    private let coverState: (LibraryBook) -> CoverUiState
    private let openBook: (BookIdentity) -> Void
    private let openMirror: (String) -> Void
    private let openSearch: () -> Void
    @State private var newCollectionTitle = ""
    @State private var pendingPair: [BookIdentity] = []
    @State private var insertionIndex: Int?
    @State private var isCreatingCollection = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: LibraryModel,
        coverState: @escaping (LibraryBook) -> CoverUiState,
        openBook: @escaping (BookIdentity) -> Void,
        openMirror: @escaping (String) -> Void = { _ in },
        openSearch: @escaping () -> Void = {}
    ) {
        self.model = model
        self.coverState = coverState
        self.openBook = openBook
        self.openMirror = openMirror
        self.openSearch = openSearch
    }

    public var body: some View {
        StateView(model.state, retry: { Task { await model.load() } }) { content in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
                    if model.activeCollection == nil {
                        tabs
                    }
                    updateStrip
                    LibraryShortcutBar(model: model, openMirror: openMirror)
                    if model.showUpdatesOnly, model.isUpdatesFilterAvailable {
                        filterSummary(model.project(content.entries).count)
                    }
                    books(model.project(content.entries))
                }
                .padding(.vertical, TsuyomiTheme.Metrics.gutter)
            }
            .refreshable { await model.checkUpdatesNow() }
        }
        .navigationTitle(model.activeCollection?.title ?? "书架")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .safeAreaInset(edge: .bottom) { undoBar }
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

    /// Three fixed tabs, chosen by tap. Selecting one restores its own layout and sort.
    private var tabs: some View {
        Picker("书架分区", selection: Binding(
            get: { model.tab },
            set: { selected in Task { await model.selectTab(selected) } }
        )) {
            ForEach(LibraryTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
    }

    private func filterSummary(_ count: Int) -> some View {
        HStack {
            Text("有更新 · \(count) 本")
                .font(TsuyomiTheme.Typography.supporting)
            Spacer()
            Button {
                model.setShowUpdatesOnly(false)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .accessibilityLabel("清除筛选")
        }
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
    }

    /// The update session's status: progress with a cancel while it runs, a summary with a retry
    /// once it stops. A clean completion says so briefly and is otherwise not worth a row.
    @ViewBuilder
    private var updateStrip: some View {
        if let session = model.updateSession {
            if session.state == .running || session.state == .queued {
                HStack {
                    ProgressView()
                    Text("正在检查更新 \(session.completed) / \(session.total)")
                        .font(TsuyomiTheme.Typography.supporting)
                    Spacer()
                    Button("取消") { Task { await model.cancelUpdateCheck() } }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            } else if session.state != .completed || model.isCheckingUpdates {
                HStack {
                    Text(updateSummary(session))
                        .font(TsuyomiTheme.Typography.supporting)
                    Spacer()
                    Button("重试") { Task { await model.checkUpdatesNow() } }
                        .disabled(model.isCheckingUpdates)
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            }
        }
    }

    private func updateSummary(_ session: UpdateSessionSummary) -> String {
        let state: String
        switch session.state {
        case .completed: state = "已完成"
        case .partial: state = "部分完成"
        case .failed: state = "失败"
        case .cancelled: state = "已取消"
        case .queued, .running: state = "正在检查"
        }
        return "\(state) · \(session.completed)/\(session.total) · 更新 \(session.updated)"
    }

    @ViewBuilder
    private var undoBar: some View {
        if model.undoIgnoreToken != nil {
            HStack {
                Text("已忽略当前更新")
                Spacer()
                Button("撤销") { Task { await model.undoIgnore() } }
                Button("关闭") { model.dismissUndo() }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.activeCollection != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button("返回书架") { Task { await model.open(collection: nil) } }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                openSearch()
            } label: {
                Label("搜索书架", systemImage: "magnifyingglass")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.cycleLayout()
            } label: {
                Label(model.layout.title, systemImage: layoutSymbol)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.isUpdatesFilterAvailable {
                    Section("筛选") {
                        Picker("筛选", selection: Binding(
                            get: { model.showUpdatesOnly },
                            set: { model.setShowUpdatesOnly($0) }
                        )) {
                            Text("全部").tag(false)
                            Text("仅有更新").tag(true)
                        }
                    }
                }
                Section("排序") {
                    Picker("排序方式", selection: $model.sort) {
                        ForEach(LibrarySortMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("倒序", isOn: $model.sortDescending)
                }
                Section {
                    Button("新建收藏夹") { isCreatingCollection = true }
                    Button(model.isArranging ? "完成排序" : "排序整理") {
                        Task { await model.setArranging(!model.isArranging) }
                    }
                    Button("立即检查更新") { Task { await model.checkUpdatesNow() } }
                        .disabled(model.isCheckingUpdates)
                }
            } label: {
                Label("筛选与排序", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    private var layoutSymbol: String {
        switch model.layout {
        case .grid: return "square.grid.3x3"
        case .list: return "list.bullet"
        case .compact: return "list.dash"
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
                    ForEach(slots(entries)) { slot in
                        gridCard(slot.entry, at: slot.index)
                    }
                }
                .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: insertionIndex)
            case .list, .compact:
                LazyVStack(spacing: 0) {
                    ForEach(entries, id: \.book.identity) { entry in
                        row(entry, compact: model.layout == .compact)
                    }
                }
            }
        }
    }

    /// A grid cell keeps the book's identity while carrying the slot it currently occupies, so a
    /// reorder animates the same cell moving rather than replacing one cell with another.
    private struct GridSlot: Identifiable {
        let index: Int
        let entry: LibraryEntry

        var id: BookIdentity { entry.book.identity }
    }

    private func slots(_ entries: [LibraryEntry]) -> [GridSlot] {
        entries.enumerated().map { GridSlot(index: $0.offset, entry: $0.element) }
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
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            model.selectedBooks.contains(entry.book.identity) ? [.isSelected, .isButton] : .isButton
        )
        .onLongPressGesture { model.beginSelection(book: entry.book.identity) }
        .draggable(BookIdentityTransfer(identity: entry.book.identity))
    }

    private func badge(_ entry: LibraryEntry) -> (text: LocalizedStringKey, tone: TsuyomiStatusTone)? {
        if !entry.sourceAvailable { return ("来源休眠", .warning) }
        if let update = model.update(for: entry.book.identity) { return ("新增 \(update.newChapterIds.count) 章", .positive) }
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
