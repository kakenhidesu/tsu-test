// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import ExtensionsFeature
import Foundation
import os
import TsuyomiApp
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import XCTest

/// The M5 journey against a fake HTTPS host: add a repository, confirm the publisher, install, see a
/// higher version appear, update, then have the index revoke the package and watch the installed
/// source go dormant. No test reaches a real site.
final class MarketJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("market-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testAddInstallUpdateThenRevoke() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index(packages: [original]), packages: ["v1": original])

        await world.model.probeRepository(base: "https://repo.example.org/tsuyomi")
        let pending = try XCTUnwrap(world.model.pendingApproval)
        XCTAssertEqual(pending.index.repositoryId, "org.example.repo")
        XCTAssertTrue(pending.isNewPublisherKey)
        XCTAssertFalse(pending.index.publisher.fingerprint.isEmpty)

        await world.model.approvePendingRepository()
        XCTAssertNil(world.model.pendingApproval)
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])

        let added = await world.repositories.all()
        let descriptor = try XCTUnwrap(added.first)
        let detail = world.detail(descriptor)
        await detail.refresh()
        guard case .content(let listing) = detail.state else {
            return XCTFail("index did not load: \(detail.state)")
        }
        XCTAssertEqual(listing.rows.count, 1)
        XCTAssertEqual(listing.rows[0].status, .available)

        await detail.prepare(listing.rows[0].package)
        XCTAssertNil(detail.failureCode)
        let prepared = try XCTUnwrap(detail.pendingInstall)
        XCTAssertNil(prepared.active)
        await detail.approvePendingInstall()
        XCTAssertNil(detail.failureCode)
        XCTAssertNil(detail.pendingInstall, "an approved install must release the sheet it was presented from")
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])

        let bumped = try HxpTestArchive.repackaged(original, version: "99.0.0")
        world.host.publish(index: try world.index(packages: [bumped]), packages: ["v1": bumped])
        await detail.refresh()
        guard case .content(let updated) = detail.state else {
            return XCTFail("refreshed index did not load: \(detail.state)")
        }
        guard case .updatable = updated.rows[0].status else {
            return XCTFail("a higher version must read as updatable, got \(updated.rows[0].status)")
        }
        await detail.prepare(updated.rows[0].package)
        XCTAssertNil(detail.failureCode)
        XCTAssertNotNil(try XCTUnwrap(detail.pendingInstall).active)
        await detail.approvePendingInstall()
        let afterUpdate = try await world.registry.installedSources()
        XCTAssertEqual(afterUpdate.map(\.version.original), ["99.0.0"])

        // A revocation names the manifest content digest, so re-zipping the same payload cannot dodge it.
        let digest = try MarketIndexBuilder.contentDigest(of: bumped)
        world.host.publish(
            index: try world.index(packages: [bumped], revokingPackageDigest: digest),
            packages: ["v1": bumped]
        )
        await detail.refresh()
        XCTAssertTrue(world.trust.isRevokedPackage(digest))
        let availability = try await world.remoteLibrary.sourceAvailability("org.tsuyomi.wenku8")
        XCTAssertEqual(availability?.available, false)
        let stillListed = try await world.registry.installedSources()
        XCTAssertTrue(stillListed.isEmpty, "a revoked package must stop verifying")
    }

    @MainActor
    func testRemovingARepositoryKeepsTheInstalledExtension() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index(packages: [original]), packages: ["v1": original])
        await world.model.probeRepository(base: "https://repo.example.org/tsuyomi")
        await world.model.approvePendingRepository()
        let added = await world.repositories.all()
        let descriptor = try XCTUnwrap(added.first)
        let detail = world.detail(descriptor)
        await detail.refresh()
        guard case .content(let listing) = detail.state else { return XCTFail("no index") }
        await detail.prepare(listing.rows[0].package)
        await detail.approvePendingInstall()

        await world.model.removeRepository(descriptor.repositoryId)
        let remaining = await world.repositories.all()
        XCTAssertTrue(remaining.isEmpty)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])
    }

    /// A picked archive is consumed once, and a verified import stays reported until the review is
    /// decided either way; deciding clears the report together with the pending install.
    @MainActor
    func testLocalImportStaysReportedUntilTheReviewIsDecided() async throws {
        let world = try await MarketWorld(directory: directory)
        let key = try Phase2TestPublisher.key()
        try await world.trust.approve(
            TrustedPublisher(
                keyId: key.keyId,
                publicKey: key.publicKey,
                trust: .builtInTest,
                repositoryId: nil,
                approvedAt: Date()
            )
        )
        let picked = directory.appendingPathComponent("picked.hxp")
        try JourneyFixtures.data("wenku8-fixture.hxp").write(to: picked)

        await world.model.importPackage(at: picked)
        XCTAssertNil(world.model.failureCode)
        XCTAssertNotNil(world.model.pendingInstall)
        XCTAssertNotNil(world.model.importStatus)
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path))

        world.model.discardPendingInstall()
        XCTAssertNil(world.model.pendingInstall)
        XCTAssertNil(world.model.importStatus)

        try JourneyFixtures.data("wenku8-fixture.hxp").write(to: picked)
        await world.model.importPackage(at: picked)
        await world.model.approvePendingInstall()
        XCTAssertNil(world.model.failureCode)
        XCTAssertNil(world.model.pendingInstall)
        XCTAssertNil(world.model.importStatus)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])
    }
}

