// SPDX-License-Identifier: AGPL-3.0-only

import SettingsFeature
import SwiftUI
import TransferFeature
import TsuyomiUI

enum MoreRoute: Hashable {
    case display
    case readerSettings
    case data
    case transfer
    case help
    case about
}

/// The third tab. Every row is a real destination, so the tab grows by gaining rows rather than by
/// holding placeholders.
struct MoreScreen: View {
    @ObservedObject var container: AppContainer
    @StateObject private var transfer: TransferModel
    @State private var path: [MoreRoute] = []

    init(container: AppContainer) {
        self.container = container
        _transfer = StateObject(
            wrappedValue: TransferModel(
                transfers: container.transfers,
                preferences: container.preferences,
                roots: container.roots
            )
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("设置") {
                    row("显示", "paintpalette", .display)
                    row("阅读器设置", "textformat", .readerSettings)
                }
                Section("数据") {
                    row("数据", "externaldrive", .data)
                    row("数据迁移", "arrow.up.arrow.down.square", .transfer)
                }
                Section {
                    row("帮助", "questionmark.circle", .help)
                    row("关于", "info.circle", .about)
                }
            }
            .navigationTitle("更多")
            .navigationDestination(for: MoreRoute.self) { destination($0) }
        }
    }

    private func row(_ title: LocalizedStringKey, _ symbol: String, _ route: MoreRoute) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: symbol)
        }
    }

    @ViewBuilder
    private func destination(_ route: MoreRoute) -> some View {
        switch route {
        case .display:
            DisplaySettingsScreen(preferences: container.preferences)
        case .readerSettings:
            ReaderSettingsScreen(preferences: container.preferences)
        case .data:
            DataSettingsScreen { path.append(.transfer) }
        case .transfer:
            TransferScreen(model: transfer)
        case .help:
            HelpScreen()
        case .about:
            AboutScreen(thirdPartyNotices: ThirdPartyNotices.text)
        }
    }
}

/// The notices shown in the app are the same text the repository ships, kept here so the About screen
/// cannot drift from `THIRD_PARTY_NOTICES.md`.
enum ThirdPartyNotices {
    static let text = """
    QuickJS-ng 0.16.1 — MIT
    Sources/CQuickJS/quickjs-ng/ (vendored verbatim)
    Upstream: https://github.com/quickjs-ng/quickjs
    Source archive SHA-256:
    4b3c11f37dab2c58bdeccbaeb23b923fa4a9798a45e50be6af55f3e75b616ea0

    Copyright (c) 2017-2021 Fabrice Bellard
    Copyright (c) 2017-2021 Charlie Gordon
    Copyright (c) 2023-2025 Ben Noordhuis
    Copyright (c) 2023-2025 Saúl Ibarra Corretgé

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software \
    and associated documentation files (the "Software"), to deal in the Software without \
    restriction, including without limitation the rights to use, copy, modify, merge, publish, \
    distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the \
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or \
    substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING \
    BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, \
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
