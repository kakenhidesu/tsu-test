// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import BrowseFeature
import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiRemoteLibrary
import TsuyomiSource
import XCTest

/// The website shelf: read into a mirror that never pins, and written to one signed, consented,
/// recorded request at a time. Every byte comes from the wenku8 fixtures through a fake transport.
final class RemoteMirrorJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testAPullMirrorsTheShelfAndItsFoldersWithoutPinningAnything() async throws {
        let world = try await MirrorWorld(directory: directory)
        let page = world.mirrorModel()
        await page.load()
        guard case .empty = page.state else { return XCTFail("an unread mirror is empty, not loading: \(page.state)") }
        XCTAssertTrue(world.transport.requests.isEmpty, "opening the page must not touch the site")

        await page.refresh()
        XCTAssertNil(page.notice)
        let content = try XCTUnwrap(page.content)
        XCTAssertEqual(content.items.map(\.identity.remoteBookId).sorted(), ["1234", "5678"])
        XCTAssertEqual(content.mirror.targets.map(\.targetId), ["0", "1"])
        XCTAssertEqual(content.mirror.targets.map(\.displayName), ["默认书架", "第1组书架"])
        XCTAssertEqual(content.defaultTargetId, "0")
        XCTAssertEqual(try await world.mirror.membership(try world.identity("1234"))?.targetId, "1")
        XCTAssertEqual(try await world.mirror.membership(try world.identity("5678"))?.targetId, "0")
        XCTAssertTrue(try await world.library.libraryEntries().isEmpty, "a mirror never pins")
        XCTAssertTrue(world.transport.writes.isEmpty)

