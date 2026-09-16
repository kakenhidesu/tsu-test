// SPDX-License-Identifier: AGPL-3.0-only

import ExtensionsFeature
import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import XCTest

/// Trust decisions around a package: who may sign it, whether it may run, and what happens to a
/// source once its archive or its publisher is gone. Each is a separate act with a separate record.
final class ExtensionTrustJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A local archive from a publisher nobody trusts stops at asking for the key. A wrong key does
    /// not verify; the right one verifies but stores nothing until the install is approved with the
    /// execution consent, and only then does the key become durable trust and the package a grant.
    @MainActor
    func testALocalArchiveFromAnUnknownPublisherNeedsItsKeyAndThenConsent() async throws {
        let world = try await MarketWorld(directory: directory)
        let picked = directory.appendingPathComponent("picked.hxp")
        try JourneyFixtures.data("wenku8-fixture.hxp").write(to: picked)

        await world.model.importPackage(at: picked)
        XCTAssertNil(world.model.pendingInstall)
        let request = try XCTUnwrap(world.model.pendingPublisherKey)
        XCTAssertEqual(request.keyId, Phase2TestPublisher.keyId)
        XCTAssertTrue(world.trust.trusted.isEmpty)

        let wrong = try HxpTestArchive.successor.publicKey().base64EncodedString()
        await world.model.providePublisherKey(wrong)
        XCTAssertEqual(world.model.failureCode, HxpVerificationError.invalidSignature.rawValue)
        XCTAssertNotNil(world.model.pendingPublisherKey, "a wrong key leaves the request open")
        XCTAssertTrue(world.trust.trusted.isEmpty, "a typed key is never stored by itself")

        let right = try HxpTestArchive.fixture.publicKey().base64EncodedString()
        await world.model.providePublisherKey(right)
        XCTAssertNil(world.model.failureCode)
        XCTAssertNil(world.model.pendingPublisherKey)
        let pending = try XCTUnwrap(world.model.pendingInstall)
        XCTAssertEqual(pending.provisionalKey?.keyId, Phase2TestPublisher.keyId)
        XCTAssertTrue(pending.prepared.requiresNonOfficialConsent)
        XCTAssertTrue(world.trust.trusted.isEmpty, "verification alone stores nothing")

        await world.model.approvePendingInstall()
        XCTAssertEqual(world.model.failureCode, ExtensionInstallError.packageGrantRequired.rawValue)
        XCTAssertTrue(world.trust.trusted.isEmpty, "a refused install retains no key")
        let awaited1 = try await world.registry.installedSources().isEmpty
        XCTAssertTrue(awaited1)

        try JourneyFixtures.data("wenku8-fixture.hxp").write(to: picked)
        await world.model.importPackage(at: picked)
        await world.model.providePublisherKey(right)
        world.model.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
        await world.model.approvePendingInstall()
        XCTAssertNil(world.model.failureCode)
        XCTAssertEqual(world.trust.trusted.map(\.keyId), [Phase2TestPublisher.keyId])
        XCTAssertEqual(world.trust.trusted.map(\.trust), [.userAdded])
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])
        let verified = try await world.installer.readVerifiedActive(try SourceId("org.tsuyomi.wenku8"))
        XCTAssertEqual(verified?.publisherTrust, .userAdded, "the retained key is user-added trust, not built-in")
    }

    /// Uninstalling marks the source dormant under a new generation, removes the archive, and tells
    /// navigation to drop the source's screens. Forgetting a publisher later has nothing left to
    /// close, and a source already dormant does not have its generation advanced again.
    @MainActor
    func testUninstallMakesTheSourceDormantOnceAndReportsIt() async throws {
        let world = try await MarketWorld(directory: directory)
        try await world.trust.approve(
            TrustedPublisher(
                keyId: HxpTestArchive.fixture.keyId,
                publicKey: try HxpTestArchive.fixture.publicKey(),
                trust: .builtInTest,
                repositoryId: nil,
                approvedAt: Date()
            )
        )
        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        let prepared = try await world.installer.prepare(archiveBytes: original)
        try await world.lifecycle.activate(prepared)
        let sourceId = prepared.candidate.manifest.sourceId
        let awaited2 = try await world.remoteLibrary.sourceAvailability(sourceId.value)
        let live = try XCTUnwrap(awaited2)
        XCTAssertTrue(live.available)

        await world.model.uninstall(sourceId)
        XCTAssertNil(world.model.failureCode)
        XCTAssertEqual(world.removedSources.ids, [sourceId])
        let awaited3 = try await world.remoteLibrary.sourceAvailability(sourceId.value)
        let dormant = try XCTUnwrap(awaited3)
        XCTAssertFalse(dormant.available)
        XCTAssertNil(dormant.verifiedVersion)
        XCTAssertGreaterThan(dormant.generation, live.generation)
        let awaited4 = try await world.registry.installedSources().isEmpty
        XCTAssertTrue(awaited4)

        try await world.lifecycle.closeUnverifiable()
        let awaited5 = try await world.remoteLibrary.sourceAvailability(sourceId.value)
        let unchanged = try XCTUnwrap(awaited5)
        XCTAssertEqual(unchanged.generation, dormant.generation, "a dormant source must not churn its generation")
    }

    /// The official repository is the one the app ships pointed at: removing it disables it, and it
    /// can be enabled again without re-approving anything.
    @MainActor
    func testTheOfficialRepositoryIsDisabledRatherThanRemoved() async throws {
        let world = try await MarketWorld(directory: directory)
        let official = try OfficialRepository.descriptor(addedAt: Date())
        try await world.repositories.add(official)

        await world.model.removeRepository(official.repositoryId)
        let afterRemoval = await world.repositories.all()
        XCTAssertEqual(afterRemoval.map(\.repositoryId), [official.repositoryId])
        XCTAssertEqual(afterRemoval.map(\.enabled), [false])

        await world.model.setRepositoryEnabled(official.repositoryId, enabled: true)
        let restored = await world.repositories.all()
        XCTAssertEqual(restored.map(\.enabled), [true])
        XCTAssertEqual(restored.first?.rootPublicKey, official.rootPublicKey)
    }
}
