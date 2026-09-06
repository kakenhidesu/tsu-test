// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore

/// Every reader setting there is, in one place. The reader's own sheet and the settings tab show this
/// same form rather than each listing the controls again: two lists of the same settings drift, and
/// they had — one of them was already missing the page turn. Every control writes through
/// immediately, so there is no "apply" step whose failure could leave the surface and the stored
/// settings disagreeing.
public struct ReaderSettingsForm: View {
    @Binding private var settings: ReaderSettings
    private let onChange: (ReaderSettings) -> Void

    /// Every control writes through the binding. `onChange` is for a caller that has to do something
    /// beyond storing the value — the reader has to repaginate — and defaults to nothing.
    public init(settings: Binding<ReaderSettings>, onChange: @escaping (ReaderSettings) -> Void = { _ in }) {
        self._settings = settings
        self.onChange = onChange
    }

    public var body: some View {
        Form {
            Section("排版") {
                SettingsRow(title: "字号", supporting: "\(Int(settings.fontSize)) pt") {
                    Stepper("字号", value: binding(\.fontSize), in: ReaderSettings.fontSizeRange, step: 1)
                        .labelsHidden()
                }
                SettingsRow(title: "行距", supporting: "\(String(format: "%.1f", settings.lineHeight)) 倍") {
                    Stepper("行距", value: binding(\.lineHeight), in: ReaderSettings.lineHeightRange, step: 0.1)
                        .labelsHidden()
                }
                SettingsRow(title: "页边距", supporting: "\(Int(settings.horizontalMargin)) pt") {
                    Stepper(
                        "页边距",
                        value: binding(\.horizontalMargin),
                        in: ReaderSettings.horizontalMarginRange,
                        step: 4
                    )
                    .labelsHidden()
                }
                SettingsRow(title: "段间距", supporting: "\(Int(settings.paragraphSpacing)) pt") {
                    Stepper(
                        "段间距",
                        value: binding(\.paragraphSpacing),
                        in: ReaderSettings.paragraphSpacingRange,
                        step: 2
                    )
                    .labelsHidden()
                }
                Picker("阅读主题", selection: binding(\.theme)) {
                    ForEach(ReaderTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
            }

            Section("翻页") {
                SegmentedSelector(label: "阅读方式", options: flowOptions, selection: binding(\.flow))
                SegmentedSelector(
                    label: "翻页效果",
                    options: transitionOptions,
                    selection: binding(\.pageTransition)
                )
                Toggle("锁定竖屏", isOn: binding(\.lockPortrait))
                Toggle("显示进度", isOn: binding(\.progressVisible))
            }

            Section("导航") {
                Toggle("沉浸模式", isOn: binding(\.immersive))
                Toggle("阅读时常亮", isOn: binding(\.keepAwake))
            }
        }
    }

    private var flowOptions: [(value: ReaderPresentation, title: LocalizedStringKey)] {
        [(.scroll, "滚动"), (.paged, "单页"), (.dualPage, "双页")]
    }

    private var transitionOptions: [(value: ReaderPageTransition, title: LocalizedStringKey)] {
        [(.slide, "滑动"), (.curl, "卷页"), (.immediate, "无")]
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReaderSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var updated = settings
                updated[keyPath: keyPath] = newValue
                settings = updated
                onChange(updated)
            }
        )
    }
}
