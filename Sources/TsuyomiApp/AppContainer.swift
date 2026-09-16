// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiSource
import TsuyomiUpdates

/// The single object graph, built once at launch by constructor injection. There is no container
/// framework and no service locator: everything a screen needs is handed to it.
@MainActor
public final class AppContainer: ObservableObject {
    public let roots: StorageRoots
    public let database: TsuyomiDatabase
    public let library: LibraryRepository
    public let progress: ReadingProgressStore
    public let remoteLibrary: RemoteLibraryStore
    public let mirror: RemoteMirrorStore
    public let directActions = DirectActionTokenRegistry()
    public let remoteCoordinator: RemoteLibraryCoordinator
    public let updates: UpdateStore
    public let updateCoordinator: UpdateCoordinator
    public let credentials: SourceCredentialStore
    public let sessions: VerifiedBrowserSessionStore
    public let collections: CollectionStore
    public let transfers: TransferRepository
    public let gateway: HostNetworkGateway
    public let registry: SourceRegistry
    public let installedExtensions: InstalledExtensionStore
    public let trust: PublisherTrustStore
    public let grants: PackageGrantStore
    public let mutationGate = ExtensionMutationGate()
    public let repositories: RepositoryStore
    public let hostApi: SemanticVersion
    public let preferences: AppPreferences
    public let snapshots: SourceFlowSnapshotStore
    private var trustLoad: Task<Void, Never>?

    public static let userAgent = "Tsuyomi/1.0 (iOS)"
    /// The host API this app implements. It is the version an extension's declared range is checked
    /// against, so a value lower than what the runtime actually provides rejects every package built
    /// for the real API. 1.2.0 added the host-initiated signed update check, which this host admits
    /// as a capability but never issues; nothing an extension can call changed.
    public static let hostApiVersion = "1.2.0"

    public init(base: URL, defaults: UserDefaults) throws {
        roots = try StorageRoots(base: base)
        database = try TsuyomiDatabase(
            path: roots.directory(.extensions).appendingPathComponent("tsuyomi.sqlite").path
        )
        library = LibraryRepository(database: database)
        progress = ReadingProgressStore(database: database)
        remoteLibrary = RemoteLibraryStore(database: database)
        mirror = RemoteMirrorStore(database: database)
        updates = UpdateStore(database: database)
        credentials = try SourceCredentialStore(roots: roots)
        sessions = VerifiedBrowserSessionStore(credentials: credentials)
        collections = CollectionStore(database: database)
        transfers = TransferRepository(database: database)
        gateway = HostNetworkGateway(
            transport: URLSessionHostHttpTransport(userAgent: AppContainer.userAgent),
            directActionTokens: directActions
        )
        let extensionFiles = try QuotaFileStore(
            roots: roots,
            root: .extensions,
            namespace: "installed-extensions",
            quota: StorageQuota(maximumBytes: 128 * 1024 * 1024, maximumEntries: 512)
        )
        installedExtensions = InstalledExtensionStore(files: extensionFiles)
        trust = PublisherTrustStore(files: extensionFiles)
        grants = PackageGrantStore(files: extensionFiles)
        repositories = RepositoryStore(files: extensionFiles)
        hostApi = try SemanticVersion(AppContainer.hostApiVersion)
        registry = SourceRegistry(
            installer: ExtensionInstaller(
                verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApi),
                store: installedExtensions,
                grants: grants
            ),
            store: installedExtensions,
            gateway: gateway,
            sessions: sessions
        )
        remoteCoordinator = RemoteLibraryCoordinator(
            registry: registry,
            remoteLibrary: remoteLibrary,
            mirror: mirror,
            library: library,
            sessions: sessions,
            tokens: directActions
        )
        updateCoordinator = UpdateCoordinator(
            registry: registry,
            updates: updates,
            library: library,
            mirror: mirror,
            remoteLibrary: remoteLibrary,
            progress: progress
        )
        preferences = AppPreferences(defaults: defaults)
        snapshots = SourceFlowSnapshotStore(defaults: defaults)
    }

    /// Trust is read from disk once, before anything is verified; every caller awaits that same read.
    /// The official repository and its publisher are written on the first launch only: removing
    /// either afterwards is the reader's decision and is not undone. The acceptance fixture publisher
    /// exists in DEBUG builds alone, so a package signed with the published fixture key can never
    /// load in production even if it reaches the device.
    public func loadTrust() async {
        let load = trustLoad ?? Task { await readTrust() }
        trustLoad = load
        await load.value
    }

    private func seedOfficialRepository() async -> Bool {
        do {
            try await repositories.add(try OfficialRepository.descriptor(addedAt: Date()))
            try await trust.approve(try OfficialRepository.publisher(approvedAt: Date()))
            return true
        } catch {
            return false
        }
    }

    /// Trust is followed by one reconciliation: every source whose archive is gone becomes dormant,
    /// once, so a cold start after a deletion never leaves a source that looks available.
    private func readTrust() async {
        await trust.load()
        await grants.load()
        if !preferences.officialRepositorySeeded, await seedOfficialRepository() {
            preferences.markOfficialRepositorySeeded()
        }
        let installed = Set(await installedExtensions.installedSourceIds().map(\.value))
        try? await remoteLibrary.markMissingSourcesUnavailable(installed: installed)
        #if DEBUG
        if let key = try? Phase2TestPublisher.key(), trust.resolve(keyId: key.keyId) == nil {
            try? await trust.approve(
                TrustedPublisher(
                    keyId: key.keyId,
                    publicKey: key.publicKey,
                    trust: .builtInTest,
                    repositoryId: nil,
                    approvedAt: Date(timeIntervalSince1970: 0)
                )
            )
        }
        #endif
    }
}
