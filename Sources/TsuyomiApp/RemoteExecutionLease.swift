// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The exact package, capability set and generations a multi-page remote operation started under.
/// A reinstall, a capability change or a new owner between pages invalidates the whole run rather
/// than letting half of it be attributed to the new state.
public struct RemoteExecutionLease: Hashable, Sendable {
    public let packageSha256: String
    public let packageVersion: String
    public let capabilitySetFingerprint: String
    public let sourceGeneration: Int64
    public let ownerGeneration: Int64

    public init(
        packageSha256: String,
        packageVersion: String,
        capabilitySetFingerprint: String,
        sourceGeneration: Int64,
        ownerGeneration: Int64
    ) {
        self.packageSha256 = packageSha256
        self.packageVersion = packageVersion
        self.capabilitySetFingerprint = capabilitySetFingerprint
        self.sourceGeneration = sourceGeneration
        self.ownerGeneration = ownerGeneration
    }

    public func matches(
        packageSha256: String?,
        packageVersion: String?,
        verifiedSourceVersion: String?,
        capabilitySetFingerprint: String?,
        sourceGeneration: Int64?,
        ownerGeneration: Int64
    ) -> Bool {
        self.packageSha256 == packageSha256
            && self.packageVersion == packageVersion
            && self.packageVersion == verifiedSourceVersion
            && self.capabilitySetFingerprint == capabilitySetFingerprint
            && self.sourceGeneration == sourceGeneration
            && self.ownerGeneration == ownerGeneration
    }
}
