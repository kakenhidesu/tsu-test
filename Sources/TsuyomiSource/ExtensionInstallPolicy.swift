// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// What the host may do with a candidate package given the one it already trusts
/// (hxp-package-v1 §Updates, `package-policy-cases.json`).
public enum ExtensionPolicyOutcome: String, Sendable, Equatable, CaseIterable {
    case accepted = "accepted"
    case requiresGrant = "requires-grant"
    case rejectedRevoked = "rejected-revoked"
    case rejectedKeyRotation = "rejected-key-rotation"
    case rejectedDowngrade = "rejected-downgrade"
    case rejectedReplay = "rejected-replay"
}

public extension ExtensionInstaller {
    /// The single owner of the update rule. Revocation is decided before any version comparison, a
    /// publisher change needs explicit re-approval, and a capability increase always needs a grant
    /// even when the version moves forward.
    static func evaluatePolicy(
        candidate: HxpManifest,
        active: HxpManifest?,
        publisherRevoked: Bool,
        rotationApproved: Bool
    ) -> ExtensionPolicyOutcome {
        if publisherRevoked { return .rejectedRevoked }
        guard let active else {
            return addedCapabilities(candidate, nil).isEmpty ? .accepted : .requiresGrant
        }
        if candidate.publisherKeyId != active.publisherKeyId, !rotationApproved {
            return .rejectedKeyRotation
        }
        if candidate.version == active.version { return .rejectedReplay }
        if candidate.version < active.version { return .rejectedDowngrade }
        if !addedCapabilities(candidate, active).isEmpty { return .requiresGrant }
        if !resourceLimitIncreases(candidate, active).isEmpty { return .requiresGrant }
        return .accepted
    }
}
