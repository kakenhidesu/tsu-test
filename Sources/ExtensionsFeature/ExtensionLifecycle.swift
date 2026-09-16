// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// The one place an extension is installed, updated or removed, whatever screen asked. Installing
/// always ends at `ExtensionInstaller.activate` with an approval the user gave, so a repository can
/// never reach a weaker path than a local `.hxp` import, and every mutation passes one gate so two
/// screens cannot race an archive on disk.
public struct ExtensionLifecycle: Sendable {
    private let installer: ExtensionInstaller
    private let installed: InstalledExtensionStore
    private let registry: SourceRegistry
    private let remoteLibrary: RemoteLibraryStore
    private let trust: PublisherTrustStore
    private let grants: PackageGrantStore
    private let gate: ExtensionMutationGate
    private let hostApiVersion: SemanticVersion

    public init(
        installed: InstalledExtensionStore,
        registry: SourceRegistry,
        remoteLibrary: RemoteLibraryStore,
        trust: PublisherTrustStore,
        grants: PackageGrantStore,
        gate: ExtensionMutationGate,
        hostApiVersion: SemanticVersion
    ) {
        self.installer = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApiVersion),
            store: installed,
            grants: grants
        )
        self.installed = installed
        self.registry = registry
        self.remoteLibrary = remoteLibrary
        self.trust = trust
        self.grants = grants
        self.gate = gate
        self.hostApiVersion = hostApiVersion
    }

    /// Verifies an archive and reports what approving it would grant. A catalog listing is compared
    /// against the manifest here: a mismatch is refused rather than reconciled, and only the
    /// listing's root-signed migration can approve a publisher change.
    public func prepare(
        archiveBytes: Data,
        declaring listed: RepositoryPackage?
    ) async throws -> PreparedExtensionInstall {
        let prepared = try await installer.prepare(
            archiveBytes: archiveBytes,
            migration: listed?.legacyMigration
        )
        guard let listed else { return prepared }
        try RepositoryInstallPolicy.requireInstallable(
            listed: listed,
            manifest: prepared.candidate.manifest,
            archiveBytes: archiveBytes,
            hostApi: hostApiVersion,
            activeVersion: prepared.active?.manifest.version
        )
        return prepared
    }

    /// Verifies a local archive under a key the reader typed, without storing that key: a throwaway
    /// installer resolves it alongside the durable trust, with the durable side taking precedence,
    /// so a typed key can neither shadow a pinned identity nor outlive this one review.
    public func prepare(archiveBytes: Data, provisionalKey key: PublisherKey) async throws -> PreparedExtensionInstall {
        let resolver = CompositePublisherKeyResolver([trust, InMemoryPublisherKeyStore(keys: [key])])
        let provisional = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: resolver, hostApiVersion: hostApiVersion),
            store: installed,
            grants: grants
        )
        let prepared = try await provisional.prepare(archiveBytes: archiveBytes)
        guard prepared.candidate.publisherTrust == .userAdded,
              prepared.candidate.publisherFingerprint == key.fingerprint else {
            throw HxpVerificationError.unknownPublisher
        }
        return prepared
    }

    /// Activation is where a typed key finally becomes durable trust, after the archive it verifies
    /// has been approved with the consent that trust requires.
    public func activate(
        _ prepared: PreparedExtensionInstall,
        consent: ExtensionInstallConsent = ExtensionInstallConsent(),
        retaining key: PublisherKey? = nil
    ) async throws {
        try await gate.withMutation {
            if let key {
                try await trust.approve(
                    TrustedPublisher(
                        keyId: key.keyId,
                        publicKey: key.publicKey,
                        trust: .userAdded,
                        repositoryId: nil,
                        approvedAt: Date()
                    )
                )
            }
            try await installer.activate(prepared, approval: ExtensionInstallApproval.approve(prepared, consent: consent))
            await registry.close(prepared.candidate.manifest.sourceId)
            try await remoteLibrary.setSourceAvailability(
                sourceId: prepared.candidate.manifest.sourceId.value,
                version: prepared.candidate.manifest.version.original,
                available: true,
                generation: await nextGeneration(prepared.candidate.manifest.sourceId.value)
            )
        }
    }

    /// Removes the package, its runtime lane and its availability, in that order of consequence: the
    /// source goes dormant before the archive leaves, and if the archive cannot be removed the
    /// availability comes back under a newer generation so any run that started meanwhile still
    /// loses. Credentials, shelf entries and the publisher pin stay.
    public func uninstall(_ sourceId: SourceId) async throws {
        try await gate.withMutation {
            await registry.close(sourceId)
            let previous = try await remoteLibrary.sourceAvailability(sourceId.value)
            let generation = await nextGeneration(sourceId.value)
            try await remoteLibrary.setSourceAvailability(
                sourceId: sourceId.value, version: nil, available: false, generation: generation
            )
            do {
                _ = try await installed.remove(sourceId)
            } catch {
                try await remoteLibrary.setSourceAvailability(
                    sourceId: sourceId.value,
                    version: previous?.verifiedVersion,
                    available: previous?.available ?? false,
                    generation: generation + 1
                )
                throw error
            }
        }
    }

    /// Applies a catalog's revocations. A revocation only ever deactivates: it never deletes a shelf
    /// entry, and a package or key it names can no longer be reinstalled or approved.
    public func applyRevocations(_ revocations: RepositoryRevocations) async throws {
        for fingerprint in CanonicalOrder.sorted(revocations.publisherFingerprints) {
            try await trust.revoke(fingerprint: fingerprint)
        }
        for digest in CanonicalOrder.sorted(revocations.packageDigests) {
            try await trust.revoke(packageDigest: digest)
        }
        try await closeUnverifiable()
    }

    /// Whatever no longer verifies against the current trust is closed and its source marked
    /// unavailable — once: a source already dormant is left alone so its generation does not churn.
    public func closeUnverifiable() async throws {
        for sourceId in await installed.installedSourceIds() {
            let stillVerifies = (try? await installer.readVerifiedActive(sourceId)) ?? nil
            guard stillVerifies == nil else { continue }
            await registry.close(sourceId)
            guard try await remoteLibrary.sourceAvailability(sourceId.value)?.available == true else { continue }
            try await remoteLibrary.setSourceAvailability(
                sourceId: sourceId.value,
                version: nil,
                available: false,
                generation: await nextGeneration(sourceId.value)
            )
        }
    }

    /// Every availability change advances the generation, which is what an in-flight remote run's
    /// lease is checked against; reusing a number would let a stale run finish under new state.
    private func nextGeneration(_ sourceId: String) async -> Int64 {
        let current = (try? await remoteLibrary.sourceAvailability(sourceId))??.generation ?? 0
        return current + 1
    }
}
