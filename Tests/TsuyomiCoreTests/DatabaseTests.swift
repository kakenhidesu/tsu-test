// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
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

    func testSchemaIsCreatedAtVersionFour() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let version = try await database.read { connection in
            try connection.query("PRAGMA user_version").first?["user_version"].int
        }
        XCTAssertEqual(version, 4)
        let tables = try await database.read { connection in
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .compactMap { $0["name"].string }
        }
        for expected in [
            "books", "browsing_history", "collections", "import_sessions", "import_warnings", "library_entries",
            "local_book_tags", "manual_collection_memberships", "reading_progress",
            "remote_library_reconciliation", "search_history", "smart_rules", "source_availability",
            "source_remote_policy", "subscription_drafts"
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

    func testRemoteMergeRequiresAnUnchangedLease() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = RemoteLibraryStore(database: database)
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
        let request = RemoteLibraryMergeRequest(
            sourceId: "org.tsuyomi.wenku8",
            books: [try book("1", title: "書")],
            expectedVersion: "0.2.0",
            expectedCapabilityFingerprint: "capability",
            expectedGeneration: 3,
            importedAt: Date(timeIntervalSince1970: 5_000)
        )
        let added = try await store.merge(request)
        XCTAssertEqual(added, 1)

        try await store.setSourceAvailability(
            sourceId: "org.tsuyomi.wenku8", version: "0.3.0", available: true, generation: 4
        )
        do {
            _ = try await store.merge(request)
            XCTFail("expected a stale lease to abort the merge")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    func testReconciliationTransitionsFollowTheDeclaredStateMachine() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let store = RemoteLibraryStore(database: database)
        let id = try await store.beginRemoteAdd(
            RemoteAddRequest(
                book: try book("1", title: "書"),
                packageDigest: "digest",
                packageVersion: "0.2.0",
                capabilitySetFingerprint: "capability",
                registryGeneration: 1,
                startedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        let started = try await store.transitionRemoteAdd(
            id: id, expected: .pendingUserAction, next: .inFlight, now: Date(timeIntervalSince1970: 1_001)
        )
        XCTAssertTrue(started)
        do {
            _ = try await store.transitionRemoteAdd(
                id: id, expected: .inFlight, next: .pendingUserAction, now: Date(timeIntervalSince1970: 1_002)
            )
            XCTFail("expected an illegal transition to be rejected")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
        let confirmed = try await store.transitionRemoteAdd(
            id: id, expected: .inFlight, next: .confirmed, now: Date(timeIntervalSince1970: 1_003)
        )
        XCTAssertTrue(confirmed)
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
