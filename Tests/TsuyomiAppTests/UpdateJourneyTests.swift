// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUpdates
import XCTest

/// Update checks: a first check is a silent baseline, an appended chapter reaches the inbox, and
/// the inbox empties only through reading, ignoring or undoing. Every page is a wenku8 fixture.
final class UpdateJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("updates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func pin(_ world: MirrorWorld, _ remoteBookId: String, title: String) async throws -> BookIdentity {
        let identity = try world.identity(remoteBookId)
        _ = try await world.library.addToLibrary(
            LibraryBook(identity: identity, title: title, addedAt: Date(), metadataUpdatedAt: Date())
        )
        return identity
    }

    @MainActor
    func testAFirstCheckIsASilentBaselineAndAnAppendedChapterReachesTheInbox() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try await pin(world, "1234", title: "雾港纪事")

        let first = await world.updateCoordinator.run(trigger: .manual)
        guard case .completed = first else { return XCTFail("the first session did not complete: \(first)") }
        let awaited1 = try await world.updates.latestSession()
        let baselineSession = try XCTUnwrap(awaited1)
        XCTAssertEqual(baselineSession.state, .completed)
        XCTAssertEqual(baselineSession.total, 1)
        XCTAssertEqual(baselineSession.updated, 0)
        let awaited2 = try await world.updates.baseline(identity)
        let baseline = try XCTUnwrap(awaited2)
        XCTAssertTrue(baseline.anchor.hasPrefix("update-check-v2.2."))
        XCTAssertEqual(baseline.chapters.map(\.chapterId), ["10001", "10002"])
        let emptyInbox = try await world.updates.unresolvedUpdates()
        XCTAssertTrue(emptyInbox.isEmpty, "a baseline is silent")

        world.transport.setDirectoryPage("update-directory-appended")
        _ = await world.updateCoordinator.run(trigger: .manual)
        let awaited3 = try await world.updates.latestSession()
        let second = try XCTUnwrap(awaited3)
        XCTAssertEqual(second.updated, 1)
        let inbox = try await world.updates.unresolvedUpdates()
        XCTAssertEqual(inbox.map(\.identity), [identity])
        XCTAssertEqual(inbox.first?.newChapterIds, ["10003"])
        XCTAssertEqual(inbox.first?.lastUpdatedDate, "2026-09-07")
        let items = try await world.updates.sessionItems(second.sessionId, limit: 10)
        XCTAssertEqual(items.map(\.state), [.updated])

        let library = world.libraryModel()
        await library.load()
        XCTAssertEqual(library.update(for: identity)?.newChapterIds, ["10003"])
        library.setShowUpdatesOnly(true)
        guard case .content(let content) = library.state else { return XCTFail("shelf did not load") }
        XCTAssertEqual(library.project(content.entries).map(\.book.identity), [identity])
    }

    /// Reading the announced chapter through resolves the update; reading anything else does not.
    @MainActor
    func testCompletingEveryAnnouncedChapterResolvesTheUpdate() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try await pin(world, "1234", title: "雾港纪事")
        _ = await world.updateCoordinator.run(trigger: .manual)
        world.transport.setDirectoryPage("update-directory-appended")
        _ = await world.updateCoordinator.run(trigger: .manual)

        try await world.progress.markChapterCompleted(identity, chapterId: "10002", at: Date())
        let partial = Set(try await world.progress.completedChapterIds(identity))
        try await world.updates.reconcileCompleted(identity, completedChapterIds: partial)
        let stillThere = try await world.updates.unresolvedUpdates()
        XCTAssertEqual(stillThere.count, 1, "an unrelated chapter changes nothing")

        try await world.progress.markChapterCompleted(identity, chapterId: "10003", at: Date())
        let all = Set(try await world.progress.completedChapterIds(identity))
        try await world.updates.reconcileCompleted(identity, completedChapterIds: all)
        let resolved = try await world.updates.unresolvedUpdates()
        XCTAssertTrue(resolved.isEmpty)
    }

    /// Ignoring hides exactly the detection the reader saw and can be undone for a short while;
    /// neither touches progress.
    @MainActor
    func testIgnoringAnUpdateCanBeUndone() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try await pin(world, "1234", title: "雾港纪事")
        _ = await world.updateCoordinator.run(trigger: .manual)
        world.transport.setDirectoryPage("update-directory-appended")
        _ = await world.updateCoordinator.run(trigger: .manual)

        let library = world.libraryModel()
        await library.load()
        await library.ignoreUpdate(identity)
        XCTAssertNotNil(library.undoIgnoreToken)
        XCTAssertNil(library.update(for: identity))
        let progressAfter = try await world.progress.progress(identity)
        XCTAssertNil(progressAfter, "ignoring never writes progress")

        await library.undoIgnore()
        XCTAssertNil(library.undoIgnoreToken)
        XCTAssertEqual(library.update(for: identity)?.newChapterIds, ["10003"])
    }

    /// Exclusions keep a book or a whole source out of a session without removing anything.
    @MainActor
    func testExclusionsSkipBooksWithoutRemovingThem() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try await pin(world, "1234", title: "雾港纪事")
        try await world.updates.setBookExcluded(identity, excluded: true)
        _ = await world.updateCoordinator.run(trigger: .manual)
        let awaited4 = try await world.updates.latestSession()
        let session = try XCTUnwrap(awaited4)
        XCTAssertEqual(session.total, 0, "an excluded book is not enumerated")
        XCTAssertEqual(session.state, .completed)
        let shelf = try await world.library.libraryEntries()
        XCTAssertEqual(shelf.map(\.book.identity), [identity])

        try await world.updates.setBookExcluded(identity, excluded: false)
        try await world.updates.setSourceExcluded(world.sourceId.value, excluded: true)
        _ = await world.updateCoordinator.run(trigger: .manual)
        let awaited5 = try await world.updates.latestSession()
        let sourceSession = try XCTUnwrap(awaited5)
        XCTAssertEqual(sourceSession.total, 0)
        XCTAssertTrue(world.transport.requests.isEmpty, "nothing was asked of the source")
    }

    /// Books listed only by the website mirror are checked too; a session cannot start while
    /// another is live, and a cancelled session closes durably.
    @MainActor
    func testMirrorBooksAreInScopeAndSessionsDoNotOverlap() async throws {
        let world = try await MirrorWorld(directory: directory)
        _ = await world.coordinator.pull(world.sourceId)
        let candidates = try await world.updateCoordinator.candidates()
        XCTAssertEqual(candidates.map(\.identity.remoteBookId).sorted(), ["1234", "5678"])

        let awaited6 = try await world.updates.startSession(trigger: .manual, candidates: candidates, now: Date())
        let started = try XCTUnwrap(awaited6)
        let busy = await world.updateCoordinator.run(trigger: .manual)
        XCTAssertEqual(busy, .busy)
        let awaited7 = try await world.updates.cancelActiveSession(now: Date())
        XCTAssertTrue(awaited7)
        let awaited8 = try await world.updates.latestSession()
        let cancelled = try XCTUnwrap(awaited8)
        XCTAssertEqual(cancelled.sessionId, started.sessionId)
        XCTAssertEqual(cancelled.state, .cancelled)

        let fresh = await world.updateCoordinator.run(trigger: .manual)
        guard case .completed = fresh else { return XCTFail("a new session must start once the old one is closed") }
        let awaited9 = try await world.updates.latestSession()
        let session = try XCTUnwrap(awaited9)
        XCTAssertEqual(session.total, 2)
    }
}
