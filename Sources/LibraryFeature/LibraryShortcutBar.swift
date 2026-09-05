// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// The shelf's shortcut row. Collapsed it is a full-height handle rather than a hidden strip, so the
/// way back is always at least as large as a touch target.
struct LibraryShortcutBar: View {
    @ObservedObject var model: LibraryModel
    @State private var isEditing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.isShortcutBarCollapsed {
                handle
            } else if isEditing {
                editor
            } else {
                strip
            }
        }
        .animation(reduceMotion ? nil : .default, value: model.isShortcutBarCollapsed)
        .animation(reduceMotion ? nil : .default, value: isEditing)
    }

    private var handle: some View {
        Button {
            model.isShortcutBarCollapsed = false
        } label: {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                Image(systemName: "chevron.down")
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
            if targeted { model.isShortcutBarCollapsed = false }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
                ForEach(model.shortcuts) { shortcut in
                    chip(shortcut)
                }
                Button(model.isShortcutBarLocked ? "已锁定" : "整理") {
                    if model.isShortcutBarLocked {
                        model.setShortcutBarLocked(false)
                    } else {
                        isEditing = true
                    }
                }
                .buttonStyle(.borderless)
                Button("收折") { model.isShortcutBarCollapsed = true }
                    .buttonStyle(.borderless)
            }
            .font(TsuyomiTheme.Typography.supporting)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
        }
        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func chip(_ shortcut: LibraryShortcut) -> some View {
        Button(model.title(of: shortcut)) { tap(shortcut) }
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
                    isEditing = false
                }
                Button("完成") { isEditing = false }
            }
            .font(TsuyomiTheme.Typography.supporting)
            .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
            .padding(.horizontal, TsuyomiTheme.Metrics.gutter)
            List {
                ForEach(model.shortcuts) { shortcut in
                    Text(model.title(of: shortcut))
                        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                }
                .onMove { source, destination in
                    model.moveShortcut(from: source, to: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .listStyle(.plain)
            .frame(height: 240)
        }
    }

    private func isActive(_ shortcut: LibraryShortcut) -> Bool {
        switch shortcut {
        case .system(let node): return model.activeCollection == nil && model.filter == node
        case .collection(let id): return model.activeCollection?.collectionId == id
        }
    }
}

extension SystemLibraryFilter: Identifiable {
    public var id: String { rawValue }
}
