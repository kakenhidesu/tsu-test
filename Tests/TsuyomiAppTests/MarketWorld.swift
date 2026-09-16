// SPDX-License-Identifier: AGPL-3.0-only

import ExtensionsFeature
import Foundation
import os
import TsuyomiApp
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import XCTest

/// Serves exactly the two paths a repository exposes. Anything else is a 404, so a stray request
/// fails the test rather than silently succeeding.
final class FakeRepositoryHost: HostHttpTransport {
    private struct Payload: Sendable {
        var index = Data()
        var package = Data()
    }

    private let state = OSAllocatedUnfairLock(initialState: Payload())

    func publish(index: Data, package: Data) {
        state.withLock { current in
            current.index = index
            current.package = package
        }
    }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        let path = request.url.path
        let body: Data? = state.withLock { current in
            if path.hasSuffix("/index-v1.json") { return current.index }
            if path.hasSuffix(".hxp") { return current.package }
            return nil
        }
        guard let body else {
            return HostHttpResponse(status: 404, finalUrl: request.url, headers: [:], bytes: Data())
        }
        return HostHttpResponse(
            status: 200,
            finalUrl: request.url,
            headers: ["content-type": "application/octet-stream"],
            bytes: body
        )
    }
}

@MainActor
final class RemovedSourceRecorder {
    var ids: [SourceId] = []
}

@MainActor
struct MarketWorld {
    static let indexUrl = "https://repo.example.org/tsuyomi/index-v1.json"

    let host = FakeRepositoryHost()
    let removedSources = RemovedSourceRecorder()
    let model: ExtensionsModel
    let registry: SourceRegistry
    let repositories: RepositoryStore
    let trust: PublisherTrustStore
    let grants: PackageGrantStore
    let remoteLibrary: RemoteLibraryStore
    let installer: ExtensionInstaller
    let lifecycle: ExtensionLifecycle
    private let client: ExtensionRepositoryClient
    private let hostApi: SemanticVersion

    init(directory: URL) async throws {
        let roots = try StorageRoots(base: directory)
        let database = try TsuyomiDatabase(path: directory.appendingPathComponent("t.sqlite").path)
        remoteLibrary = RemoteLibraryStore(database: database)
        let files = try QuotaFileStore(
            roots: roots,
            root: .extensions,
            namespace: "installed-extensions",
            quota: StorageQuota(maximumBytes: 64 * 1024 * 1024, maximumEntries: 64)
        )
        let installed = InstalledExtensionStore(files: files)
        trust = PublisherTrustStore(files: files)
        grants = PackageGrantStore(files: files)
        repositories = RepositoryStore(files: files)
        hostApi = try SemanticVersion(AppContainer.hostApiVersion)
        let gateway = HostNetworkGateway(transport: host)
        installer = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApi),
            store: installed,
            grants: grants
        )
        registry = SourceRegistry(
            installer: installer,
            store: installed,
            gateway: gateway,
            sessions: VerifiedBrowserSessionStore(credentials: try SourceCredentialStore(roots: roots))
        )
        client = ExtensionRepositoryClient(gateway: gateway)
        lifecycle = ExtensionLifecycle(
            installed: installed,
            registry: registry,
            remoteLibrary: remoteLibrary,
            trust: trust,
            grants: grants,
            gate: ExtensionMutationGate(),
            hostApiVersion: hostApi
        )
        model = ExtensionsModel(
            registry: registry,
            repositories: repositories,
            trust: trust,
            client: client,
            lifecycle: lifecycle,
            sourceRemoved: { [removedSources] in removedSources.ids.append($0) }
        )
    }

    func probe(rootSeed: Data = MarketIndexBuilder.rootSeed) async {
        let key = (try? MarketIndexBuilder.rootPublicKeyBase64(seed: rootSeed)) ?? ""
        await model.probeRepository(
            link: "\(MarketWorld.indexUrl)#repositoryId=org.example.repo&keyId=\(MarketIndexBuilder.rootKeyId)&publicKey=\(key)"
        )
    }

    func detail() async throws -> RepositoryDetailModel {
        let added = await repositories.all()
        let descriptor = try XCTUnwrap(added.first)
        return RepositoryDetailModel(
            descriptor: descriptor,
            registry: registry,
            repositories: repositories,
            trust: trust,
            client: client,
            lifecycle: lifecycle,
            hostApi: hostApi
        )
    }

    func index(
        _ listings: [MarketIndexBuilder.Listing],
        sequence: Int,
        revokedPackageDigests: [String] = [],
        rootSeed: Data = MarketIndexBuilder.rootSeed
    ) throws -> Data {
        try MarketIndexBuilder.build(
            listings,
            sequence: sequence,
            revokedPackageDigests: revokedPackageDigests,
            rootSeed: rootSeed
        )
    }
}
