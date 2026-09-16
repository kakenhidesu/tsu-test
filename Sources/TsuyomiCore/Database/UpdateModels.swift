// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public enum UpdateCadence: String, Sendable, CaseIterable {
    case off = "OFF"
    case hours12 = "HOURS_12"
    case daily = "DAILY"
    case days3 = "DAYS_3"
    case weekly = "WEEKLY"

    public var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .hours12: return 12 * 3600
        case .daily: return 24 * 3600
        case .days3: return 72 * 3600
        case .weekly: return 168 * 3600
        }
    }
}

/// When checks may run on their own. Off by default; the constraints only matter once a cadence is
/// chosen, and nothing here ever authorizes a check the reader did not ask for or schedule.
public struct UpdatePolicy: Hashable, Sendable {
    public let cadence: UpdateCadence
    public let unmeteredOnly: Bool
    public let requiresCharging: Bool
    public let batteryNotLow: Bool

    public init(cadence: UpdateCadence = .off, unmeteredOnly: Bool = true, requiresCharging: Bool = false, batteryNotLow: Bool = true) {
        self.cadence = cadence
        self.unmeteredOnly = unmeteredOnly
        self.requiresCharging = requiresCharging
        self.batteryNotLow = batteryNotLow
    }
}

public enum UpdateSessionTrigger: String, Sendable {
    case manual
    case scheduled
}

public enum UpdateSessionState: String, Sendable, CaseIterable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case completed = "COMPLETED"
    case partial = "PARTIAL"
    case failed = "FAILED"
    case cancelled = "CANCELLED"

    public var isTerminal: Bool { self != .queued && self != .running }
}

public enum UpdateItemState: String, Sendable, CaseIterable {
    case pending = "PENDING"
    case unchanged = "UNCHANGED"
    case updated = "UPDATED"
    case skipped = "SKIPPED"
    case unavailable = "UNAVAILABLE"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
}

public struct UpdateSessionSummary: Hashable, Sendable {
    public let sessionId: String
    public let trigger: UpdateSessionTrigger
    public let state: UpdateSessionState
    public let total: Int
    public let completed: Int
    public let updated: Int
    public let failed: Int
    public let reason: String?
    public let cancellationRequested: Bool
    public let startedAt: Date
    public let finishedAt: Date?
}

public struct UpdateSessionItemSummary: Hashable, Sendable {
    public let identity: BookIdentity
    public let capturedTitle: String
    public let state: UpdateItemState
    public let reason: String?
    public let anchor: String?
}

/// A running session's right to write: every mutation carries the owner token and is refused once
/// the lease lapsed, so a relaunched app cannot race a session that a dead process still owned.
public struct UpdateSessionLease: Hashable, Sendable {
    public let sessionId: String
    public let ownerToken: String
    public let expiresAt: Date
}

public struct UpdateBaseline: Hashable, Sendable {
    public let identity: BookIdentity
    public let anchor: String
    public let chapters: [UpdateCheckChapter]
    public let lastUpdatedDate: String?
    public let updatedAt: Date
}

/// One book the inbox is holding: the newest full chapter list, which of those chapters are new
/// since the reader's baseline, and the revision that an ignore must name exactly.
public struct UnresolvedUpdate: Hashable, Sendable {
    public let identity: BookIdentity
    public let title: String
    public let anchor: String
    public let chapters: [UpdateCheckChapter]
    public let newChapterIds: [String]
    public let lastUpdatedDate: String?
    public let detectedAt: Date
    public let revision: Int64

    public init(
        identity: BookIdentity,
        title: String,
        anchor: String,
        chapters: [UpdateCheckChapter],
        newChapterIds: [String],
        lastUpdatedDate: String?,
        detectedAt: Date,
        revision: Int64
    ) {
        self.identity = identity
        self.title = title
        self.anchor = anchor
        self.chapters = chapters
        self.newChapterIds = newChapterIds
        self.lastUpdatedDate = lastUpdatedDate
        self.detectedAt = detectedAt
        self.revision = revision
    }
}

public struct UpdateCandidate: Hashable, Sendable {
    public let identity: BookIdentity
    public let title: String

    public init(identity: BookIdentity, title: String) {
        self.identity = identity
        self.title = title
    }
}

public enum UpdateProbeOutcome: String, Sendable {
    case unchanged = "UNCHANGED"
    case updated = "UPDATED"
    case unavailable = "UNAVAILABLE"
    case failed = "FAILED"
}

/// The result of one signed update check after admission (hxp-host-api-v1 §Signed update check v2).
/// The invariants per outcome are what a caller may rely on: an unchanged or updated result always
/// carries a real anchor and the full list, a refused one never carries evidence.
public struct UpdateProbeResult: Hashable, Sendable {
    public static let reasonLimit = 128

    public let identity: BookIdentity
    public let outcome: UpdateProbeOutcome
    public let previousAnchor: String?
    public let anchor: String?
    public let chapters: [UpdateCheckChapter]
    public let newChapterIds: [String]
    public let lastUpdatedDate: String?
    public let reason: String?

    public init(
        identity: BookIdentity,
        outcome: UpdateProbeOutcome,
        previousAnchor: String?,
        anchor: String?,
        chapters: [UpdateCheckChapter],
        newChapterIds: [String],
        lastUpdatedDate: String?,
        reason: String?
    ) throws {
        switch outcome {
        case .unchanged:
            guard anchor != nil, !chapters.isEmpty, newChapterIds.isEmpty, reason == nil else {
                throw DatabaseError.invariantViolated("An unchanged probe carries an anchor and no delta")
            }
        case .updated:
            guard previousAnchor != nil, anchor != nil, !newChapterIds.isEmpty, reason == nil else {
                throw DatabaseError.invariantViolated("An updated probe carries both anchors and a delta")
            }
        case .unavailable, .failed:
            guard anchor == nil, chapters.isEmpty, newChapterIds.isEmpty, lastUpdatedDate == nil,
                  let reason, UpdateProbeResult.isReason(reason) else {
                throw DatabaseError.invariantViolated("A refused probe carries only a bounded reason")
            }
        }
        guard Set(newChapterIds).isSubset(of: Set(chapters.map(\.chapterId))) else {
            throw DatabaseError.invariantViolated("The delta must be part of the chapter list")
        }
        self.identity = identity
        self.outcome = outcome
        self.previousAnchor = previousAnchor
        self.anchor = anchor
        self.chapters = chapters
        self.newChapterIds = newChapterIds
        self.lastUpdatedDate = lastUpdatedDate
        self.reason = reason
    }

    /// `^[a-z][a-z0-9._-]{0,127}$`: a token the interface can map to a label, never free text.
    public static func isReason(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...reasonLimit).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
}
