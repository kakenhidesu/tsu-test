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

/// The M5 journey against a fake HTTPS host: add a repository, confirm its root key and publisher,
/// install, see a higher version appear, update, then have the catalog revoke the package and watch
/// the installed source go dormant. No test reaches a real site.
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
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)

        await world.probe()
        let pending = try XCTUnwrap(world.model.pendingApproval)
        XCTAssertEqual(pending.index.repositoryId, "org.example.repo")
        XCTAssertEqual(pending.newPublisherKeyIds, [Phase2TestPublisher.keyId])
        XCTAssertFalse(pending.descriptor.rootKey.fingerprint.isEmpty)

        await world.model.approvePendingRepository()
        XCTAssertNil(world.model.pendingApproval)
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])

        let detail = try await world.detail()
        await detail.loadCached()
        guard case .content(let cached) = detail.state else {
            return XCTFail("an approved catalog must be readable from cache: \(detail.state)")
        }
        XCTAssertEqual(cached.rows.count, 1)
        XCTAssertEqual(cached.rows[0].status, .available)
        XCTAssertTrue(cached.untrustedPublishers.isEmpty)

        await detail.prepare(cached.rows[0].package)
        XCTAssertNil(detail.failureCode)
        let prepared = try XCTUnwrap(detail.pendingInstall)
        XCTAssertNil(prepared.active)
        await detail.approvePendingInstall()
        XCTAssertNil(detail.failureCode)
        XCTAssertNil(detail.pendingInstall, "an approved install must release the sheet it was presented from")
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])

        let bumped = try HxpTestArchive.repackaged(original, version: "99.0.0")
        world.host.publish(index: try world.index([.init(bumped)], sequence: 2), package: bumped)
        await detail.refresh()
        XCTAssertNil(detail.failureCode)
        guard case .content(let updated) = detail.state else {
            return XCTFail("refreshed catalog did not load: \(detail.state)")
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

        // A revocation names the archive digest the catalog listed, the same digest the download is
        // checked against.
        let digest = Sha256.hex(bumped)
        world.host.publish(
            index: try world.index([.init(bumped)], sequence: 3, revokedPackageDigests: [digest]),
            package: bumped
        )
        await detail.refresh()
        XCTAssertNil(detail.failureCode)
        XCTAssertTrue(world.trust.isRevokedPackage(digest))
        let availability = try await world.remoteLibrary.sourceAvailability("org.tsuyomi.wenku8")
        XCTAssertEqual(availability?.available, false)
        let stillListed = try await world.registry.installedSources()
        XCTAssertTrue(stillListed.isEmpty, "a revoked package must stop verifying")
    }

    /// The sequence is root-signed, so a mirror serving yesterday's catalog cannot roll back a
    /// revocation or an update.
    @MainActor
    func testAnOlderCatalogIsRefused() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 2), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await detail.refresh()
        XCTAssertEqual(detail.failureCode, RepositoryError.indexRollback.rawValue)
    }

    @MainActor
    func testRemovingARepositoryKeepsTheInstalledExtension() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        await detail.refresh()
        guard case .content(let listing) = detail.state else { return XCTFail("no catalog") }
        await detail.prepare(listing.rows[0].package)
        await detail.approvePendingInstall()

        await world.model.removeRepository(detail.descriptor.repositoryId)
        let remaining = await world.repositories.all()
        XCTAssertTrue(remaining.isEmpty)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])
    }

    /// A publisher change is refused until the catalog carries a root-signed migration naming the
    /// exact installed package and publisher, and a newly listed publisher is trusted one key at a
    /// time on the repository's own screen.
    @MainActor
    func testARootSignedMigrationApprovesAPublisherChange() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        await detail.loadCached()
        guard case .content(let listing) = detail.state else { return XCTFail("no catalog") }
        await detail.prepare(listing.rows[0].package)
        await detail.approvePendingInstall()

        let successor = HxpTestArchive.successor
        let bumped = try HxpTestArchive.repackaged(original, version: "99.0.0", publisher: successor)
        world.host.publish(
            index: try world.index([.init(bumped, publisher: successor)], sequence: 2),
            package: bumped
        )
        await detail.refresh()
        guard case .content(let unsigned) = detail.state else { return XCTFail("no catalog") }
        XCTAssertEqual(unsigned.untrustedPublishers.map(\.keyId), [successor.keyId])
        await detail.prepare(unsigned.rows[0].package)
        XCTAssertEqual(detail.failureCode, HxpVerificationError.unknownPublisher.rawValue)

        await detail.trustPublisher(try XCTUnwrap(unsigned.untrustedPublishers.first))
        guard case .content(let trusted) = detail.state else { return XCTFail("no catalog") }
        XCTAssertTrue(trusted.untrustedPublishers.isEmpty)
        await detail.prepare(trusted.rows[0].package)
        XCTAssertEqual(detail.failureCode, ExtensionInstallError.keyRotationNotAuthorized.rawValue)

        let migration = LegacyMigration(
            fromPublisherFingerprint: try HxpTestArchive.fixture.fingerprint(),
            fromPackageSha256: Sha256.hex(original)
        )
        world.host.publish(
            index: try world.index([.init(bumped, publisher: successor, legacyMigration: migration)], sequence: 3),
            package: bumped
        )
        await detail.refresh()
        guard case .content(let migrated) = detail.state else { return XCTFail("no catalog") }
        await detail.prepare(migrated.rows[0].package)
        XCTAssertNil(detail.failureCode)
        XCTAssertNotEqual(try XCTUnwrap(detail.pendingInstall).policyOutcome, .rejectedKeyRotation)
        await detail.approvePendingInstall()
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.version.original), ["99.0.0"])
        XCTAssertEqual(installed.map(\.publisherFingerprint), [try successor.fingerprint()])
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
private struct MarketWorld {
    static let indexUrl = "https://repo.example.org/tsuyomi/index-v1.json"

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

    func probe() async {
        await model.probeRepository(
            indexUrl: MarketWorld.indexUrl,
            rootPublicKey: (try? MarketIndexBuilder.rootPublicKeyBase64()) ?? ""
        )
    }

    func detail() async throws -> RepositoryDetailModel {
        let descriptor = try XCTUnwrap(await repositories.all().first)
        return RepositoryDetailModel(
            descriptor: descriptor,
            registry: registry,
            repositories: repositories,
            trust: trust,
            client: container.client,
            lifecycle: container.lifecycle,
            hostApi: container.hostApi
        )
    }

    func index(
        _ listings: [MarketIndexBuilder.Listing],
        sequence: Int,
        revokedPackageDigests: [String] = []
    ) throws -> Data {
        try MarketIndexBuilder.build(listings, sequence: sequence, revokedPackageDigests: revokedPackageDigests)
    }
}
