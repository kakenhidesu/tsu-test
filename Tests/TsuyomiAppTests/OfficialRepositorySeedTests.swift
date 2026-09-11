// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiApp
import TsuyomiSource
import XCTest

/// The official repository and its publisher are written on the first launch, and only then: a
/// reader who removes either gets to keep that decision.
final class OfficialRepositorySeedTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "org.tsuyomi.ios.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testTheFirstLaunchSeedsTheOfficialRepositoryOnce() async throws {
        let first = try AppContainer(base: directory, defaults: defaults)
        await first.loadTrust()
        let seeded = await first.repositories.all()
        XCTAssertEqual(seeded.map(\.repositoryId), [OfficialRepository.repositoryId])
        XCTAssertEqual(seeded.first?.rootKeyId, OfficialRepository.rootKeyId)
        let publisher = try XCTUnwrap(first.trust.resolve(keyId: OfficialRepository.publisherKeyId))
        XCTAssertEqual(publisher.trust, .builtInOfficial)
        XCTAssertEqual(publisher.publicKey, try OfficialRepository.publisher(approvedAt: Date()).publicKey)

        try await first.repositories.remove(OfficialRepository.repositoryId)
        try await first.trust.forget(keyId: OfficialRepository.publisherKeyId)

        let second = try AppContainer(base: directory, defaults: defaults)
        await second.loadTrust()
        let afterRemoval = await second.repositories.all()
        XCTAssertTrue(afterRemoval.isEmpty, "a removed built-in repository must stay removed")
        XCTAssertNil(second.trust.resolve(keyId: OfficialRepository.publisherKeyId))
    }
}
