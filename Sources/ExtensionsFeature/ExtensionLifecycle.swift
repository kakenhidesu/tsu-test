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

    /// Verifies an archive and reports what approving it would grant. The index's own capability
    /// preview is compared against the manifest here: a mismatch is refused rather than reconciled.
    public func prepare(
        archiveBytes: Data,
        declaring preview: HxpCapabilities?,
        rotationApproved: Bool = false
    ) async throws -> PreparedExtensionInstall {
        let prepared = try await installer.prepare(
            archiveBytes: archiveBytes,
            rotationApproved: rotationApproved
        )
        if let preview, preview != prepared.candidate.manifest.capabilities {
            throw RepositoryError.indexManifestMismatch
        }
        let manifest = prepared.candidate.manifest
        guard hostApiVersion >= manifest.hostApiMinInclusive,
              hostApiVersion < manifest.hostApiMaxExclusive else {
            throw RepositoryError.hostApiIncompatible
        }
        if let active = prepared.active, prepared.candidate.manifest.version <= active.manifest.version {
            throw RepositoryError.downgradeRejected
        }
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

    /// Applies an index's revocations. A revocation only ever deactivates: it never deletes a shelf
    /// entry, and a package it names can no longer be reinstalled.
    public func applyRevocations(
        _ revocations: [RepositoryRevocation],
        now: Date
    ) async throws {
        for revocation in revocations where revocation.expiresAt > now {
            switch revocation.target {
            case .keyId(let keyId):
                try await trust.revoke(keyId: keyId)
            case .packageDigest(let digest):
                try await trust.revoke(packageDigest: digest)
            }
        }
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
