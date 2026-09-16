// SPDX-License-Identifier: AGPL-3.0-only

import ExtensionsFeature
import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import XCTest

/// The 可安装 list merges every enabled repository's cache, and installs through the same review
/// as everything else.
final class CatalogJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testTheCatalogListsSubscribedPackagesAndInstallsThroughTheReview() async throws {
        let world = try await MarketWorld(directory: directory)
        await world.catalog.loadCached()
        XCTAssertFalse(world.catalog.hasRepositories)
        XCTAssertTrue(world.catalog.items.isEmpty)

        let original = try JourneyFixtures.data("wenku8-fixture.hxp")
        world.host.publish(index: try world.index([.init(original)], sequence: 1), package: original)
        await world.probe()
        await world.model.approvePendingRepository()

        await world.catalog.loadCached()
        XCTAssertTrue(world.catalog.hasRepositories)
        XCTAssertEqual(world.catalog.status, .ready)
        XCTAssertEqual(world.catalog.items.map(\.package.id.value), ["org.tsuyomi.wenku8"])
        XCTAssertEqual(world.catalog.items.first?.status, .available)
        XCTAssertTrue(world.catalog.items.first?.isInstallable == true)
        XCTAssertTrue(world.catalog.installationAllowed)

        world.catalog.query = "nothing-like-this"
        XCTAssertTrue(world.catalog.filtered.isEmpty)
        world.catalog.query = "wenku"
        XCTAssertEqual(world.catalog.filtered.count, 1)
        world.catalog.query = ""

        let item = try XCTUnwrap(world.catalog.items.first)
        await world.catalog.prepare(item)
        XCTAssertNil(world.catalog.installFailure)
        XCTAssertNotNil(world.catalog.pendingInstall)
        world.catalog.installConsent = ExtensionInstallConsent(nonOfficialExecution: true)
        await world.catalog.approvePendingInstall()
        XCTAssertNil(world.catalog.pendingInstall)
        XCTAssertEqual(world.catalog.items.first?.status, .installed)
        let installed = try await world.registry.installedSources()
        XCTAssertEqual(installed.map(\.sourceId.value), ["org.tsuyomi.wenku8"])

        try await world.repositories.setEnabled("org.example.repo", enabled: false)
        await world.catalog.loadCached()
        XCTAssertTrue(world.catalog.items.isEmpty, "a disabled repository offers nothing")
    }
}
