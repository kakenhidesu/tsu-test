// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class TransferRepositoryTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func identity(_ remoteBookId: String) throws -> BookIdentity {
        try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: remoteBookId)
    }

    private func populated() async throws -> TsuyomiDatabase {
        let database = try TsuyomiDatabase.inMemory()
        let repository = LibraryRepository(database: database)
        let collections = CollectionStore(database: database)
        let progress = ReadingProgressStore(database: database)
        try await collections.createCollection(
            try LibraryCollection(
                collectionId: "shelf", kind: .manual, title: "书架", parentCollectionId: nil, displayOrder: 0
            )
        )
        for index in 1...2 {
            let identity = try identity("\(index)")
            try await repository.addToLibrary(
                LibraryBook(
                    identity: identity,
                    title: "書\(index)",
                    addedAt: createdAt,
                    metadataUpdatedAt: createdAt,
                    authors: ["作者"],
                    coverUrl: "https://www.wenku8.net/cover/\(index).jpg",
                    canonicalUrl: "https://www.wenku8.net/book/\(index).htm",
                    status: "ongoing",
                    remoteTags: ["奇幻"]
                )
            )
            try await repository.setLocalTags(identity, tags: ["置顶"])
            try await repository.setRating(identity, rating: 4)
            try await collections.addManualMembership("shelf", identity)
            try await progress.saveProgress(
                try ReadingProgress(
                    identity: identity,
                    locator: try ReaderLocator(
                        document: try DocumentIdentity(
                            sourceId: identity.sourceId,
                            remoteBookId: identity.remoteBookId,
                            contentId: "chapter-\(index)"
                        ),
                        blockId: "b1",
                        characterOffset: index * 10,
                        capturedAt: createdAt
                    )
                )
            )
        }
        return database
    }

    func testExportThenImportRestoresEveryField() async throws {
        let source = TransferRepository(database: try await populated())
        let snapshot = try await source.exportSnapshot(createdAt: createdAt, readerPreferences: nil)
        let encoded = try TransferCodec.encode(snapshot)

        guard case .ready(let plan, let digest) = TransferCodec.parse(encoded) else {
            return XCTFail("expected the exported document to parse")
        }
        let restored = try TsuyomiDatabase.inMemory()
        let repository = TransferRepository(database: restored)
        try await repository.prepare(
            sessionId: "session",
            plan: plan,
            planDigest: digest,
            normalizedPlanPath: "plans/session.json",
            preferencePatchJson: "{}",
            startedAt: createdAt
        )
        try await repository.applyPlan(sessionId: "session", digest: digest, plan: plan)

        let roundTrip = try await repository.exportSnapshot(createdAt: createdAt, readerPreferences: nil)
        XCTAssertEqual(try TransferCodec.encode(roundTrip), encoded)
    }

    func testApplyPlanIsIdempotentAfterTheRoomStage() async throws {
        let source = TransferRepository(database: try await populated())
        let snapshot = try await source.exportSnapshot(createdAt: createdAt, readerPreferences: nil)
        guard case .ready(let plan, let digest) = TransferCodec.parse(try TransferCodec.encode(snapshot)) else {
            return XCTFail("expected the exported document to parse")
        }
        let database = try TsuyomiDatabase.inMemory()
        let repository = TransferRepository(database: database)
        try await repository.prepare(
            sessionId: "session",
            plan: plan,
            planDigest: digest,
            normalizedPlanPath: "plans/session.json",
            preferencePatchJson: "{}",
            startedAt: createdAt
        )
        try await repository.applyPlan(sessionId: "session", digest: digest, plan: plan)
        try await repository.applyPlan(sessionId: "session", digest: digest, plan: plan)

        let entries = try await LibraryRepository(database: database).libraryEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.localTags, ["置顶"])
    }

    func testImportDigestMismatchIsRejected() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let repository = TransferRepository(database: database)
        let plan = ImportPlan(
            kind: .tsuyomiTransfer,
            sourceCreatedAt: createdAt,
            books: [],
            shelves: [],
            readerPreferences: nil
        )
        try await repository.prepare(
            sessionId: "session",
            plan: plan,
            planDigest: "digest",
            normalizedPlanPath: "plans/session.json",
            preferencePatchJson: "{}",
            startedAt: createdAt
        )
        do {
            try await repository.applyPlan(sessionId: "session", digest: "other", plan: plan)
            XCTFail("expected a digest mismatch to abort")
        } catch {
            XCTAssertNotNil(error as? DatabaseError)
        }
    }

    func testDatabaseConflictsAreReportedBeforeAnythingIsWritten() async throws {
        let database = try await populated()
        let repository = TransferRepository(database: database)
        let existing = try await repository.exportSnapshot(createdAt: createdAt, readerPreferences: nil)
        guard case .ready(let plan, _) = TransferCodec.parse(try TransferCodec.encode(existing)) else {
            return XCTFail("expected the exported document to parse")
        }
        let annotated = try await repository.withDatabaseConflicts(plan)
        XCTAssertTrue(annotated.warnings.contains { $0.safeCode == "existing-progress-retained" })
        XCTAssertTrue(annotated.warnings.allSatisfy { $0.severity == .conflict })
    }

    func testAnImportNeverInheritsRemoteWriteConsent() async throws {
        let database = try TsuyomiDatabase.inMemory()
        let remote = RemoteLibraryStore(database: database)
        try await remote.saveSourceRemotePolicy(
            SourceRemotePolicy(
                sourceId: "org.tsuyomi.wenku8",
                trustedPublisherFingerprint: "publisher",
                capabilitySetFingerprint: "capability",
                approvedOrigin: "https://www.wenku8.net",
                addWritebackEnabled: true,
                firstImportPromptDismissed: true
            )
        )
        let repository = TransferRepository(database: database)
        let plan = ImportPlan(
            kind: .tsuyomiTransfer,
            sourceCreatedAt: createdAt,
            books: [],
            shelves: [],
            readerPreferences: nil
        )
        try await repository.prepare(
            sessionId: "session",
            plan: plan,
            planDigest: "digest",
            normalizedPlanPath: "plans/session.json",
            preferencePatchJson: "{}",
            startedAt: createdAt
        )
        try await repository.applyPlan(sessionId: "session", digest: "digest", plan: plan)

        let policy = try await remote.sourceRemotePolicy("org.tsuyomi.wenku8")
        XCTAssertEqual(policy?.addWritebackEnabled, false)
    }
}
