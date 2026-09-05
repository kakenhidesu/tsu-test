// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// A semantic target inside an immutable preview plan.
public struct PreviewTarget: Hashable, Sendable {
    public let id: String
    public let locator: ReaderLocator

    public init(id: String, locator: ReaderLocator) throws {
        guard id.contains(where: { !$0.isWhitespace }) else { throw ReaderEngineError.invalidWitness }
        self.id = id
        self.locator = locator
    }
}

/// A preview target request, identified within its session by `generation`.
public struct PreviewRequest: Hashable, Sendable {
    public let target: PreviewTarget
    public let generation: Int64
}

/// Frozen measured geometry available to one preview session. The value copy prevents a UI-owned
/// collection from changing the plan after the session is created.
public struct FrozenPreviewPlan: Sendable {
    public let revision: Int64
    public let targets: Set<PreviewTarget>

    public init(revision: Int64, targets: some Sequence<PreviewTarget>) {
        precondition(revision >= 0, "preview plan revision must not be negative")
        self.revision = revision
        self.targets = Set(targets)
    }

    public func contains(_ target: PreviewTarget) -> Bool { targets.contains(target) }
}

public enum PreviewState: Equatable, Sendable {
    case idle
    case preparing(PreviewTarget)
    case ready(PreviewTarget)
    case released
    case cancelled
}

public enum PreviewReleaseRejection: Sendable, Equatable {
    case noTarget
    case targetNotReady
    case staleEpochs
    case staleOrForeignWitness
    case cancelled
    case alreadyReleased
}

public enum PreviewRelease: Equatable {
    /// The caller may now perform exactly one semantic navigation to `target`.
    case committed(PreviewTarget)
    case rejected(PreviewReleaseRejection)
}

/// Evidence that the independent preview surface visually committed a target.
public struct PreviewVisualWitness: Hashable, Sendable {
    public let sessionId: Int64
    public let target: PreviewTarget
    public let epochs: ReaderEpochs
    public let planRevision: Int64
    public let requestGeneration: Int64
    public let visualEpoch: Int64

    public init(
        sessionId: Int64,
        target: PreviewTarget,
        epochs: ReaderEpochs,
        planRevision: Int64,
        requestGeneration: Int64,
        visualEpoch: Int64
    ) throws {
        guard sessionId >= 0, planRevision >= 0, requestGeneration > 0, visualEpoch >= 0 else {
            throw ReaderEngineError.invalidWitness
        }
        self.sessionId = sessionId
        self.target = target
        self.epochs = epochs
        self.planRevision = planRevision
        self.requestGeneration = requestGeneration
        self.visualEpoch = visualEpoch
    }
}

/// Transient, frozen-plan scrub state. It deliberately owns neither the active reader position nor
/// persistent history; only `release` authorises a single semantic navigation, for the target the
/// preview surface actually drew.
public final class PreviewSession {
    public let sessionId: Int64
    public let epochs: ReaderEpochs
    public let plan: FrozenPreviewPlan

    private var latestInputFrame: Int64 = -1
    private var latestRequest: PreviewRequest?

    public private(set) var state: PreviewState = .idle

    public init(sessionId: Int64, epochs: ReaderEpochs, plan: FrozenPreviewPlan) throws {
        guard sessionId >= 0 else { throw ReaderEngineError.invalidWitness }
        self.sessionId = sessionId
        self.epochs = epochs
        self.plan = plan
        for target in plan.targets { try PreviewSession.requireTarget(target, epochs) }
    }

    public var latestTarget: PreviewTarget? { latestRequest?.target }

    /// The current request, including the generation a visual witness must carry.
    public var currentRequest: PreviewRequest? { latestRequest }

    /// Coalesces pointer input by frame: a later update in the same frame replaces an earlier one,
    /// and an obsolete frame cannot move the preview backwards. Each accepted logical target change
    /// takes the next request generation; a value-equal repeat keeps its current visual witness.
    @discardableResult
    public func offerTarget(inputFrame: Int64, target: PreviewTarget) throws -> PreviewState {
        precondition(inputFrame >= 0, "inputFrame must not be negative")
        if state == .cancelled || state == .released { return state }
        if inputFrame < latestInputFrame { return state }
        try PreviewSession.requireTarget(target, epochs)
        latestInputFrame = inputFrame
        if latestRequest?.target != target {
            let previous = latestRequest?.generation ?? 0
            latestRequest = PreviewRequest(target: target, generation: previous + 1)
        }
        state = plan.contains(target) ? .ready(target) : .preparing(target)
        return state
    }

    /// Convenience for clients that already coalesce input per frame.
    @discardableResult
    public func requestTarget(_ target: PreviewTarget) throws -> PreviewState {
        try offerTarget(inputFrame: latestInputFrame + 1, target: target)
    }

    /// User interaction with the active reader always wins over preview work.
    @discardableResult
    public func cancelForUserInteraction() -> Bool { cancel() }

    /// Explicit cancellation is idempotent and makes visual witnesses unusable.
    @discardableResult
    public func cancel() -> Bool {
        if state == .cancelled || state == .released { return false }
        state = .cancelled
        return true
    }

    /// Cancels when document, session, layout, navigation, or the frozen plan changed.
    @discardableResult
    public func invalidateIfStale(_ currentEpochs: ReaderEpochs, currentPlanRevision: Int64) -> Bool {
        if state == .cancelled || state == .released { return false }
        if currentEpochs == epochs && currentPlanRevision == plan.revision { return false }
        state = .cancelled
        return true
    }

    /// Performs no persistence itself. A successful result grants the coordinator exactly one
    /// release-time semantic navigation; pointer movement never emits a commit.
    public func release(
        witness: PreviewVisualWitness?,
        currentEpochs: ReaderEpochs,
        currentPlanRevision: Int64
    ) -> PreviewRelease {
        switch state {
        case .cancelled: return .rejected(.cancelled)
        case .released: return .rejected(.alreadyReleased)
        case .idle: return .rejected(.noTarget)
        case .preparing: return .rejected(.targetNotReady)
        case .ready: break
        }
        guard currentEpochs == epochs, currentPlanRevision == plan.revision else {
            state = .cancelled
            return .rejected(.staleEpochs)
        }
        guard let request = latestRequest else { return .rejected(.noTarget) }
        guard let witness,
              witness.sessionId == sessionId,
              witness.target == request.target,
              witness.epochs == epochs,
              witness.planRevision == plan.revision,
              witness.requestGeneration == request.generation else {
            return .rejected(.staleOrForeignWitness)
        }
        state = .released
        return .committed(request.target)
    }

    private static func requireTarget(_ target: PreviewTarget, _ epochs: ReaderEpochs) throws {
        guard target.locator.document.namesSameDocument(as: epochs.document) else {
            throw ReaderEngineError.locatorDocumentMismatch
        }
        guard target.locator.document.revision == nil
            || target.locator.document.revision == epochs.documentRevision else {
            throw ReaderEngineError.locatorRevisionMismatch
        }
    }
}
