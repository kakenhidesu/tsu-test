// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Lifecycle of a compatible presentation switch.
public enum PresentationSwitchState: Sendable, Equatable {
    case awaitingTargetVisualCommit
    case committed
    case cancelled
}

/// Why a switch could not start or a visual commit was rejected.
public enum PresentationSwitchRejection: Sendable, Equatable {
    case noExactSettledCapture
    case incompatibleDocument
    case staleEpochs
    case staleOrForeignWitness
    case cancelled
    case alreadyCommitted
}

public enum PresentationSwitchStart {
    case started(PresentationSwitchTransaction)
    case rejected(PresentationSwitchRejection)
}

public enum PresentationSwitchCommit: Equatable {
    case accepted(SettledPositionSnapshot)
    case rejected(PresentationSwitchRejection)
}

/// Complete immutable input for starting one compatible presentation handoff.
public struct PresentationSwitchRequest {
    public let transactionId: Int64
    public let targetId: String
    public let sourceEpochs: ReaderEpochs
    public let targetEpochs: ReaderEpochs
    public let captures: SettledPositionCache
    public let mountedCapture: SettledPositionSnapshot?
    public let mountedRendererIsRebuilding: Bool

    public init(
        transactionId: Int64,
        targetId: String,
        sourceEpochs: ReaderEpochs,
        targetEpochs: ReaderEpochs,
        captures: SettledPositionCache,
        mountedCapture: SettledPositionSnapshot?,
        mountedRendererIsRebuilding: Bool
    ) {
        self.transactionId = transactionId
        self.targetId = targetId
        self.sourceEpochs = sourceEpochs
        self.targetEpochs = targetEpochs
        self.captures = captures
        self.mountedCapture = mountedCapture
        self.mountedRendererIsRebuilding = mountedRendererIsRebuilding
    }
}

/// A cancellation-aware handoff across compatible reader presentations. It has no persistence hook:
/// a successful visual commit merely authorises the caller to resume progress writes and preloading.
public final class PresentationSwitchTransaction {
    public let transactionId: Int64
    public let targetId: String
    public let sourceEpochs: ReaderEpochs
    public let targetEpochs: ReaderEpochs
    public let capture: SettledPositionSnapshot
    public private(set) var state: PresentationSwitchState = .awaitingTargetVisualCommit

    private init(
        transactionId: Int64,
        targetId: String,
        sourceEpochs: ReaderEpochs,
        targetEpochs: ReaderEpochs,
        capture: SettledPositionSnapshot
    ) {
        self.transactionId = transactionId
        self.targetId = targetId
        self.sourceEpochs = sourceEpochs
        self.targetEpochs = targetEpochs
        self.capture = capture
    }

    public var isActive: Bool { state == .awaitingTargetVisualCommit }

    /// Rejects future commits. Cancellation is idempotent.
    @discardableResult
    public func cancel() -> Bool {
        guard isActive else { return false }
        state = .cancelled
        return true
    }

    /// Cancels when any document, session, layout, or navigation provenance changed since mount.
    @discardableResult
    public func invalidateIfStale(_ currentTargetEpochs: ReaderEpochs) -> Bool {
        guard isActive, currentTargetEpochs != targetEpochs else { return false }
        state = .cancelled
        return true
    }

    /// Accepts only the target surface's current witness. A rejected old witness leaves the
    /// transaction open so the current target can still commit.
    public func acceptVisualCommit(
        _ witness: VisualCommitWitness,
        currentTargetEpochs: ReaderEpochs
    ) -> PresentationSwitchCommit {
        switch state {
        case .cancelled: return .rejected(.cancelled)
        case .committed: return .rejected(.alreadyCommitted)
        case .awaitingTargetVisualCommit: break
        }
        guard currentTargetEpochs == targetEpochs else {
            state = .cancelled
            return .rejected(.staleEpochs)
        }
        guard witness.ownerId == transactionId,
              witness.targetId == targetId,
              witness.epochs == targetEpochs else {
            return .rejected(.staleOrForeignWitness)
        }
        state = .committed
        return .accepted(capture)
    }

    /// Freezes a compatible transition. Source and target may use different metric layout keys and
    /// epochs, but every document, session, and navigation identity must be identical.
    public static func begin(_ request: PresentationSwitchRequest) -> PresentationSwitchStart {
        precondition(request.transactionId >= 0, "transactionId must not be negative")
        precondition(
            request.targetId.contains { !$0.isWhitespace },
            "targetId must not be blank"
        )
        guard areCompatible(request.sourceEpochs, request.targetEpochs) else {
            return .rejected(.incompatibleDocument)
        }
        guard let capture = request.captures.selectForPresentationSwitch(
            source: request.sourceEpochs,
            mountedCapture: request.mountedCapture,
            mountedRendererIsRebuilding: request.mountedRendererIsRebuilding
        ) else {
            return .rejected(.noExactSettledCapture)
        }
        return .started(
            PresentationSwitchTransaction(
                transactionId: request.transactionId,
                targetId: request.targetId,
                sourceEpochs: request.sourceEpochs,
                targetEpochs: request.targetEpochs,
                capture: capture
            )
        )
    }

    private static func areCompatible(_ source: ReaderEpochs, _ target: ReaderEpochs) -> Bool {
        source.document.namesSameDocument(as: target.document)
            && source.documentRevision == target.documentRevision
            && source.contentDigest == target.contentDigest
            && source.documentEpoch == target.documentEpoch
            && source.sessionEpoch == target.sessionEpoch
            && source.navigationEpoch == target.navigationEpoch
    }
}
