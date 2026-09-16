// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public enum ResourceLimit: String, Sendable, CaseIterable {
    case maximumExecutionWallTimeMs = "MAX_EXECUTION_WALL_TIME_MS"
    case maximumMemoryBytes = "MAX_MEMORY_BYTES"
    case storageQuotaBytes = "STORAGE_QUOTA_BYTES"
    case networkConcurrentRequests = "NETWORK_CONCURRENT_REQUESTS"
    case networkRequestTimeoutMs = "NETWORK_REQUEST_TIMEOUT_MS"
    case networkResponseBytes = "NETWORK_RESPONSE_BYTES"
}

public struct ResourceLimitIncrease: Hashable, Sendable {
    public let limit: ResourceLimit
    public let activeValue: Int64
    public let candidateValue: Int64
}

public struct PreparedExtensionInstall: Sendable {
    public let candidate: VerifiedHxpPackage
    public let active: VerifiedHxpPackage?
    public let addedCapabilities: [String]
    public let resourceLimitIncreases: [ResourceLimitIncrease]
    public let capabilityGrantFingerprint: String
    public let remoteCapabilitySetFingerprint: String
    public let isDowngrade: Bool
    public let policyOutcome: ExtensionPolicyOutcome
    /// A user-added publisher's package runs in this process only after the reader says so, once,
    /// for exactly this archive.
    public let requiresNonOfficialConsent: Bool
    /// The catalog's root-signed migration allows a publisher change; the reader still confirms it.
    public let requiresMigrationConsent: Bool
}

/// The consents an approval may carry beyond the package itself.
public struct ExtensionInstallConsent: Hashable, Sendable {
    public let allowLocalDowngrade: Bool
    public let nonOfficialExecution: Bool
    public let publisherMigration: Bool

    public init(allowLocalDowngrade: Bool = false, nonOfficialExecution: Bool = false, publisherMigration: Bool = false) {
        self.allowLocalDowngrade = allowLocalDowngrade
        self.nonOfficialExecution = nonOfficialExecution
        self.publisherMigration = publisherMigration
    }
}

/// The user approves an exact package, publisher, and capability delta. Anything else that arrives
/// at `activate` is a different install and is refused.
public struct ExtensionInstallApproval: Hashable, Sendable {
    public let packageSha256: String
    public let publisherFingerprint: String
    public let capabilityGrantFingerprint: String
    public let consent: ExtensionInstallConsent

    public init(
        packageSha256: String,
        publisherFingerprint: String,
        capabilityGrantFingerprint: String,
        consent: ExtensionInstallConsent
    ) {
        self.packageSha256 = packageSha256
        self.publisherFingerprint = publisherFingerprint
        self.capabilityGrantFingerprint = capabilityGrantFingerprint
        self.consent = consent
    }

    public static func approve(
        _ prepared: PreparedExtensionInstall,
        consent: ExtensionInstallConsent = ExtensionInstallConsent()
    ) -> ExtensionInstallApproval {
        ExtensionInstallApproval(
            packageSha256: prepared.candidate.packageSha256,
            publisherFingerprint: prepared.candidate.publisherFingerprint,
            capabilityGrantFingerprint: prepared.capabilityGrantFingerprint,
            consent: consent
        )
    }
}

public struct ExtensionInstaller: Sendable {
    private let verifier: HxpArchiveVerifier
    private let store: InstalledExtensionStore
    private let grants: PackageGrantStore

    public init(verifier: HxpArchiveVerifier, store: InstalledExtensionStore, grants: PackageGrantStore) {
        self.verifier = verifier
        self.store = store
        self.grants = grants
    }

