// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// The reader's own settings panel, shaped like the one it sits beside on this platform: a titled
/// sheet, a row of controls for the things changed most often, and everything else behind 选项. It
/// writes the same `ReaderSettings` the settings tab writes — one set of values, two presentations,
/// each the right one for where it appears.
public struct ReaderSettingsSheet: View {
    @Binding private var settings: ReaderSettings
    @Binding private var appearance: ColorSchemePreference
    private let onChange: (ReaderSettings) -> Void
    private let onClose: () -> Void
    @State private var isShowingOptions = false

    public init(
        settings: Binding<ReaderSettings>,
        appearance: Binding<ColorSchemePreference>,
        onChange: @escaping (ReaderSettings) -> Void,
        onClose: @escaping () -> Void
    ) {
        self._settings = settings
        self._appearance = appearance
        self.onChange = onChange
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TsuyomiTheme.Metrics.gutter) {
            heading
            controls
            Spacer(minLength: 0)
        }
        .padding(TsuyomiTheme.Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(220), .large])
        .presentationContentInteraction(.scrolls)
        .sheet(isPresented: $isShowingOptions) {
            NavigationStack {
                ReaderSettingsForm(settings: $settings, onChange: onChange)
                    .navigationTitle("选项")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { isShowingOptions = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("主题与设置")
                    .font(TsuyomiTheme.Typography.screenTitle)
                Button {
                    isShowingOptions = true
                } label: {
                    HStack(spacing: 2) {
                        Text("选项")
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(TsuyomiTheme.Typography.supporting)
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(TsuyomiTheme.Palette.raisedSurface, in: Circle())
            }
            .accessibilityLabel("关闭")
        }
    }

    /// One row: the size, then the things that change how a page behaves. Each is a control the
    /// reference puts here, and each writes through immediately.
    private var controls: some View {
        HStack(spacing: TsuyomiTheme.Metrics.tightGutter) {
            HStack(spacing: 0) {
                sizeButton(delta: -1, symbol: "textformat.size.smaller", label: "缩小字号")
                Divider().frame(height: 22)
                sizeButton(delta: 1, symbol: "textformat.size.larger", label: "放大字号")
            }
            .background(TsuyomiTheme.Palette.raisedSurface, in: Capsule())
            flowMenu
            transitionMenu
            appearanceMenu
        }
    }

    private func sizeButton(delta: Double, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            var updated = settings
            let range = ReaderSettings.fontSizeRange
            updated.fontSize = min(max(updated.fontSize + delta, range.lowerBound), range.upperBound)
            settings = updated
            onChange(updated)
        } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity)
                .frame(height: TsuyomiTheme.Metrics.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var flowMenu: some View {
        controlMenu(symbol: "text.alignleft", label: "阅读方式") {
            picker(
                options: [(.scroll, "滚动"), (.paged, "单页"), (.dualPage, "双页")],
                selection: \.flow
            )
        }
    }

    private var transitionMenu: some View {
        controlMenu(symbol: "book.closed", label: "翻页效果") {
            picker(
                options: [(.slide, "滑动"), (.curl, "卷页"), (.immediate, "无")],
                selection: \.pageTransition
            )
        }
    }

    /// The page's colour lives here because it is the app's appearance, not a reader-only theme.
    private var appearanceMenu: some View {
        Menu {
            Picker("外观", selection: $appearance) {
                Label("浅色", systemImage: "sun.max").tag(ColorSchemePreference.light)
                Label("深色", systemImage: "moon").tag(ColorSchemePreference.dark)
                Label("匹配设备", systemImage: "circle.lefthalf.filled").tag(ColorSchemePreference.system)
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .frame(
                    width: TsuyomiTheme.Metrics.minimumTouchTarget,
                    height: TsuyomiTheme.Metrics.minimumTouchTarget
                )
                .background(TsuyomiTheme.Palette.raisedSurface, in: Circle())
        }
        .accessibilityLabel("外观")
    }

    private func controlMenu(
        symbol: String,
        label: LocalizedStringKey,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: symbol)
                .frame(width: 56, height: TsuyomiTheme.Metrics.minimumTouchTarget)
                .background(TsuyomiTheme.Palette.raisedSurface, in: Capsule())
        }
        .accessibilityLabel(label)
    }

    private func picker<Value: Hashable>(
        options: [(Value, LocalizedStringKey)],
        selection keyPath: WritableKeyPath<ReaderSettings, Value>
    ) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { settings[keyPath: keyPath] },
                set: { newValue in
                    var updated = settings
                    updated[keyPath: keyPath] = newValue
                    settings = updated
                    onChange(updated)
                }
            )
        ) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
    }
}
