// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TsuyomiCore

/// The app's scene. The executable target declares `@main` over this so the whole composition stays
/// buildable and testable as a library.
public struct TsuyomiRootScene: Scene {
    @StateObject private var container: AppContainer
    @StateObject private var flow: SourceFlowController
    @StateObject private var scheduler: UpdateScheduler
    @Environment(\.scenePhase) private var scenePhase

    /// The background task is registered here, before any scene body runs: the system accepts a
    /// registration only while the app is still launching.
    public init() {
        let built = TsuyomiRootScene.build()
        let scheduler = UpdateScheduler(coordinator: built.updateCoordinator, updates: built.updates)
        scheduler.register()
        _container = StateObject(wrappedValue: built)
        _flow = StateObject(wrappedValue: SourceFlowController(container: built))
        _scheduler = StateObject(wrappedValue: scheduler)
    }

    public var body: some Scene {
        WindowGroup {
            AppRootView(container: container, flow: flow, scheduler: scheduler)
                .task { await scheduler.reschedule() }
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
