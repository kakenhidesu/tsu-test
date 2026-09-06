// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// Appearance. There is no display profile to choose: iOS has no ink-screen device class, so the only
/// choice is the system light/dark preference.
public struct DisplaySettingsScreen: View {
    @ObservedObject private var preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: colorScheme) {
                    Text("跟随系统").tag(ColorSchemePreference.system)
                    Text("浅色").tag(ColorSchemePreference.light)
                    Text("深色").tag(ColorSchemePreference.dark)
                }
                .pickerStyle(.inline)
            }
        }
        .navigationTitle("显示")
        .navigationBarTitleDisplayMode(.inline)
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

/// What a transfer file does and does not contain, stated where the reader decides to make one.
public struct DataSettingsScreen: View {
    private let openTransfer: () -> Void

    public init(openTransfer: @escaping () -> Void) {
        self.openTransfer = openTransfer
    }

    public var body: some View {
        Form {
            Section("包含") {
                Text("书架条目、收藏夹与智能规则、本地标签、评分与稍后再读、阅读进度、搜索与浏览历史、阅读偏好。")
                    .font(TsuyomiTheme.Typography.supporting)
            }
            Section("不包含") {
                Text("登录凭据与 Cookie、下载的正文与封面缓存、已安装的扩展包及其发布者信任。")
                    .font(TsuyomiTheme.Typography.supporting)
            }
            Section {
                Button("打开数据迁移") { openTransfer() }
            }
        }
        .navigationTitle("数据")
        .navigationBarTitleDisplayMode(.inline)
    }
}

public struct HelpScreen: View {
    @State private var query = ""

    public init() {}

    public var body: some View {
        List {
            ForEach(HelpTopic.matching(query)) { topic in
                DisclosureGroup(topic.question) {
                    Text(topic.answer)
                        .font(TsuyomiTheme.Typography.supporting)
                        .foregroundStyle(TsuyomiTheme.Palette.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "搜索帮助")
        .navigationTitle("帮助")
        .navigationBarTitleDisplayMode(.inline)
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

extension ReaderTheme {
    var label: LocalizedStringKey {
        switch self {
        case .paper: return "纸白"
        case .warmGray: return "暖灰"
        case .nightInk: return "夜墨"
        case .black: return "纯黑"
        case .inkGreen: return "护眼绿"
        }
    }
}
