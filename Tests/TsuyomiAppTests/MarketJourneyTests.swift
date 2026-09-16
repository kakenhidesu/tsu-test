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

/// The M5 journey against a fake HTTPS host: subscribe to a repository, confirm its root key and
/// publisher, install, see a higher version appear, update, then have the catalog revoke the package
/// and watch the installed source go dormant. No test reaches a real site.
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
        XCTAssertTrue(prepared.requiresNonOfficialConsent, "a user-added publisher's package needs explicit consent")
        await detail.approvePendingInstall()
        XCTAssertEqual(detail.failureCode, ExtensionInstallError.packageGrantRequired.rawValue)
        let awaited1 = try await world.registry.installedSources().isEmpty
        XCTAssertTrue(awaited1, "no consent, no archive on disk")

        await detail.prepare(cached.rows[0].package)
        detail.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
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
        detail.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
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
    /// revocation or an update, and two catalogs under one sequence cannot both be accepted.
    @MainActor
    func testAnOlderOrEquivocatingCatalogIsRefused() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 2), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await detail.refresh()
        XCTAssertEqual(detail.failureCode, RepositoryError.indexRollback.rawValue)

        let bumped = try HxpTestArchive.repackaged(original, version: "99.0.0")
        world.host.publish(index: try world.index([.init(bumped)], sequence: 2), package: bumped)
        await detail.refresh()
        XCTAssertEqual(detail.failureCode, RepositoryError.indexEquivocation.rawValue)
    }

    /// Removal keeps the installed extension, the publisher and the repository's identity: the same
    /// id can only ever come back under the same address and root.
    @MainActor
    func testRemovingARepositoryKeepsTheInstalledExtensionAndItsIdentity() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        await detail.refresh()
        guard case .content(let listing) = detail.state else { return XCTFail("no catalog") }
        await detail.prepare(listing.rows[0].package)
        detail.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
        await detail.approvePendingInstall()

        await world.model.removeRepository(detail.descriptor.repositoryId)
        let remaining = await world.repositories.all()
        XCTAssertTrue(remaining.isEmpty)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])

        let otherRoot = Data((97...128).map(UInt8.init))
        world.host.publish(
            index: try world.index([.init(original)], sequence: 1, rootSeed: otherRoot),
            package: original
        )
        await world.probe(rootSeed: otherRoot)
        XCTAssertNotNil(world.model.pendingApproval)
        await world.model.approvePendingRepository()
        XCTAssertEqual(world.model.failureCode, RepositoryError.repositoryIdentityMismatch.rawValue)

        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        world.model.discardApproval()
        await world.probe()
        await world.model.approvePendingRepository()
        XCTAssertNil(world.model.failureCode)
        let restored = await world.repositories.all()
        XCTAssertEqual(restored.map(\.repositoryId), ["org.example.repo"])
    }

    /// A publisher change is refused for a user-added root, and a catalog from such a root that
    /// carries a migration is refused whole; only the built-in official root may authorize one.
    @MainActor
    func testAUserAddedRootCannotAuthorizeAPublisherChange() async throws {
        let world = try await MarketWorld(directory: directory)
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await world.probe()
        await world.model.approvePendingRepository()
        let detail = try await world.detail()
        await detail.loadCached()
        guard case .content(let listing) = detail.state else { return XCTFail("no catalog") }
        await detail.prepare(listing.rows[0].package)
        detail.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
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
        XCTAssertEqual(detail.failureCode, RepositoryError.unauthorizedMigration.rawValue)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.version.original), [listing.rows[0].package.version.original])
    }

    /// The publisher a source was activated under is pinned past its uninstall, so a different
    /// publisher cannot take the source over through an empty slot; only an exact migration can.
    @MainActor
    func testThePublisherPinSurvivesUninstall() async throws {
        let world = try await MarketWorld(directory: directory)
        for publisher in [HxpTestArchive.fixture, HxpTestArchive.successor] {
            try await world.trust.approve(
                TrustedPublisher(
                    keyId: publisher.keyId,
                    publicKey: try publisher.publicKey(),
                    trust: .userAdded,
                    repositoryId: nil,
                    approvedAt: Date()
                )
            )
        }
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        let prepared = try await world.installer.prepare(archiveBytes: original)
        try await world.lifecycle.activate(prepared, consent: ExtensionInstallConsent(nonOfficialExecution: true))
        try await world.lifecycle.uninstall(prepared.candidate.manifest.sourceId)
        let installed = try await world.registry.installedSources()
        XCTAssertTrue(installed.isEmpty)

        let successor = try HxpTestArchive.repackaged(original, version: "99.0.0", publisher: HxpTestArchive.successor)
        do {
            _ = try await world.installer.prepare(archiveBytes: successor)
            XCTFail("a pinned source must not accept another publisher without a migration")
        } catch {
            XCTAssertEqual(error as? ExtensionInstallError, .keyRotationNotAuthorized)
        }
        let migrated = try await world.installer.prepare(
            archiveBytes: successor,
            migration: LegacyMigration(
                fromPublisherFingerprint: try HxpTestArchive.fixture.fingerprint(),
                fromPackageSha256: Sha256.hex(original)
            )
        )
        XCTAssertEqual(migrated.candidate.publisherFingerprint, try HxpTestArchive.successor.fingerprint())
        XCTAssertNotEqual(migrated.policyOutcome, .rejectedKeyRotation)
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
