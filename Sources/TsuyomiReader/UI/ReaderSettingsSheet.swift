// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore
import TsuyomiUI

/// The reader's own way to reach the settings. The controls are `ReaderSettingsForm`, the same ones
/// the settings tab shows: these are not a reader-local copy of the settings but the settings
/// themselves, so a change made here is the change made there.
public struct ReaderSettingsSheet: View {
    @Binding private var settings: ReaderSettings
    private let onChange: (ReaderSettings) -> Void

    public init(settings: Binding<ReaderSettings>, onChange: @escaping (ReaderSettings) -> Void) {
        self._settings = settings
        self.onChange = onChange
    }

    public var body: some View {
        NavigationStack {
            ReaderSettingsForm(settings: $settings, onChange: onChange)
                .navigationTitle("阅读设置")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
    }
}
