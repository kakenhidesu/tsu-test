// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore

/// The app's scene. The executable target declares `@main` over this so the whole composition stays
/// buildable and testable as a library.
public struct TsuyomiRootScene: Scene {
    @StateObject private var container: AppContainer
    @StateObject private var flow: SourceFlowController
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        let built = TsuyomiRootScene.build()
        _container = StateObject(wrappedValue: built)
        _flow = StateObject(wrappedValue: SourceFlowController(container: built))
    }

    public var body: some Scene {
        WindowGroup {
            AppRootView(container: container, flow: flow)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .background else { return }
            Task { await container.registry.closeAll() }
        }
    }

    /// The store lives in Application Support so it is not offered to the system as reclaimable, and
    /// the app has no iCloud container: nothing here syncs anywhere.
    private static func build() -> AppContainer {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        do {
            return try AppContainer(
                base: base.appendingPathComponent("Tsuyomi", isDirectory: true),
                defaults: UserDefaults(suiteName: AppPreferences.suiteName) ?? .standard
            )
        } catch {
            fatalError("Tsuyomi cannot open its local store: \(error)")
        }
    }
}
