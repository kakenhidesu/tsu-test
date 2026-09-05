// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// Reader typography and navigation settings. Every control writes through immediately, so there is
/// no "apply" step whose failure could leave the surface and the stored settings disagreeing.
public struct ReaderSettingsSheet: View {
    @Binding private var settings: ReaderSettings
    private let onChange: (ReaderSettings) -> Void

    public init(settings: Binding<ReaderSettings>, onChange: @escaping (ReaderSettings) -> Void) {
        self._settings = settings
        self.onChange = onChange
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("排版") {
                    SettingsRow(title: "字号", supporting: "\(Int(settings.fontSize)) pt") {
                        Stepper(
                            "字号",
                            value: binding(\.fontSize),
                            in: ReaderSettings.fontSizeRange,
                            step: 1
                        )
                        .labelsHidden()
                    }
                    SettingsRow(title: "行距", supporting: "\(String(format: "%.1f", settings.lineHeight)) 倍") {
                        Stepper(
                            "行距",
                            value: binding(\.lineHeight),
                            in: ReaderSettings.lineHeightRange,
                            step: 0.1
                        )
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
                    SegmentedSelector(
                        label: "阅读方式",
                        options: [
                            (ReaderPresentation.scroll, "滚动"),
                            (ReaderPresentation.paged, "单页"),
                            (ReaderPresentation.dualPage, "双页")
                        ],
                        selection: binding(\.flow)
                    )
                    Toggle("锁定竖屏", isOn: binding(\.lockPortrait))
                    Toggle("显示进度", isOn: binding(\.progressVisible))
                }

                Section("导航") {
                    Toggle("沉浸模式", isOn: binding(\.immersive))
                    Toggle("阅读时常亮", isOn: binding(\.keepAwake))
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
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
