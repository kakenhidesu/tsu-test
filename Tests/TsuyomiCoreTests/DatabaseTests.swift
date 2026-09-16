// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SQLite3
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class DatabaseTests: XCTestCase {
    private func identity(_ remoteBookId: String) throws -> BookIdentity {
        try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: remoteBookId)
    }

    private func book(_ remoteBookId: String, title: String, addedAt: Date = Date(timeIntervalSince1970: 1_700)) throws
        -> LibraryBook {
        LibraryBook(
            identity: try identity(remoteBookId),
            title: title,
            addedAt: addedAt,
            metadataUpdatedAt: addedAt,
            authors: ["  某  作者 "],
            status: "ongoing",
            remoteTags: ["奇幻", "冒险"]
        )
    }

    func testSchemaIsCreatedAtTheCurrentVersion() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let version = try await database.read { connection in
            try connection.query("PRAGMA user_version").first?["user_version"].int
        }
        XCTAssertEqual(version, 10)
        let tables = try await database.read { connection in
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .compactMap { $0["name"].string }
        }
        for expected in [
            "books", "browsing_history", "collections", "completed_chapters", "import_sessions", "import_warnings",
            "library_entries", "local_book_tags", "manual_collection_memberships", "reading_progress",
            "remote_library_reconciliation", "remote_mirror_bindings", "remote_mirror_items", "remote_mirror_targets",
            "search_history", "smart_rules", "source_availability", "source_remote_policy", "subscription_drafts",
            "unresolved_updates", "update_baselines", "update_book_exclusions", "update_ignore_undos", "update_policy",
            "update_session_items", "update_sessions", "update_source_exclusions"
        ] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
    }

    func testAuthorsAndTagsAreNormalisedBeforeStorage() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        try await repository.saveBook(try book("1", title: "書"))
        let stored = try await repository.book(try identity("1"))
        XCTAssertEqual(stored?.authors, ["某 作者"])
        XCTAssertEqual(stored?.remoteTags, ["冒险", "奇幻"])
    }

    func testRemovingALibraryEntryCascadesToTagsAndProgress() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let progress = ReadingProgressStore(database: database)
        let identity = try identity("1")
        try await repository.addToLibrary(try book("1", title: "書"))
        try await repository.setLocalTags(identity, tags: ["置顶"])
        try await progress.saveProgress(try progressRecord(identity, offset: 10, at: 1_000))

        let removed = try await repository.removeFromLibrary(identity)
        XCTAssertTrue(removed)
        let tags = try await database.read { connection in
            try connection.query("SELECT COUNT(*) AS count FROM local_book_tags").first?["count"].int
        }
        XCTAssertEqual(tags, 0)
        // The book row survives: only the library entry and its dependents are removed.
        let book = try await repository.book(identity)
        XCTAssertNotNil(book)
        let stored = try await progress.progress(identity)
        XCTAssertNotNil(stored)
    }

    func testLibraryReorderIsIdempotentAndTotal() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        for index in 1...3 { try await repository.addToLibrary(try book("\(index)", title: "書\(index)")) }
        let order = [try identity("3"), try identity("1"), try identity("2")]

        try await repository.reorderLibrary(order)
        try await repository.reorderLibrary(order)
        let entries = try await repository.libraryEntries().map(\.book.identity)
        XCTAssertEqual(entries, order)

        do {
            try await repository.reorderLibrary([try identity("3")])
            XCTFail("expected a partial reorder to be rejected")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    func testProgressConflictKeepsTheNewerCaptureAndTiesKeepTheHostRecord() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let store = ReadingProgressStore(database: database)
        let identity = try identity("1")
        try await repository.addToLibrary(try book("1", title: "書"))

        var result = try await store.saveProgress(try progressRecord(identity, offset: 900, at: 1_000))
        XCTAssertEqual(result, .applied)
        result = try await store.saveProgress(try progressRecord(identity, offset: 100, at: 2_000))
        XCTAssertEqual(result, .applied)
        let current = try await store.progress(identity)?.locator.characterOffset
        XCTAssertEqual(current, 100)

        result = try await store.saveProgress(try progressRecord(identity, offset: 900, at: 1_500))
        XCTAssertEqual(result, .keptExisting)
        result = try await store.saveProgress(try progressRecord(identity, offset: 500, at: 2_000))
        XCTAssertEqual(result, .keptExisting)
        let settled = try await store.progress(identity)?.locator.characterOffset
        XCTAssertEqual(settled, 100)
    }

    func testCollectionOrderIsCompactedAfterDeletion() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = CollectionStore(database: database)
        for index in 0..<3 {
            try await store.createCollection(
                try LibraryCollection(
                    collectionId: "c\(index)",
                    kind: .manual,
                    title: "Shelf \(index)",
                    parentCollectionId: nil,
                    displayOrder: Int64(index)
                )
            )
        }
        let deleted = try await store.deleteCollection("c1")
        XCTAssertTrue(deleted)
        let orders = try await store.collections().map(\.displayOrder)
        XCTAssertEqual(orders, [0, 1])
    }

    func testCollectionParentCyclesAreRejected() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = CollectionStore(database: database)
        try await store.createCollection(
            try LibraryCollection(
                collectionId: "a", kind: .manual, title: "A", parentCollectionId: nil, displayOrder: 0
            )
        )
        try await store.createCollection(
            try LibraryCollection(
                collectionId: "b", kind: .manual, title: "B", parentCollectionId: "a", displayOrder: 0
            )
        )
        do {
            try await store.updateCollectionPresentation("a", parentCollectionId: "b", displayOrder: 0)
            XCTFail("expected a cycle to be rejected")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    func testManualMembershipOrderIsCompactedAfterRemoval() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let store = CollectionStore(database: database)
        for index in 1...3 { try await repository.addToLibrary(try book("\(index)", title: "書\(index)")) }
        try await store.createManualCollectionWithMemberships(
            try LibraryCollection(
                collectionId: "shelf", kind: .manual, title: "Shelf", parentCollectionId: nil, displayOrder: 0
            ),
            identities: [try identity("1"), try identity("2"), try identity("3")]
        )
        let removed = try await store.removeManualMemberships("shelf", [try identity("2")])
        XCTAssertEqual(removed, 1)
        let orders = try await database.read { connection in
            try connection.query(
                "SELECT display_order FROM manual_collection_memberships ORDER BY display_order"
            ).compactMap { $0["display_order"].int }
        }
        XCTAssertEqual(orders, [0, 1])
    }

    func testSmartShelfCompilesToAParameterisedQueryWithTheExpectedHits() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let store = CollectionStore(database: database)
        try await repository.addToLibrary(try book("1", title: "夜行"))
        try await repository.addToLibrary(try book("2", title: "晨光"))
        try await repository.setLocalTags(try identity("1"), tags: ["置顶"])

        let rule = try SmartRule(root: .predicate(.tagContains(mode: .any, tags: ["置顶"])))
        let compiled = try SmartShelfQueryCompiler.compile(rule, now: Date(timeIntervalSince1970: 10_000))
        XCTAssertFalse(compiled.sql.contains("置顶"))
        XCTAssertEqual(compiled.bindings.count, 2)

        try await store.createSmartCollection(
            try LibraryCollection(
                collectionId: "smart", kind: .smart, title: "Pinned", parentCollectionId: nil, displayOrder: 0
            ),
            rule: rule
        )
        let entries = try await store.collectionEntries("smart", now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(entries.map(\.book.identity.remoteBookId), ["1"])
    }

    func testAMirrorSnapshotRequiresAnUnchangedLeaseAndNeverPins() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = RemoteLibraryStore(database: database)
        let mirror = RemoteMirrorStore(database: database)
        try await store.setSourceAvailability(
            sourceId: "org.tsuyomi.wenku8", version: "0.2.0", available: true, generation: 3
        )
        try await store.saveSourceRemotePolicy(
            SourceRemotePolicy(
                sourceId: "org.tsuyomi.wenku8",
                trustedPublisherFingerprint: "publisher",
                capabilitySetFingerprint: "capability",
                approvedOrigin: "https://www.wenku8.net",
                addWritebackEnabled: false,
                firstImportPromptDismissed: false
            )
        )
        let folder = RemoteMirrorTarget(
            sourceId: "org.tsuyomi.wenku8", targetId: "t1", displayName: "默认", parentId: nil, kind: "folder"
        )
        func snapshot(_ targets: [RemoteMirrorTarget], generation: Int64) throws -> RemoteMirrorSnapshot {
            RemoteMirrorSnapshot(
                sourceId: "org.tsuyomi.wenku8",
                displayName: "Wenku8",
                targets: targets,
                books: [try book("1", title: "書")],
                memberships: [try identity("1"): "t1"],
                expectedVersion: "0.2.0",
                expectedCapabilityFingerprint: "capability",
                expectedGeneration: generation,
                observedAt: Date(timeIntervalSince1970: 5_000)
            )
        }
        try await mirror.save(try snapshot([folder], generation: 3))
        let saved = try XCTUnwrap(try await mirror.mirror(sourceId: "org.tsuyomi.wenku8"))
        XCTAssertEqual(saved.items.map(\.identity.remoteBookId), ["1"])
        XCTAssertEqual(saved.targets.map(\.frozen), [false])
        let awaited1 = try await LibraryRepository(database: database).libraryEntries().isEmpty
        XCTAssertTrue(awaited1, "a mirror never pins")

        try await mirror.save(try snapshot([], generation: 3))
        let refreshed = try XCTUnwrap(try await mirror.mirror(sourceId: "org.tsuyomi.wenku8"))
        XCTAssertEqual(refreshed.targets.map(\.frozen), [true], "a target the site stopped listing survives frozen")

        try await store.setSourceAvailability(
            sourceId: "org.tsuyomi.wenku8", version: "0.3.0", available: true, generation: 4
        )
        do {
            try await mirror.save(try snapshot([folder], generation: 3))
            XCTFail("expected a stale lease to abort the snapshot")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    func testReconciliationTransitionsFollowTheDeclaredStateMachine() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = RemoteLibraryStore(database: database)
        func request(_ operation: RemoteWriteOperation, retrying: String? = nil) throws -> RemoteMutationRequest {
            RemoteMutationRequest(
                book: try book("1", title: "書"),
                operation: operation,
                packageDigest: "digest",
                packageVersion: "0.2.0",
                capabilitySetFingerprint: "capability",
                registryGeneration: 1,
                retryingUnresolvedId: retrying,
                startedAt: Date(timeIntervalSince1970: 1_000)
            )
        }
        let id = try await store.beginRemoteMutation(try request(.add))
        let started = try await store.transitionRemoteMutation(
            id: id, expected: .pendingUserAction, next: .inFlight, now: Date(timeIntervalSince1970: 1_001)
        )
        XCTAssertTrue(started)
        do {
            _ = try await store.transitionRemoteMutation(
                id: id, expected: .inFlight, next: .pendingUserAction, now: Date(timeIntervalSince1970: 1_002)
            )
            XCTFail("expected an illegal transition to be rejected")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
        let awaited2 = try await store.transitionRemoteMutation(
            id: id, expected: .inFlight, next: .unresolved, now: Date(timeIntervalSince1970: 1_003)
        )
        XCTAssertTrue(awaited2)
        do {
            _ = try await store.beginRemoteMutation(try request(.remove))
            XCTFail("an unresolved attempt blocks any other operation")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
        do {
            _ = try await store.transitionRemoteMutation(
                id: id, expected: .unresolved, next: .cancelled, now: Date(timeIntervalSince1970: 1_004)
            )
            XCTFail("an accepted add can never be declared undone")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
        let retry = try await store.beginRemoteMutation(try request(.add, retrying: id))
        let awaited3 = try await store.transitionRemoteMutation(
            id: retry, expected: .pendingUserAction, next: .inFlight, now: Date(timeIntervalSince1970: 1_005)
        )
        XCTAssertTrue(awaited3)
        let awaited4 = try await store.transitionRemoteMutation(
            id: retry, expected: .inFlight, next: .confirmed, now: Date(timeIntervalSince1970: 1_006)
        )
        XCTAssertTrue(awaited4)
        try await store.confirmUnresolvedMutations(try identity("1"), operation: .add, now: Date(timeIntervalSince1970: 1_007))
        let awaited5 = try await store.reconciliation(id: id)?.state
        XCTAssertEqual(awaited5, .confirmed)
        let awaited6 = try await store.latestReconciliation(try identity("1"))?.id
        XCTAssertEqual(awaited6, retry)
    }

    /// Removal keeps everything the reader wrote about the book; only the pin and the manual
    /// memberships go, and adding again brings the pin back over the same annotations.
    func testRemovalUnpinsButKeepsTheRetainedRecord() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let library = LibraryRepository(database: database)
        let collections = CollectionStore(database: database)
        let identity = try identity("1")
        let awaited7 = try await library.addToLibrary(try book("1", title: "書"))
        XCTAssertTrue(awaited7)
        try await library.setRating(identity, rating: 4)
        try await library.setLocalTags(identity, tags: ["收藏"])
        try await library.setReadLater(identity, readLater: true)
        try await collections.createCollection(
            try LibraryCollection(collectionId: "c1", kind: .manual, title: "夹", parentCollectionId: nil, displayOrder: 0)
        )
        let awaited8 = try await collections.addManualMembership("c1", identity)
        XCTAssertTrue(awaited8)

        let awaited9 = try await library.removeFromLibrary(identity)
        XCTAssertTrue(awaited9)
        let awaited10 = try await library.removeFromLibrary(identity)
        XCTAssertFalse(awaited10, "removing an unpinned book changes nothing")
        let awaited11 = try await library.libraryEntries().isEmpty
        XCTAssertTrue(awaited11)
        let retained = try XCTUnwrap(try await library.libraryEntry(identity))
        XCTAssertFalse(retained.localMembership)
        XCTAssertEqual(retained.rating, 4)
        XCTAssertEqual(retained.localTags, ["收藏"])
        XCTAssertTrue(retained.readLater)
        let awaited12 = try await library.readLaterEntries().map(\.book.identity)
        XCTAssertEqual(awaited12, [identity])
        let awaited13 = try await collections.collectionEntries("c1").isEmpty
        XCTAssertTrue(awaited13)
        do {
            _ = try await collections.addManualMembership("c1", identity)
            XCTFail("a retained record cannot hold a manual membership")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }

        let awaited14 = try await library.addToLibrary(try book("1", title: "書"))
        XCTAssertTrue(awaited14)
        let pinned = try XCTUnwrap(try await library.libraryEntry(identity))
        XCTAssertTrue(pinned.localMembership)
        XCTAssertEqual(pinned.rating, 4)
        let awaited15 = try await library.libraryEntries().count
        XCTAssertEqual(awaited15, 1)
    }

    /// A policy row follows the package that verifies now. The reader's consents are kept only when
    /// the publisher and capability set are the very ones they were given for.
    func testPolicySynchronisationRetiresReceiptsWhenTheCapabilitySetChanges() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = RemoteLibraryStore(database: database)
        try await store.synchronizeVerifiedPackage(
            sourceId: "org.tsuyomi.wenku8", publisherFingerprint: "pub", capabilityFingerprint: "cap-1",
            approvedOrigin: "https://www.wenku8.net", preserveWriteback: true
        )
        let awaited16 = try await store.setWritebackEnabled(.add, sourceId: "org.tsuyomi.wenku8", capabilityFingerprint: "cap-1", enabled: true)
        XCTAssertTrue(awaited16)
        let awaited17 = try await store.dismissFirstRemoteImportPrompt(sourceId: "org.tsuyomi.wenku8", capabilityFingerprint: "cap-1")
        XCTAssertTrue(awaited17)

        try await store.synchronizeVerifiedPackage(
            sourceId: "org.tsuyomi.wenku8", publisherFingerprint: "pub", capabilityFingerprint: "cap-1",
            approvedOrigin: "https://www.wenku8.net", preserveWriteback: true
        )
        var policy = try XCTUnwrap(try await store.sourceRemotePolicy("org.tsuyomi.wenku8"))
        XCTAssertTrue(policy.addWritebackEnabled, "the same set keeps its receipts")
        XCTAssertTrue(policy.firstImportPromptDismissed)

        try await store.synchronizeVerifiedPackage(
            sourceId: "org.tsuyomi.wenku8", publisherFingerprint: "pub", capabilityFingerprint: "cap-1",
            approvedOrigin: "https://www.wenku8.net", preserveWriteback: false
        )
        policy = try XCTUnwrap(try await store.sourceRemotePolicy("org.tsuyomi.wenku8"))
        XCTAssertFalse(policy.addWritebackEnabled, "a downgrade retires the receipts")
        XCTAssertTrue(policy.firstImportPromptDismissed, "the copy prompt is about the set, not the version")

        try await store.setWritebackEnabled(.add, sourceId: "org.tsuyomi.wenku8", capabilityFingerprint: "cap-1", enabled: true)
        try await store.synchronizeVerifiedPackage(
            sourceId: "org.tsuyomi.wenku8", publisherFingerprint: "pub", capabilityFingerprint: "cap-2",
            approvedOrigin: "https://www.wenku8.net", preserveWriteback: true
        )
        policy = try XCTUnwrap(try await store.sourceRemotePolicy("org.tsuyomi.wenku8"))
        XCTAssertFalse(policy.addWritebackEnabled, "a changed set retires the receipts")
        XCTAssertFalse(policy.firstImportPromptDismissed)
        XCTAssertEqual(policy.capabilitySetFingerprint, "cap-2")
    }

    func testChapterCompletionIsExactAndFirstWins() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let library = LibraryRepository(database: database)
        let progress = ReadingProgressStore(database: database)
        let identity = try identity("1")
        try await library.saveBook(try book("1", title: "書"))
        try await progress.markChapterCompleted(identity, chapterId: "c2", at: Date(timeIntervalSince1970: 20))
        try await progress.markChapterCompleted(identity, chapterId: "c1", at: Date(timeIntervalSince1970: 30))
        try await progress.markChapterCompleted(identity, chapterId: "c2", at: Date(timeIntervalSince1970: 40))
        let awaited18 = try await progress.completedChapterIds(identity)
        XCTAssertEqual(awaited18, ["c2", "c1"])
        do {
            try await progress.markChapterCompleted(identity, chapterId: "  ", at: Date())
            XCTFail("a blank chapter id is not a completion")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    /// A database written at the frozen v4 schema is carried to the current version in place.
    func testAVersionFourDatabaseIsMigratedInPlace() async throws {
        let path = NSTemporaryDirectory() + "migrate-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        let raw = try XCTUnwrap(handle)
        let legacy = SQLiteConnection(handle: raw)
        for statement in TsuyomiSchema.version4 { try legacy.execute(statement) }
        try legacy.execute("PRAGMA user_version=4")
        try legacy.execute(
            """
            INSERT INTO books (source_id, remote_book_id, title, added_at_epoch_second, added_at_nano,
            metadata_updated_at_epoch_second, metadata_updated_at_nano) VALUES ('org.tsuyomi.wenku8', '1', '書', 1, 0, 1, 0)
            """
        )
        try legacy.execute(
            """
            INSERT INTO library_entries (source_id, remote_book_id, added_at_epoch_second, added_at_nano)
            VALUES ('org.tsuyomi.wenku8', '1', 1, 0)
            """
        )
        sqlite3_close_v2(raw)

        let database = try TsuyomiDatabase(path: path)
        let version = try await database.read { try $0.query("PRAGMA user_version").first?["user_version"].int }
        XCTAssertEqual(version, 10)
        let entries = try await LibraryRepository(database: database).libraryEntries()
        XCTAssertEqual(entries.map(\.localMembership), [true], "every pre-existing entry is pinned")
        let tables = try await database.read { connection in
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"].string }
        }
        XCTAssertTrue(Set(tables).isSuperset(of: ["completed_chapters", "remote_mirror_items", "unresolved_updates"]))
    }

    private func progressRecord(_ identity: BookIdentity, offset: Int, at seconds: TimeInterval) throws
        -> ReadingProgress {
        let capturedAt = Date(timeIntervalSince1970: seconds)
        return try ReadingProgress(
            identity: identity,
            locator: try ReaderLocator(
                document: try DocumentIdentity(
                    sourceId: identity.sourceId,
                    remoteBookId: identity.remoteBookId,
                    contentId: "chapter-1"
                ),
                blockId: "b1",
                characterOffset: offset,
                capturedAt: capturedAt
            ),
            updatedAt: capturedAt
        )
    }
}
