// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// The one place an extension is installed, updated or removed, whatever screen asked. Installing
/// always ends at `ExtensionInstaller.activate` with an approval the user gave, so a repository can
/// never reach a weaker path than a local `.hxp` import.
public struct ExtensionLifecycle: Sendable {
    private let installer: ExtensionInstaller
    private let installed: InstalledExtensionStore
    private let registry: SourceRegistry
    private let remoteLibrary: RemoteLibraryStore
    private let trust: PublisherTrustStore
    private let hostApiVersion: SemanticVersion

    public init(
        installed: InstalledExtensionStore,
        registry: SourceRegistry,
        remoteLibrary: RemoteLibraryStore,
        trust: PublisherTrustStore,
        hostApiVersion: SemanticVersion
    ) {
        self.installer = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApiVersion),
            store: installed
        )
        self.installed = installed
        self.registry = registry
        self.remoteLibrary = remoteLibrary
        self.trust = trust
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

    public func activate(_ prepared: PreparedExtensionInstall, allowLocalDowngrade: Bool = false) async throws {
        try await installer.activate(
            prepared,
            approval: ExtensionInstallApproval.approve(prepared, allowLocalDowngrade: allowLocalDowngrade)
        )
        await registry.close(prepared.candidate.manifest.sourceId)
        try await remoteLibrary.setSourceAvailability(
            sourceId: prepared.candidate.manifest.sourceId.value,
            version: prepared.candidate.manifest.version.original,
            available: true,
            generation: await nextGeneration(prepared.candidate.manifest.sourceId.value)
        )
    }

    /// Removes the package, its runtime lane and its availability row. Credentials and shelf entries
    /// stay: the books remain readable as a dormant source, and clearing a login is its own action.
    public func uninstall(_ sourceId: SourceId) async throws {
        await registry.close(sourceId)
        _ = try await installed.remove(sourceId)
        try await remoteLibrary.setSourceAvailability(
            sourceId: sourceId.value,
            version: nil,
            available: false,
            generation: await nextGeneration(sourceId.value)
        )
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
    /// unavailable, whether trust changed because of a revocation or because the reader withdrew it.
    public func closeUnverifiable() async throws {
        for sourceId in await installed.installedSourceIds() {
            let stillVerifies = (try? await installer.readVerifiedActive(sourceId)) ?? nil
            guard stillVerifies == nil else { continue }
            await registry.close(sourceId)
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