    /// A publisher change is approved only by a root-signed migration that names the exact package
    /// and publisher this source was last activated under; nothing the candidate says about itself
    /// can approve it, and uninstalling does not reset the pin.
    public func prepare(
        archiveBytes: Data,
        migration: LegacyMigration? = nil
    ) async throws -> PreparedExtensionInstall {
        let candidate = try verifier.verify(archiveBytes: archiveBytes)
        let active = try await readVerifiedActive(candidate.manifest.sourceId)
        let pinned: PublisherPin?
        if let active {
            pinned = PublisherPin(publisherFingerprint: active.publisherFingerprint, packageSha256: active.packageSha256)
        } else {
            pinned = await store.publisherPin(candidate.manifest.sourceId)
        }
        let rotationApproved = migration.map { migration in
            pinned?.packageSha256 == migration.fromPackageSha256
                && pinned?.publisherFingerprint == migration.fromPublisherFingerprint
        } ?? false
        if active == nil, let pinned, pinned.publisherFingerprint != candidate.publisherFingerprint, !rotationApproved {
            throw ExtensionInstallError.keyRotationNotAuthorized
        }
        let outcome = ExtensionInstaller.evaluatePolicy(
            candidate: candidate.manifest,
            active: active?.manifest,
            publisherRevoked: false,
            rotationApproved: rotationApproved
        )
        switch outcome {
        case .rejectedReplay: throw ExtensionInstallError.replayRejected
        case .rejectedKeyRotation: throw ExtensionInstallError.keyRotationNotAuthorized
        default: break
        }
        let added = ExtensionInstaller.addedCapabilities(candidate.manifest, active?.manifest)
        let increases = ExtensionInstaller.resourceLimitIncreases(candidate.manifest, active?.manifest)
        return PreparedExtensionInstall(
            candidate: candidate,
            active: active,
            addedCapabilities: CanonicalOrder.sorted(added),
            resourceLimitIncreases: increases,
            capabilityGrantFingerprint: ExtensionInstaller.capabilityGrantFingerprint(
                candidate, added, increases
            ),
            remoteCapabilitySetFingerprint: ExtensionInstaller.remoteCapabilitySetFingerprint(
                candidate.manifest, candidate.publisherFingerprint
            ),
            isDowngrade: active.map { candidate.manifest.version < $0.manifest.version } ?? false,
            policyOutcome: outcome,
            requiresNonOfficialConsent: candidate.publisherTrust == .userAdded,
            requiresMigrationConsent: rotationApproved && pinned?.publisherFingerprint != candidate.publisherFingerprint
        )
    }

    /// Activation records the exact grant a non-official package needs before the archive lands, so
    /// there is never an installed archive that the next read would refuse to run.
    public func activate(_ prepared: PreparedExtensionInstall, approval: ExtensionInstallApproval) async throws {
        guard approval.packageSha256 == prepared.candidate.packageSha256,
              approval.publisherFingerprint == prepared.candidate.publisherFingerprint,
              approval.capabilityGrantFingerprint == prepared.capabilityGrantFingerprint else {
            throw ExtensionInstallError.approvalMismatch
        }
        guard !prepared.isDowngrade || approval.consent.allowLocalDowngrade else {
            throw ExtensionInstallError.downgradeRequiresConfirmation
        }
        guard !prepared.requiresNonOfficialConsent || approval.consent.nonOfficialExecution else {
            throw ExtensionInstallError.packageGrantRequired
        }
        guard !prepared.requiresMigrationConsent || approval.consent.publisherMigration else {
            throw ExtensionInstallError.migrationConsentRequired
        }
        if prepared.requiresNonOfficialConsent {
            try await grants.record(PackageGrant.covering(prepared.candidate, at: Date()))
        }
        try await store.writeActive(prepared.candidate)
    }

    public func readVerifiedActive(_ sourceId: SourceId) async throws -> VerifiedHxpPackage? {
        guard let bytes = try await store.readActive(sourceId) else { return nil }
        let verified: VerifiedHxpPackage
        do {
            verified = try verifier.verify(archiveBytes: bytes)
        } catch {
            throw ExtensionInstallError.installedPackageInvalid
        }
        try grants.requireExecutable(verified)
        return verified
    }

    public func remoteCapabilitySetFingerprint(_ packageInfo: VerifiedHxpPackage) -> String {
        ExtensionInstaller.remoteCapabilitySetFingerprint(packageInfo.manifest, packageInfo.publisherFingerprint)
    }

