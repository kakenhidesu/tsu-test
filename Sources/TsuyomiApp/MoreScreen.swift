// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TransferFeature
import TsuyomiUI

/// The third tab. It lists the things that are neither a shelf nor a source; each row is a real
/// destination, so the tab grows by gaining rows rather than by holding placeholders.
struct MoreScreen: View {
    @ObservedObject var container: AppContainer
    @StateObject private var transfer: TransferModel

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
        NavigationStack {
            List {
                NavigationLink {
                    TransferScreen(model: transfer)
                } label: {
                    Label("数据迁移", systemImage: "arrow.up.arrow.down.square")
                        .frame(minHeight: TsuyomiTheme.Metrics.minimumTouchTarget)
                }
            }
            .navigationTitle("更多")
        }
    }
}
