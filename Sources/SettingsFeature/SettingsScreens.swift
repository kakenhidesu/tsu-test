// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// Appearance. There is no display profile to choose: iOS has no ink-screen device class, so the only
/// choice is the system light/dark preference.
public struct DisplaySettingsScreen: View {
    @ObservedObject private var preferences: AppPreferences
    @State private var isConfirmingReset = false

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// The three choices are the section; the label is its header, not a row of its own.
    public var body: some View {
        Form {
            Section("外观") {
                Picker("外观", selection: colorScheme) {
                    Text("跟随系统").tag(ColorSchemePreference.system)
                    Text("浅色").tag(ColorSchemePreference.light)
                    Text("深色").tag(ColorSchemePreference.dark)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Button("重置界面偏好", role: .destructive) { isConfirmingReset = true }
            } footer: {
                Text("只恢复外观、书架展示与阅读器排版的默认值。书架、进度、登录状态、已安装的来源与导入记录都不受影响。")
            }
        }
        .navigationTitle("显示")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重置界面偏好？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { preferences.resetInterfacePreferences() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("外观、书架布局与排序、阅读器字号与主题会回到默认值。")
        }
    }

    private var colorScheme: Binding<ColorSchemePreference> {
        Binding(
            get: { preferences.colorScheme },
            set: { preferences.setColorScheme($0) }
        )
    }
}

/// The reader settings, reached from the settings tab rather than from inside a book. They are not
/// defaults that a book then diverges from: there is one set of reader settings, and this screen and
/// the reader's own sheet are two ways to the same values, through the same controls. Changing them
/// never moves a reading position — a locator is semantic, so the same position simply lands on a
/// different page.
public struct ReaderSettingsScreen: View {
    @ObservedObject private var preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        ReaderSettingsForm(settings: settings)
            .navigationTitle("阅读器设置")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Read straight from the store rather than from a snapshot taken when this screen was built, so
    /// what it shows is what a book last left there.
    private var settings: Binding<ReaderSettings> {
        Binding(
            get: { preferences.reader },
            set: { preferences.setReader($0) }
        )
    }
}

public struct AboutScreen: View {
    private let thirdPartyNotices: String

    public init(thirdPartyNotices: String) {
        self.thirdPartyNotices = thirdPartyNotices
    }

    public var body: some View {
        Form {
            Section {
                Text("Tsuyomi 是一个本地优先的阅读器。它不使用账号，不上报使用数据，不做远程配置，也不会把你的书架同步到任何服务器。")
                    .font(TsuyomiTheme.Typography.supporting)
                LabeledContent("版本", value: AboutScreen.version)
            }
            Section("许可证") {
                Text("本程序以 AGPL-3.0-only 授权。")
                    .font(TsuyomiTheme.Typography.supporting)
            }
            Section("第三方组件") {
                Text(thirdPartyNotices)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