    /// Anything a new package can reach that the active one could not. The review screen shows this
    /// list verbatim, so it names origins and operations rather than summarising them.
    static func addedCapabilities(_ candidate: HxpManifest, _ active: HxpManifest?) -> Set<String> {
        var added = Set<String>()
        let previous = active?.capabilities
        for origin in candidate.capabilities.network.origins
        where previous?.network.origins.contains(origin) != true {
            added.insert("network:\(origin.canonical)")
        }
        if candidate.capabilities.cookies.sourceScoped, previous?.cookies.sourceScoped != true {
            added.insert("cookies:sourceScoped")
        }
        for origin in candidate.capabilities.cookies.origins
        where previous?.cookies.origins.contains(origin) != true {
            added.insert("cookies-origin:\(origin.canonical)")
        }
        if candidate.capabilities.webLogin.enabled, previous?.webLogin.enabled != true {
            added.insert("web-login")
        }
        for origin in candidate.capabilities.webLogin.origins
        where previous?.webLogin.origins.contains(origin) != true {
            added.insert("web-login-origin:\(origin.canonical)")
        }
        if candidate.capabilities.home.enabled, previous?.home.enabled != true {
            added.insert("source-home:read")
        }
        if let updateCheck = candidate.capabilities.updateCheck, previous?.updateCheck != updateCheck {
            added.insert("update-check:\(updateCheck.origin.canonical)\(updateCheck.path)")
        }
        if candidate.capabilities.remoteLibrary.read, previous?.remoteLibrary.read != true {
            added.insert("remote-library:read")
        }
        for operation in candidate.capabilities.remoteLibrary.writeOperations
        where previous?.remoteLibrary.writeOperations.contains(operation) != true {
            added.insert("remote-library:write:\(operation)")
        }
        return added
    }

    static func resourceLimitIncreases(
        _ candidate: HxpManifest,
        _ active: HxpManifest?
    ) -> [ResourceLimitIncrease] {
        let previousCapabilities = active?.capabilities
        let previousLimits = active?.resourceLimits
        let pairs: [(ResourceLimit, Int64, Int64)] = [
            (
                .maximumExecutionWallTimeMs,
                Int64(previousLimits?.maximumExecutionWallTimeMs ?? 0),
                Int64(candidate.resourceLimits.maximumExecutionWallTimeMs)
            ),
            (
                .maximumMemoryBytes,
                Int64(previousLimits?.maximumMemoryBytes ?? 0),
                Int64(candidate.resourceLimits.maximumMemoryBytes)
            ),
            (
                .storageQuotaBytes,
                Int64(previousCapabilities?.storageQuotaBytes ?? 0),
                Int64(candidate.capabilities.storageQuotaBytes)
            ),
            (
                .networkConcurrentRequests,
                Int64(previousCapabilities?.network.maximumConcurrentRequests ?? 0),
                Int64(candidate.capabilities.network.maximumConcurrentRequests)
            ),
            (
                .networkRequestTimeoutMs,
                Int64(previousCapabilities?.network.requestTimeoutMs ?? 0),
                Int64(candidate.capabilities.network.requestTimeoutMs)
            ),
            (
                .networkResponseBytes,
                Int64(previousCapabilities?.network.maximumResponseBytes ?? 0),
                Int64(candidate.capabilities.network.maximumResponseBytes)
            )
        ]
        return pairs
            .filter { $0.2 > $0.1 }
            .map { ResourceLimitIncrease(limit: $0.0, activeValue: $0.1, candidateValue: $0.2) }
    }

    static func capabilityGrantFingerprint(
        _ candidate: VerifiedHxpPackage,
        _ addedCapabilities: Set<String>,
        _ increases: [ResourceLimitIncrease]
    ) -> String {
        var text = candidate.packageSha256 + "\u{0}"
        for capability in CanonicalOrder.sorted(addedCapabilities) {
            text += "capability:\(capability)\n"
        }
        for increase in increases {
            text += "resource:\(increase.limit.rawValue):\(increase.activeValue):\(increase.candidateValue)\n"
        }
        return Sha256.hex(text)
    }
}
