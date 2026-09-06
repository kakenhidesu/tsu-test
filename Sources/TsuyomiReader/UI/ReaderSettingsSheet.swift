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
            themes
            Spacer(minLength: 0)
        }
        .padding(TsuyomiTheme.Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        /// One height, and no second detent to drag it to: this panel is a fixed set of controls over
        /// a page, and a reader who pulls it to full screen has lost the page they were setting.
        .presentationDetents([.height(400)])
        .sheet(isPresented: $isShowingOptions) {
            NavigationStack {
                ReaderSettingsForm(settings: $settings, onChange: onChange, hiding: .offeredInTheReader)
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

    /// The themes, as the pages they make: each tile is drawn in its own colours and says its name, so
    /// the choice is the thing itself rather than a word for it.
    private var themes: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TsuyomiTheme.Metrics.tightGutter), count: 3),
            spacing: TsuyomiTheme.Metrics.tightGutter
        ) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
                Button {
                    var updated = settings
                    updated.theme = theme
                    settings = updated
                    onChange(updated)
                } label: {
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("大").font(.system(size: 22, weight: .bold))
                            Text("小").font(.system(size: 14))
                        }
                        .foregroundStyle(theme.foreground)
                        Text(theme.label)
                            .font(TsuyomiTheme.Typography.badge)
                            .foregroundStyle(theme.foreground.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .background(theme.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                settings.theme == theme
                                    ? TsuyomiTheme.Palette.primaryText
                                    : Color.clear,
                                lineWidth: 2
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.label)
                .accessibilityAddTraits(settings.theme == theme ? [.isSelected] : [])
            }
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
