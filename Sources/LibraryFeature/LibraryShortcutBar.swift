// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// The shelf's shortcut row. Collapsed it is a full-height handle rather than a hidden strip, so the
/// way back is always at least as large as a touch target.
struct LibraryShortcutBar: View {
    @ObservedObject var model: LibraryModel
    var openMirror: (String) -> Void = { _ in }
    var createCollection: () -> Void = {}
    @State private var isEditing = false
    @State private var deleting: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// An empty bar has nothing to collapse or arrange: it offers the one act that fills it.
    /// The three forms cross-fade inside one clipped container, driven by the buttons that switch
    /// them, so the shelf below slides to the new height instead of jumping.
    var body: some View {
        Group {
            if model.shortcuts.isEmpty {
                strip.transition(.opacity)
            } else if model.isShortcutBarCollapsed {
                handle.transition(.opacity)
            } else if isEditing {
                editor.transition(.opacity)
            } else {
                strip.transition(.opacity)
            }
        }
        .clipped()
        .confirmationDialog("删除这个收藏夹？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("删除收藏夹", role: .destructive) {
                guard let collectionId = deleting else { return }
                deleting = nil
                Task { await model.deleteCollection(collectionId) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("只删除收藏夹本身；里面的书仍留在书架上。")
        }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private var handle: some View {
        Button {
            withAnimation(motion) { model.isShortcutBarCollapsed = false }
        } label: {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Image(systemName: "chevron.down")
                    .accessibilityHidden(true)
                Text("展开快捷栏")
            }
            .font(TsuyomiTheme.Typography.supporting)
            .frame(maxWidth: .infinity, minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
        .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        .dropDestination(for: BookIdentityTransfer.self) { _, _ in false } isTargeted: { targeted in
            if targeted { withAnimation(motion) { model.isShortcutBarCollapsed = false } }
        }
    }

    /// Every control in the strip is the same chip: entries, then the two acts on the strip itself,
    /// which exist only once there are entries to arrange or hide.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                if model.shortcuts.isEmpty {
                    Button {
                        createCollection()
                    } label: {
                        Label("新建收藏夹", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                } else {
                    ForEach(model.shortcuts) { shortcut in
                        chip(shortcut)
                    }
                    Button {
                        if model.isShortcutBarLocked {
                            model.setShortcutBarLocked(false)
                        } else {
                            withAnimation(motion) { isEditing = true }
                        }
                    } label: {
                        Label(model.isShortcutBarLocked ? "已锁定" : "整理", systemImage: model.isShortcutBarLocked ? "lock" : "arrow.up.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                    Button {
                        withAnimation(motion) { model.isShortcutBarCollapsed = true }
                    } label: {
                        Label("收折", systemImage: "chevron.up")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func chip(_ shortcut: LibraryShortcut) -> some View {
        Button(model.title(of: shortcut)) {
            if case .mirror(let sourceId) = shortcut {
                openMirror(sourceId)
            } else {
                tap(shortcut)
            }
        }
            .buttonStyle(.bordered)
            .tint(tint(shortcut))
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .onLongPressGesture {
                guard case .collection(let collectionId) = shortcut else { return }
                model.beginSelection(collection: collectionId)
            }
            .contextMenu { menu(shortcut) }
            .dropDestination(for: BookIdentityTransfer.self) { items, _ in
                guard case .collection(let collectionId) = shortcut else { return false }
                let identities = items.compactMap { try? $0.identity }
                guard !identities.isEmpty else { return false }
                Task { await model.addBooks(identities, to: collectionId) }
                return true
            }
    }

    /// While books are selected a collection chip is the "move into" target; while collections are
    /// selected it toggles its own selection. Otherwise it opens.
    private func tap(_ shortcut: LibraryShortcut) {
        guard case .collection(let collectionId) = shortcut else {
            Task { await model.activate(shortcut) }
            return
        }
        switch model.selectionKind {
        case .books:
            let selected = Array(model.selectedBooks)
            Task { await model.addBooks(selected, to: collectionId) }
        case .collections:
            model.toggle(collection: collectionId)
        case nil:
            Task { await model.activate(shortcut) }
        }
    }

    private func tint(_ shortcut: LibraryShortcut) -> Color? {
        if case .collection(let collectionId) = shortcut,
           model.selectedCollections.contains(collectionId) {
            return TsuyomiTheme.Palette.accent
        }
        return isActive(shortcut) ? TsuyomiTheme.Palette.accent : nil
    }

    @ViewBuilder
    private func menu(_ shortcut: LibraryShortcut) -> some View {
        if case .collection(let collectionId) = shortcut {
            Button("删除收藏夹", role: .destructive) { deleting = collectionId }
        }
        if case .system(let node) = shortcut, node != .all {
            Button("隐藏此入口") { model.setSystemNode(node, hidden: true) }
        }
        ForEach(SystemLibraryFilter.allCases.filter(model.hiddenSystemNodes.contains)) { hidden in
            Button("恢复\(hidden.title)") { model.setSystemNode(hidden, hidden: false) }
        }
        Button(model.isShortcutBarLocked ? "解锁快捷栏" : "锁定快捷栏") {
            model.setShortcutBarLocked(!model.isShortcutBarLocked)
        }
    }

    /// Reordering happens in an explicit editing list: a single long press starts one continuous drag
    /// there, so a drag can never be confused with opening a shortcut.
    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("拖动排序")
                Spacer()
                Button("锁定并完成") {
                    model.setShortcutBarLocked(true)
                    withAnimation(motion) { isEditing = false }
                }
                Button("完成") { withAnimation(motion) { isEditing = false } }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            /// The list is exactly as tall as its rows, up to a cap that keeps a long bar scrollable:
            /// a fixed height left most of it as empty space over a bar of two or three entries.
            List {
                ForEach(model.shortcuts) { shortcut in
                    Text(model.title(of: shortcut))
                        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                        .listRowInsets(EdgeInsets(top: 0, leading: TsuyomiTheme.Metrics.gutter, bottom: 0, trailing: TsuyomiTheme.Metrics.gutter))
                }
                .onMove { source, destination in
                    model.moveShortcut(from: source, to: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .environment(\.defaultMinListRowHeight, TsuyomiTheme.Metrics.minimumTouchTarget)
            .listStyle(.plain)
            .scrollDisabled(model.shortcuts.count <= LibraryShortcutBar.editorRowCap)
            .frame(height: LibraryShortcutBar.editorHeight(rows: model.shortcuts.count))
        }
    }

    private static let editorRowCap = 5

    private static func editorHeight(rows: Int) -> CGFloat {
        CGFloat(min(max(rows, 1), editorRowCap)) * TsuyomiTheme.Metrics.minimumTouchTarget
    }

    private func isActive(_ shortcut: LibraryShortcut) -> Bool {
        switch shortcut {
        case .system(let node): return model.activeCollection == nil && model.filter == node
        case .collection(let id): return model.activeCollection?.collectionId == id
        case .mirror: return false
        }
    }
}

extension SystemLibraryFilter: Identifiable {
    public var id: String { rawValue }
}
