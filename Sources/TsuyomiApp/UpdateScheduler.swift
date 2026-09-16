// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Network
import os
import TsuyomiCore
import TsuyomiUpdates
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Periodic update checks on iOS run as a background processing task. The policy row is the source
/// of truth: registering happens once before launch finishes, and every policy change re-submits
/// one request whose earliest date is one interval away. There is no notification and no retry
/// loop; a run that could not happen is simply asked for again next time.
@MainActor
public final class UpdateScheduler: ObservableObject {
    public nonisolated static let taskIdentifier = "org.tsuyomi.ios.updates.refresh"

    private let coordinator: UpdateCoordinator
    private let updates: UpdateStore
    #if canImport(BackgroundTasks)
    private var activeTask: BGProcessingTask?
    #endif

    public init(coordinator: UpdateCoordinator, updates: UpdateStore) {
        self.coordinator = coordinator
        self.updates = updates
    }

    /// Must be called before the app finishes launching; the system refuses later registrations.
    /// The task object the system hands over is not `Sendable`, and it has to reach the main actor
    /// where this object lives: `nonisolated(unsafe)` states that hand-over explicitly. It is sound
    /// because the handler uses the task nowhere else, and BGTask's own methods are thread-safe.
    public nonisolated func register() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: UpdateScheduler.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let handed = processing
            Task { @MainActor in self.begin(handed) }
        }
        #endif
    }

    /// Re-submits the one pending request to match the policy. Off cancels it.
    public func reschedule() async {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: UpdateScheduler.taskIdentifier)
        guard let policy = try? await updates.policy(), let interval = policy.cadence.interval else { return }
        let request = BGProcessingTaskRequest(identifier: UpdateScheduler.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(interval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = policy.requiresCharging
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(BackgroundTasks)
    /// The system's own constraints cover connectivity and power. Metered and low-battery limits are
    /// checked here, at the moment the task starts, and a run that fails them is deferred whole.
    private func begin(_ task: BGProcessingTask) {
        activeTask?.setTaskCompleted(success: false)
        activeTask = task
        let coordinator = self.coordinator
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                _ = await coordinator.cancel()
                self?.finish(success: false)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await self.constraintsAllowRun()
            guard allowed else {
                self.finish(success: true)
                return
            }
            let outcome = await coordinator.run(trigger: .scheduled)
            self.finish(success: outcome != .relinquished)
        }
    }

    private func finish(success: Bool) {
        activeTask?.setTaskCompleted(success: success)
        activeTask = nil
        Task { await reschedule() }
    }

    private func constraintsAllowRun() async -> Bool {
        guard let policy = try? await updates.policy(), policy.cadence != .off else { return false }
        if policy.unmeteredOnly, await NetworkPath.isExpensive() { return false }
        if policy.batteryNotLow, UpdateScheduler.batteryIsLow { return false }
        return true
    }

    private static var batteryIsLow: Bool {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 && level < 0.2 && UIDevice.current.batteryState == .unplugged
        #else
        return false
        #endif
    }
    #endif
}

/// One reading of the current network path. A monitor answers asynchronously, so the first update
/// is awaited and the monitor released; a path that never reports counts as not expensive.
enum NetworkPath {
    static func isExpensive() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let claimed = OSAllocatedUnfairLock(initialState: false)
            let claim: @Sendable () -> Bool = {
                claimed.withLock { flag in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
            }
            monitor.pathUpdateHandler = { path in
                guard claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "org.tsuyomi.network-path"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard claim() else { return }
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
