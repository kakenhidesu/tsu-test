// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// How a run ended for the caller that asked for it. The session's own record is in the store.
public enum UpdateRunOutcome: Sendable, Equatable {
    /// The session reached a terminal state under this process, whatever the items said.
    case completed(sessionId: String)
    /// Another live session holds the lane; nothing was started.
    case busy
    /// This process lost its lease mid-run; the session is queued for whoever claims it next.
    case relinquished
    /// A run was already in progress in this process; the request folded into it.
    case coalesced
}

/// Runs one update session at a time: enumerates the books in scope, asks each source with a signed
/// update check, and records every answer under a lease it renews as it goes. It never decides
/// what an update means for the reader — that is the inbox's, and completion's, business.
public actor UpdateCoordinator {
    public static let pageSize = 32
    /// A lease is renewed once less than a third of it remains.
    static let renewalWindow: TimeInterval = 40

    private let registry: SourceRegistry
    private let updates: UpdateStore
    private let library: LibraryRepository
    private let mirror: RemoteMirrorStore
    private let remoteLibrary: RemoteLibraryStore
    private let progress: ReadingProgressStore
    private let clock: @Sendable () -> Date
    private var running = false

    public init(
        registry: SourceRegistry,
        updates: UpdateStore,
        library: LibraryRepository,
        mirror: RemoteMirrorStore,
        remoteLibrary: RemoteLibraryStore,
        progress: ReadingProgressStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.updates = updates
        self.library = library
        self.mirror = mirror
        self.remoteLibrary = remoteLibrary
        self.progress = progress
        self.clock = clock
    }

    public var isRunning: Bool { running }

    /// What a session may check: every pinned shelf book and every book in a live website mirror,
    /// each once. Exclusions and the size bound are applied when the session opens.
    public func candidates() async throws -> [UpdateCandidate] {
        var seen = Set<BookIdentity>()
        var result: [UpdateCandidate] = []
        for entry in try await library.libraryEntries() where seen.insert(entry.book.identity).inserted {
            result.append(UpdateCandidate(identity: entry.book.identity, title: entry.book.title))
        }
        for binding in try await mirror.bindings() where !binding.frozen {
            guard let stored = try await mirror.mirror(sourceId: binding.sourceId) else { continue }
            for item in stored.items where seen.insert(item.identity).inserted {
                let title = try await library.book(item.identity)?.title ?? item.identity.remoteBookId
                result.append(UpdateCandidate(identity: item.identity, title: title))
            }
        }
        return result
    }

    /// Starts a session, or resumes one an earlier process left queued, and drains it.
    public func run(trigger: UpdateSessionTrigger) async -> UpdateRunOutcome {
        guard !running else { return .coalesced }
        running = true
        defer { running = false }
        try? await updates.recoverExpiredSessions(now: clock())
        let lease: UpdateSessionLease
        if let claimed = try? await updates.claimQueuedSession(now: clock()) {
            lease = claimed
        } else {
            let candidates = (try? await candidates()) ?? []
            guard let started = try? await updates.startSession(trigger: trigger, candidates: candidates, now: clock()) else {
                return .busy
            }
            lease = started
        }
        return await drain(lease)
    }

    /// Cancellation is written first, so it holds whether or not this process finishes the loop.
    public func cancel() async -> Bool {
        (try? await updates.cancelActiveSession(now: clock())) ?? false
    }

    private func drain(_ initial: UpdateSessionLease) async -> UpdateRunOutcome {
        var lease = initial
        while true {
            if (try? await updates.isCancellationRequested(lease)) == true { return .completed(sessionId: lease.sessionId) }
            guard let batch = try? await updates.pendingCandidates(lease, limit: UpdateCoordinator.pageSize, now: clock()),
                  !batch.isEmpty else { return .completed(sessionId: lease.sessionId) }
            for candidate in batch {
                if (try? await updates.isCancellationRequested(lease)) == true { return .completed(sessionId: lease.sessionId) }
                if lease.expiresAt.timeIntervalSince(clock()) < UpdateCoordinator.renewalWindow {
                    guard let renewed = try? await updates.renewLease(lease, now: clock()) else { return .relinquished }
                    lease = renewed
                }
                await probe(candidate, lease: lease)
            }
        }
    }

    /// One book. Eligibility is re-read here rather than trusted from enumeration, the source lease
    /// is checked on both sides of the request, and every way out records something.
    private func probe(_ candidate: UpdateCandidate, lease: UpdateSessionLease) async {
        let identity = candidate.identity
        guard await inScope(identity) else {
            try? await updates.skipItem(lease, identity, reason: "ineligible", now: clock())
            return
        }
        let previous = (try? await updates.baseline(identity))?.anchor
        let completed = Set((try? await progress.completedChapterIds(identity)) ?? [])
        func record(_ result: UpdateProbeResult) async {
            _ = try? await updates.recordProbe(lease, result: result, completedChapterIds: completed, now: clock())
        }
        func refuse(_ outcome: UpdateProbeOutcome, _ reason: String) async {
            guard let refused = try? UpdateCheckAdmission.refused(identity, outcome, previousAnchor: previous, reason: reason) else {
                try? await updates.skipItem(lease, identity, reason: "ineligible", now: clock())
                return
            }
            await record(refused)
        }
        guard let sourceId = try? SourceId(identity.sourceId),
              let before = try? await remoteLibrary.sourceAvailability(sourceId.value), before.available,
              let client = try? await registry.client(for: sourceId) else {
            await refuse(.unavailable, "source-unavailable")
            return
        }
        guard client.supportsUpdateChecks else {
            await refuse(.failed, "updates-not-supported")
            return
        }
        guard before.verifiedVersion == client.manifest.version.original else {
            await refuse(.failed, "stale-source-lease")
            return
        }
        do {
            let result = try await client.checkUpdates(remoteBookId: identity.remoteBookId, previousAnchor: previous)
            let after = try? await remoteLibrary.sourceAvailability(sourceId.value)
            guard after?.available == true, after?.generation == before.generation else {
                await refuse(.failed, "stale-source-lease")
                return
            }
            await record(result)
        } catch let failure as SourceException {
            let reason = UpdateCheckAdmission.reason(
                code: failure.code, stage: failure.diagnostic.stage, safeCode: failure.diagnostic.safeCode
            )
            switch failure.code {
            case .extensionCancelled:
                try? await updates.skipItem(lease, identity, reason: "cancelled", now: clock())
            case .sessionRequired, .verificationRequired, .networkTimeout, .networkOffline:
                await refuse(.unavailable, reason)
            default:
                await refuse(.failed, reason)
            }
        } catch {
            await refuse(.failed, "source-failure")
        }
    }

    /// In scope means pinned on the shelf, or listed by a live website mirror.
    private func inScope(_ identity: BookIdentity) async -> Bool {
        if (try? await library.libraryEntry(identity))?.localMembership == true { return true }
        guard (try? await mirror.membership(identity)) != nil,
              let stored = try? await mirror.mirror(sourceId: identity.sourceId) else { return false }
        return !stored.binding.frozen
    }
}
