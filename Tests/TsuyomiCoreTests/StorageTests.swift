// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiCore

final class StorageTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func roots() throws -> StorageRoots { try StorageRoots(base: base) }

    func testSafeRelativePathRejectsTraversalAndAbsolutePaths() {
        XCTAssertTrue(isSafeRelativePath("a/b/c.bin"))
        XCTAssertFalse(isSafeRelativePath(""))
        XCTAssertFalse(isSafeRelativePath("  "))
        XCTAssertFalse(isSafeRelativePath("/etc/passwd"))
        XCTAssertFalse(isSafeRelativePath("a/../../b"))
        XCTAssertFalse(isSafeRelativePath("a//b"))
        XCTAssertFalse(isSafeRelativePath("a/./b"))
        XCTAssertFalse(isSafeRelativePath("a\\..\\b"))
        XCTAssertTrue(isSinglePathSegment("covers"))
        XCTAssertFalse(isSinglePathSegment("covers/deep"))
    }

    func testDurableStoreRefusesToEvictWhenQuotaCannotBeSatisfied() async throws {
        let store = try QuotaFileStore(
            roots: try roots(),
            root: .extensions,
            namespace: "packages",
            quota: StorageQuota(maximumBytes: 32, maximumEntries: 4)
        )
        _ = try await store.write("a.bin", bytes: Data(count: 24))
        do {
            _ = try await store.write("b.bin", bytes: Data(count: 24))
            XCTFail("expected the durable quota to refuse the write")
        } catch {
            XCTAssertEqual(error as? StorageError, .quotaExceeded)
        }
        let existing = try await store.read("a.bin")
        XCTAssertEqual(existing?.count, 24)
    }

    func testCacheStoreEvictsLeastRecentlyUsedEntries() async throws {
        let store = try QuotaFileStore(
            roots: try roots(),
            root: .cache,
            namespace: "responses",
            quota: StorageQuota(maximumBytes: 40, maximumEntries: 8)
        )
        _ = try await store.write("a.bin", bytes: Data(count: 16))
        _ = try await store.write("b.bin", bytes: Data(count: 16))
        _ = try await store.read("a.bin")
        _ = try await store.write("c.bin", bytes: Data(count: 16))

        let entries = await store.entries().map(\.relativePath)
        XCTAssertFalse(entries.contains("b.bin"))
        XCTAssertTrue(entries.contains("c.bin"))
    }

    func testWriteRejectsPathsOutsideTheNamespace() async throws {
        let store = try QuotaFileStore(
            roots: try roots(),
            root: .cache,
            namespace: "responses",
            quota: StorageQuota(maximumBytes: 1_024, maximumEntries: 8)
        )
        do {
            _ = try await store.write("../escape.bin", bytes: Data(count: 1))
            XCTFail("expected traversal to be rejected")
        } catch {
            XCTAssertEqual(error as? StorageError, .invalidPath)
        }
        XCTAssertThrowsError(
            try QuotaFileStore(
                roots: try roots(),
                root: .cache,
                namespace: "a/b",
                quota: StorageQuota(maximumBytes: 1_024, maximumEntries: 8)
            )
        ) { XCTAssertEqual($0 as? StorageError, .invalidNamespace) }
    }

    func testCredentialRecordsAreBoundToTheirSourceAndOrigin() async throws {
        let store = try SourceCredentialStore(roots: try roots(), aead: InMemoryAead())
        let wenku8 = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.wenku8",
            origin: try HttpsOrigin("https://www.wenku8.net")
        )
        let other = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.other",
            origin: try HttpsOrigin("https://www.wenku8.net")
        )
        let otherOrigin = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.wenku8",
            origin: try HttpsOrigin("https://api.wenku8.net")
        )
        try await store.put(wenku8, plaintext: Data("session=opaque".utf8))

        let snapshot = try await store.snapshot(wenku8)
        XCTAssertEqual(snapshot?.plaintext, Data("session=opaque".utf8))
        XCTAssertEqual(snapshot?.cachePartitionId.count, 64)
        let missingSource = try await store.get(other)
        XCTAssertNil(missingSource)
        let missingOrigin = try await store.get(otherOrigin)
        XCTAssertNil(missingOrigin)
    }

    func testCredentialRecordRewriteChangesTheCachePartitionRevision() async throws {
        let store = try SourceCredentialStore(roots: try roots(), aead: InMemoryAead())
        let partition = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.wenku8",
            origin: try HttpsOrigin("https://www.wenku8.net")
        )
        try await store.put(partition, plaintext: Data("one".utf8))
        let first = try await store.snapshot(partition)?.cachePartitionId
        try await store.put(partition, plaintext: Data("one".utf8))
        let second = try await store.snapshot(partition)?.cachePartitionId
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)

        let deleted = try await store.delete(partition)
        XCTAssertTrue(deleted)
        let afterDelete = try await store.get(partition)
        XCTAssertNil(afterDelete)
    }

    func testCorruptCredentialRecordIsInvalidatedInPlace() async throws {
        let roots = try roots()
        let store = try SourceCredentialStore(roots: roots, aead: InMemoryAead())
        let partition = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.wenku8",
            origin: try HttpsOrigin("https://www.wenku8.net")
        )
        try await store.put(partition, plaintext: Data("session".utf8))
        let directory = roots.directory(.credentials).appendingPathComponent("records", isDirectory: true)
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try Data(repeating: 0, count: 8).write(to: file)

        do {
            _ = try await store.snapshot(partition)
            XCTFail("expected a corrupt record to be reported")
        } catch {
            XCTAssertEqual(error as? CredentialStorageError, .corruptOrUnauthenticated)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testVerifiedBrowserSessionRoundTripsThroughTheCredentialPartition() async throws {
        let credentials = try SourceCredentialStore(roots: try roots(), aead: InMemoryAead())
        let sessions = VerifiedBrowserSessionStore(credentials: credentials)
        let partition = try SourceCredentialPartition(
            sourceId: "org.tsuyomi.wenku8",
            origin: try HttpsOrigin("https://www.wenku8.net")
        )
        let session = try VerifiedBrowserSession(requestCookies: "session=opaque", userAgent: "Tsuyomi/1.0")
        try await sessions.put(partition, session: session)

        let snapshot = try await sessions.snapshot(partition)
        XCTAssertEqual(snapshot?.session, session)
        XCTAssertThrowsError(try VerifiedBrowserSession(requestCookies: " ", userAgent: "Tsuyomi/1.0"))
        XCTAssertThrowsError(try VerifiedBrowserSession(requestCookies: "a=b", userAgent: "bad\nagent"))
    }
}
