// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// The single object graph, built once at launch by constructor injection. There is no container
/// framework and no service locator: everything a screen needs is handed to it.
@MainActor
public final class AppContainer: ObservableObject {
    public let roots: StorageRoots
    public let database: TsuyomiDatabase
    public let library: LibraryRepository
    public let progress: ReadingProgressStore
    public let remoteLibrary: RemoteLibraryStore
    public let credentials: SourceCredentialStore
    public let collections: CollectionStore
    public let transfers: TransferRepository
    public let gateway: HostNetworkGateway
    public let registry: SourceRegistry
    public let installedExtensions: InstalledExtensionStore
    public let trust: PublisherTrustStore
    public let repositories: RepositoryStore
    public let hostApi: SemanticVersion
    public let preferences: AppPreferences
    public let snapshots: SourceFlowSnapshotStore

    public static let userAgent = "Tsuyomi/1.0 (iOS)"
    public static let hostApiVersion = "1.0.0"

    public init(base: URL, defaults: UserDefaults) throws {
        roots = try StorageRoots(base: base)
        database = try TsuyomiDatabase(
            path: roots.directory(.extensions).appendingPathComponent("tsuyomi.sqlite").path
        )
        library = LibraryRepository(database: database)
        progress = ReadingProgressStore(database: database)
        remoteLibrary = RemoteLibraryStore(database: database)
        credentials = try SourceCredentialStore(roots: roots)
        collections = CollectionStore(database: database)
        transfers = TransferRepository(database: database)
        gateway = HostNetworkGateway(
            transport: URLSessionHostHttpTransport(userAgent: AppContainer.userAgent)
        )
        let extensionFiles = try QuotaFileStore(
            roots: roots,
            root: .extensions,
            namespace: "installed-extensions",
            quota: StorageQuota(maximumBytes: 128 * 1024 * 1024, maximumEntries: 512)
        )
        installedExtensions = InstalledExtensionStore(files: extensionFiles)
        trust = PublisherTrustStore(files: extensionFiles)
        repositories = RepositoryStore(files: extensionFiles)
        hostApi = try SemanticVersion(AppContainer.hostApiVersion)
        registry = SourceRegistry(
            installer: ExtensionInstaller(
                verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApi),
                store: installedExtensions
            ),
            store: installedExtensions,
            gateway: gateway
        )
        preferences = AppPreferences(defaults: defaults)
        snapshots = SourceFlowSnapshotStore(defaults: defaults)
    }

    /// Trust is read from disk before anything is verified. The acceptance fixture publisher exists
    /// in DEBUG builds alone, so a package signed with the published fixture key can never load in
    /// production even if it reaches the device.
    public func loadTrust() async {
        await trust.load()
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