        XCTAssertTrue(page.supportsGrouping)
        await page.setGrouping(true)
        let folder = world.mirrorModel(targetId: "1")
        await folder.load()
        XCTAssertEqual(folder.content?.items.map(\.identity.remoteBookId), ["1234"])
        XCTAssertEqual(try await world.mirror.membership(try world.identity("5678"))?.targetId, "0", "grouping moves nothing")
    }

    /// The first copy from a source asks once; the answer is a receipt, and the copy is local.
    @MainActor
    func testCopyingToTheLocalShelfAsksOncePerSourceAndWritesNothingRemotely() async throws {
        let world = try await MirrorWorld(directory: directory)
        let page = world.mirrorModel()
        await page.refresh()
        page.toggle(try world.identity("1234"))
        await page.copySelectedToLibrary()
        XCTAssertEqual(page.pendingCopy, [try world.identity("1234")])
        XCTAssertTrue(try await world.library.libraryEntries().isEmpty)
        await page.confirmCopy()
        XCTAssertEqual(page.notice, .copied(1))
        XCTAssertEqual(try await world.library.libraryEntries().map(\.book.identity.remoteBookId), ["1234"])

        await page.copyAllToLibrary()
        XCTAssertNil(page.pendingCopy, "the prompt is answered once per source")
        XCTAssertEqual(page.notice, .copied(1), "the book already on the shelf is not counted twice")
        XCTAssertTrue(world.transport.writes.isEmpty)
    }

    /// An add is refused until the source's add consent exists, then leaves exactly once, and is
    /// remembered so a second add is refused without asking the site.
    @MainActor
    func testAnAddNeedsConsentThenWritesOnceAndIsRemembered() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try world.identity("9999")
        let shelf = world.shelfModel(identity)
        await shelf.load()
        let detail = try SourceBookDetail(
            summary: try SourceBookSummary(
                identity: identity, title: "新书", author: "某人", coverUrl: nil, canonicalUrl: "https://www.wenku8.net/book/9999.htm"
            ),
            description: nil, tags: [], status: nil, lastUpdatedDate: nil
        )
        XCTAssertEqual(shelf.state?.canAdd, true)

        await shelf.addToWebsite(detail, targetId: nil, targetName: nil)
        XCTAssertEqual(shelf.pendingAuthorization, .add)
        XCTAssertNil(shelf.banner)
        XCTAssertTrue(world.transport.writes.isEmpty, "nothing leaves before consent")

        await shelf.authorizePendingOperation()
        XCTAssertNil(shelf.pendingAuthorization)
        XCTAssertEqual(shelf.banner, .added(targetName: nil))
        XCTAssertEqual(world.transport.writes.count, 1)
        XCTAssertEqual(shelf.state?.inMirror, true)
        let record = try XCTUnwrap(try await world.remoteLibrary.latestReconciliation(identity))
        XCTAssertEqual(record.state, .confirmed)
        XCTAssertEqual(record.operation, .add)
        XCTAssertTrue(try await world.library.libraryEntries().isEmpty, "a website add never pins locally")

        await shelf.addToWebsite(detail, targetId: nil, targetName: nil)
        XCTAssertEqual(shelf.banner, .result(.add, .failure(.bookAlreadyAdded, code: "book-already-added")))
        XCTAssertEqual(world.transport.writes.count, 1, "a remembered add is not repeated")
    }

    /// A request that fails after its token was accepted may have reached the site. The record
    /// stays unresolved and blocks every other write until a retry the site answers closes it.
    @MainActor
    func testAFailureAfterAcceptanceStaysUnresolvedUntilARetryIsAnswered() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try world.identity("1234")
        XCTAssertEqual(await world.coordinator.pull(world.sourceId), .success(count: 2))
        try await world.coordinator.grantWriteback(.remove, sourceId: world.sourceId)
        try await world.coordinator.grantWriteback(.move, sourceId: world.sourceId)

        world.transport.failNext(.transport)
        XCTAssertEqual(await world.coordinator.remove(identity), .unresolved)
        let unresolved = try XCTUnwrap(try await world.remoteLibrary.latestReconciliation(identity))
        XCTAssertEqual(unresolved.state, .unresolved)
        XCTAssertNotNil(try await world.mirror.membership(identity), "an unanswered removal changes nothing here")

        XCTAssertEqual(
            await world.coordinator.move(identity, targetId: "0", targetName: "默认书架"),
            .failure(.blockedUnresolved, code: "remote-mutation-blocked-unresolved")
        )
        XCTAssertEqual(await world.coordinator.retry(identity), .confirmed)
        let closed = try XCTUnwrap(try await world.remoteLibrary.latestReconciliation(identity))
        XCTAssertEqual(closed.state, .confirmed)
        XCTAssertEqual(try await world.remoteLibrary.reconciliation(id: unresolved.id)?.state, .confirmed, "the chain closes")
        XCTAssertNil(try await world.mirror.membership(identity))
        XCTAssertEqual(world.transport.writes.count, 2)
    }

    /// `仅解除锁定` releases a move or removal without claiming an outcome, and never an add.
    @MainActor
    func testAcknowledgingAnUnresolvedRecordReleasesMovesButNeverAdds() async throws {
        let world = try await MirrorWorld(directory: directory)
        let identity = try world.identity("1234")
        _ = await world.coordinator.pull(world.sourceId)
        try await world.coordinator.grantWriteback(.move, sourceId: world.sourceId)
        try await world.coordinator.grantWriteback(.add, sourceId: world.sourceId)

        world.transport.failNext(.transport)
        XCTAssertEqual(await world.coordinator.move(identity, targetId: "0", targetName: nil), .unresolved)
        XCTAssertTrue(await world.coordinator.acknowledgeUnresolved(identity))
        XCTAssertEqual(try await world.remoteLibrary.latestReconciliation(identity)?.state, .cancelled)

        let fresh = try world.identity("9999")
        let book = LibraryBook(identity: fresh, title: "新书", addedAt: Date(), metadataUpdatedAt: Date())
        world.transport.failNext(.transport)
        XCTAssertEqual(await world.coordinator.add(book, targetId: nil, targetName: nil), .unresolved)
        XCTAssertFalse(await world.coordinator.acknowledgeUnresolved(fresh), "an add the site may have applied cannot be declared undone")
        XCTAssertEqual(try await world.remoteLibrary.latestReconciliation(fresh)?.state, .unresolved)
    }

    /// An add into a named folder is an add and then a move; both are recorded and the mirror ends
    /// in the folder the reader chose.
    @MainActor
    func testATargetedAddContinuesWithAMove() async throws {
        let world = try await MirrorWorld(directory: directory)
        _ = await world.coordinator.pull(world.sourceId)
        try await world.coordinator.grantWriteback(.add, sourceId: world.sourceId)
        try await world.coordinator.grantWriteback(.move, sourceId: world.sourceId)
        let fresh = try world.identity("9999")
        let book = LibraryBook(identity: fresh, title: "新书", addedAt: Date(), metadataUpdatedAt: Date())

        XCTAssertEqual(
            await world.coordinator.add(book, targetId: "1", targetName: "第1组书架"),
            .confirmed(targetId: "1")
        )
        XCTAssertEqual(world.transport.writes.count, 2)
        XCTAssertEqual(try await world.mirror.membership(fresh)?.targetId, "1")
        XCTAssertEqual(
            await world.coordinator.add(book, targetId: "0", targetName: "默认书架"),
            .confirmed(targetId: "0"),
            "an add into the default folder is one request"
        )
    }

    /// Without a stored session nothing is sent: the site would only answer with its login page.
    @MainActor
    func testASignedOutSourceIsAskedToLogInBeforeAnyWrite() async throws {
        let world = try await MirrorWorld(directory: directory, signedIn: false)
        try await world.coordinator.grantWriteback(.add, sourceId: world.sourceId)
        let book = LibraryBook(identity: try world.identity("9999"), title: "新书", addedAt: Date(), metadataUpdatedAt: Date())
        XCTAssertEqual(await world.coordinator.add(book, targetId: nil, targetName: nil), .loginRequired)
        XCTAssertTrue(world.transport.writes.isEmpty)
        XCTAssertNil(try await world.remoteLibrary.latestReconciliation(try world.identity("9999")), "no attempt is opened")
    }

    /// The page's removal is a single-selection act: consent, then a confirmation naming the book,
    /// then the request; the mirror row goes only when the site says the book is gone.
    @MainActor
    func testThePageRemovesOneSelectedBookAfterConsentAndConfirmation() async throws {
        let world = try await MirrorWorld(directory: directory)
        let page = world.mirrorModel()
        await page.refresh()
        page.toggle(try world.identity("1234"))
        page.toggle(try world.identity("5678"))
        await page.requestRemoveSelected()
        XCTAssertNil(page.pendingAuthorization, "removal is offered for one book only")

        page.toggle(try world.identity("5678"))
        await page.requestRemoveSelected()
        XCTAssertEqual(page.pendingAuthorization, .remove(try world.identity("1234")))
        await page.authorizePendingAction()
        XCTAssertEqual(page.pendingRemoveConfirmation, .remove(try world.identity("1234")))
        XCTAssertTrue(world.transport.writes.isEmpty)
        await page.confirmRemove()
        XCTAssertEqual(page.notice, .mutation(.remove, .confirmed))
        XCTAssertEqual(page.content?.items.map(\.identity.remoteBookId), ["5678"])
        XCTAssertEqual(world.transport.writes.count, 1)
        XCTAssertTrue(page.selected.isEmpty)
    }
}