/// Serves exactly the three paths a repository exposes. Anything else is a 404, so a stray request
/// fails the test rather than silently succeeding.
final class FakeRepositoryHost: HostHttpTransport {
    private struct Payload: Sendable {
        var index = Data()
        var signature = Data()
        var packages: [String: Data] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: Payload())

    func publish(index: (bytes: Data, signature: Data), packages: [String: Data]) {
        state.withLock { current in
            current.index = index.bytes
            current.signature = index.signature
            current.packages = packages
        }
    }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        let path = request.url.path
        let body: Data? = state.withLock { current in
            if path.hasSuffix("/index.json") { return current.index }
            if path.hasSuffix("/index.sig") { return current.signature }
            if path.hasSuffix(".hxp") { return current.packages["v1"] }
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
private struct MarketWorld {
    let host = FakeRepositoryHost()
    let model: ExtensionsModel
    let registry: SourceRegistry
    let repositories: RepositoryStore
    let trust: PublisherTrustStore
    let remoteLibrary: RemoteLibraryStore
    private let container: (client: ExtensionRepositoryClient, lifecycle: ExtensionLifecycle, hostApi: SemanticVersion)

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
        repositories = RepositoryStore(files: files)
        let hostApi = try SemanticVersion(AppContainer.hostApiVersion)
        let gateway = HostNetworkGateway(transport: host)
        registry = SourceRegistry(
            installer: ExtensionInstaller(
                verifier: HxpArchiveVerifier(publisherKeys: trust, hostApiVersion: hostApi),
                store: installed
            ),
            store: installed,
            gateway: gateway,
            sessions: VerifiedBrowserSessionStore(credentials: try SourceCredentialStore(roots: roots))
        )
        let client = ExtensionRepositoryClient(gateway: gateway)
        let lifecycle = ExtensionLifecycle(
            installed: installed,
            registry: registry,
            remoteLibrary: remoteLibrary,
            trust: trust,
            hostApiVersion: hostApi
        )
        container = (client, lifecycle, hostApi)
        model = ExtensionsModel(
            registry: registry,
            repositories: repositories,
            trust: trust,
            client: client,
            lifecycle: lifecycle
        )
    }

    func detail(_ descriptor: RepositoryDescriptor) -> RepositoryDetailModel {
        RepositoryDetailModel(
            descriptor: descriptor,
            registry: registry,
            repositories: repositories,
            trust: trust,
            client: container.client,
            lifecycle: container.lifecycle,
            hostApi: container.hostApi
        )
    }

    func index(packages: [Data], revokingPackageDigest digest: String? = nil) throws -> (bytes: Data, signature: Data) {
        try MarketIndexBuilder.build(packages: packages, revokingPackageDigest: digest)
    }
}
