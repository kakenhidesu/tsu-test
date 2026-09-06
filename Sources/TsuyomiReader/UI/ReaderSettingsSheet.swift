// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// The reader's own settings panel: a card drawn over the page, with a row of controls for the things
/// changed most often, the themes as tiles, and everything else behind 选项. It writes the same
/// `ReaderSettings` the settings tab writes — one set of values, two presentations, each the right
/// one for where it appears. It is exactly as tall as what it holds, and its owner puts it up and
/// takes it down; nothing here is presented except 选项, which is a form and wants a sheet's room.
public struct ReaderSettingsSheet: View {
    @Binding private var settings: ReaderSettings
    @Binding private var appearance: ColorSchemePreference
    private let onChange: (ReaderSettings) -> Void
    private let onClose: () -> Void
    /// The appearance in force, which picks the palette every tile is drawn in — the same one the
    /// page under the card is drawn in.
    @Environment(\.colorScheme) private var colorScheme
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
        }
        .padding(TsuyomiTheme.Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, TsuyomiTheme.Metrics.tightGutter)
        .padding(.bottom, TsuyomiTheme.Metrics.tightGutter)
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.height > 60 { onClose() }
            }
        )
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

    /// One row, one shape: four capsules of one size, so the row reads as one set of controls rather
    /// than three pills and a button. The size capsule carries its dots underneath, which is why the
    /// row lines up on its top edge and not its middle.
    private var controls: some View {
        HStack(alignment: .top, spacing: TsuyomiTheme.Metrics.tightGutter) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    sizeButton(delta: -1, pointSize: 14, label: "缩小字号")
                    Divider().frame(height: 22)
                    sizeButton(delta: 1, pointSize: 22, label: "放大字号")
                }
                .background(TsuyomiTheme.Palette.raisedSurface, in: Capsule())
                sizeDots
            }
            flowMenu
            transitionMenu
            appearanceMenu
        }
    }

    /// The dots are the run itself: the capsule alone says the size can change, the dots say where in
    /// the run it is and how far it can still go.
    private var sizeDots: some View {
        HStack(spacing: 4) {
            ForEach(ReaderSettings.fontSizeSteps.indices, id: \.self) { index in
                Circle()
                    .fill(index <= settings.fontSizeStep ? TsuyomiTheme.Palette.primaryText : Color.clear)
                    .overlay {
                        Circle().strokeBorder(TsuyomiTheme.Palette.primaryText.opacity(0.35), lineWidth: 1)
                    }
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    /// The themes, as the pages they make: each tile is drawn in the palette in force right now and
    /// says its name, so the choice is the thing itself rather than a word for it.
    private var themes: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: TsuyomiTheme.Metrics.tightGutter), count: 3),
            spacing: TsuyomiTheme.Metrics.tightGutter
        ) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
                themeTile(theme)
            }
        }
    }

    private func themeTile(_ theme: ReaderTheme) -> some View {
        let palette = theme.palette(for: colorScheme)
        let selected = settings.theme == theme
        return Button {
            var updated = settings
            updated.theme = theme
            settings = updated
            onChange(updated)
        } label: {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("大").font(.system(size: 22, weight: theme == .bold ? .heavy : .semibold))
                    Text("小").font(.system(size: 14, weight: theme == .bold ? .bold : .regular))
                }
                .foregroundStyle(palette.foreground)
                Text(theme.label)
                    .font(TsuyomiTheme.Typography.badge)
                    .foregroundStyle(palette.foreground.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        selected ? TsuyomiTheme.Palette.primaryText : TsuyomiTheme.Palette.separator,
                        lineWidth: selected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func sizeButton(delta: Int, pointSize: CGFloat, label: LocalizedStringKey) -> some View {
        let enabled = settings.canStepFontSize(delta)
        return Button {
            var updated = settings
            updated.stepFontSize(delta)
            settings = updated
            onChange(updated)
        } label: {
            Text("字")
                .font(.system(size: pointSize))
                .foregroundStyle(enabled ? TsuyomiTheme.Palette.primaryText : TsuyomiTheme.Palette.tertiaryText)
                .frame(maxWidth: .infinity)
                .frame(height: TsuyomiTheme.Metrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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

    /// The page's light or dark lives here because it is the app's appearance, not a reader-only
    /// theme: a theme is two palettes, and this is what chooses between them.
    private var appearanceMenu: some View {
        controlMenu(symbol: "circle.lefthalf.filled", label: "外观") {
            Picker("外观", selection: $appearance) {
                Label("浅色", systemImage: "sun.max").tag(ColorSchemePreference.light)
                Label("深色", systemImage: "moon").tag(ColorSchemePreference.dark)
                Label("匹配设备", systemImage: "circle.lefthalf.filled").tag(ColorSchemePreference.system)
            }
        }
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
