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
    public let gateway: HostNetworkGateway
    public let registry: SourceRegistry
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
        gateway = HostNetworkGateway(
            transport: URLSessionHostHttpTransport(userAgent: AppContainer.userAgent)
        )
        let installed = InstalledExtensionStore(
            files: try QuotaFileStore(
                roots: roots,
                root: .extensions,
                namespace: "installed-extensions",
                quota: StorageQuota(maximumBytes: 128 * 1024 * 1024, maximumEntries: 512)
            )
        )
        registry = SourceRegistry(
            installer: ExtensionInstaller(
                verifier: HxpArchiveVerifier(
                    publisherKeys: AppContainer.publisherKeys(),
                    hostApiVersion: try SemanticVersion(AppContainer.hostApiVersion)
                ),
                store: installed
            ),
            store: installed,
            gateway: gateway
        )
        preferences = AppPreferences(defaults: defaults)
        snapshots = SourceFlowSnapshotStore(defaults: defaults)
    }

    /// A release build trusts only publishers the user has added. The acceptance fixture key exists
    /// in DEBUG builds alone, so a published package signed with it can never load in production.
    private static func publisherKeys() -> InMemoryPublisherKeyStore {
        #if DEBUG
        if let key = try? Phase2TestPublisher.key() {
            return InMemoryPublisherKeyStore(keys: [key])
        }
        #endif
        return InMemoryPublisherKeyStore()
    }
}
