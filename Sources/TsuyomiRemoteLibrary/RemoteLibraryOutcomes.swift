// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore

/// Stable, user-safe reasons a website operation did not happen. They are the only strings that
/// travel from the coordinator to a screen, so nothing site-authored can ride along.
public enum RemoteLibraryFailure: String, Sendable, Equatable {
    case sourceUnavailable = "source-unavailable"
    case sourceChanged = "source-changed"
    case policyMissing = "remote-policy-missing"
    case readNotGranted = "remote-read-not-granted"
    case targetsNotGranted = "remote-targets-not-granted"
    case addNotAuthorized = "remote-add-not-authorized"
    case removeNotAuthorized = "remote-remove-not-authorized"
    case moveNotAuthorized = "remote-move-not-authorized"
    case blockedUnresolved = "remote-mutation-blocked-unresolved"
    case addNotRetryable = "remote-add-not-retryable"
    case reconciliationNotRetryable = "reconciliation-not-retryable"
    case noReconciliationRecord = "no-reconciliation-record"
    case missingTargetId = "missing-target-id"
    case bookNotInMirror = "book-not-in-mirror"
    case bookAlreadyAdded = "book-already-added"
    case targetedAddDestinationMismatch = "targeted-add-destination-mismatch"
    case recordLimit = "record-limit"
    case pageLimit = "page-limit"
    case duplicateCursor = "duplicate-cursor"
    case completeWithCursor = "complete-with-cursor"
    case sourceIdentityMismatch = "source-identity-mismatch"
    case sourceFailure = "source-failure"

    static func notAuthorized(_ operation: RemoteWriteOperation) -> RemoteLibraryFailure {
        switch operation {
        case .add: return .addNotAuthorized
        case .remove: return .removeNotAuthorized
        case .move: return .moveNotAuthorized
        }
    }
}

/// What reading the site's shelf produced. Only `.success` changed the mirror.
public enum RemoteLibraryPullResult: Sendable, Equatable {
    case success(count: Int)
    case loginRequired
    case verificationRequired
    case cancelled
    case failure(RemoteLibraryFailure, code: String)
}

/// One website write, as the screen that asked for it needs to report it. `.consentRequired` is
/// not a failure: the reader has not yet said this source may write for them, and the same request
/// is repeated once they have.
public enum RemoteMutationResult: Sendable, Equatable {
    case confirmed
    case unresolved
    case cancelled
    case consentRequired(RemoteWriteOperation)
    case loginRequired
    case verificationRequired
    case failure(RemoteLibraryFailure, code: String)
}

/// An add with a destination is two site writes. `.partial` means the book is on the site's shelf
/// in its default folder and the move into the requested folder still has to happen.
public enum RemoteTargetedAddResult: Sendable, Equatable {
    case confirmed(targetId: String?)
    case partial(defaultTargetId: String?, requestedTargetId: String, requestedName: String?, code: String)
    case unresolved
    case cancelled
    case consentRequired(RemoteWriteOperation)
    case loginRequired
    case verificationRequired
    case failure(RemoteLibraryFailure, code: String)

    init(_ result: RemoteMutationResult, targetId: String?) {
        switch result {
        case .confirmed: self = .confirmed(targetId: targetId)
        case .unresolved: self = .unresolved
        case .cancelled: self = .cancelled
        case .consentRequired(let operation): self = .consentRequired(operation)
        case .loginRequired: self = .loginRequired
        case .verificationRequired: self = .verificationRequired
        case .failure(let failure, let code): self = .failure(failure, code: code)
        }
    }
}
