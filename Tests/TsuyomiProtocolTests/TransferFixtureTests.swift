// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiProtocol

final class TransferFixtureTests: XCTestCase {
    func testValidMinimalFixtureParsesAndReencodesSemantically() throws {
        let data = try ProtocolFixtures.data("transfer/valid-minimal.json")
        guard case .ready(let plan, let digest) = TransferCodec.parse(data) else {
            return XCTFail("expected a ready import plan")
        }
        XCTAssertEqual(plan.kind, .tsuyomiTransfer)
        XCTAssertEqual(plan.books.count, 1)
        XCTAssertEqual(plan.books[0].identity.sourceId, "org.tsuyomi.wenku8")
        XCTAssertEqual(plan.books[0].progress?.chapterId, "67890")
        XCTAssertEqual(plan.books[0].progress?.characterOffset, 128)
        XCTAssertEqual(digest.count, 64)

        // A v1 document re-exports as the current version: every record it carried is pinned.
        let reencoded = try TransferCodec.encode(
            TransferSnapshot(
                createdAt: plan.sourceCreatedAt,
                library: plan.books,
                shelves: plan.shelves,
                readerPreferences: plan.readerPreferences
            )
        )
        let root = try XCTUnwrap(try JSONValue.decode(reencoded).objectValue)
        XCTAssertEqual(root.int("version"), 3)
        XCTAssertEqual(root.array("library")?.first?.objectValue?.bool("localPin"), true)
        XCTAssertTrue(plan.books.allSatisfy(\.localPin))
    }

    func testV2FixtureCarriesCompletionAndReaderLayout() throws {
        let data = try ProtocolFixtures.data("transfer/valid-v2.json")
        guard case .ready(let plan, _) = TransferCodec.parse(data) else {
            return XCTFail("expected a ready import plan")
        }
        let book = try XCTUnwrap(plan.books.first)
        XCTAssertTrue(book.readLater)
        XCTAssertTrue(book.localPin)
        XCTAssertEqual(book.completedChapterIds, ["67889"])
        let reader = try XCTUnwrap(plan.readerPreferences)
        XCTAssertEqual(reader.horizontalMargin, 32)
        XCTAssertEqual(reader.paragraphSpacing, 16)
        XCTAssertEqual(reader.lockPortrait, true)
        XCTAssertEqual(reader.progressVisible, false)
        XCTAssertEqual(reader.immersive, true)
        XCTAssertEqual(reader.keepAwake, false)
        XCTAssertEqual(reader.volumePaging, false)
    }

    func testV3FixtureRoundTripsAndKeepsTheUnpinnedRecordUnpinned() throws {
        let data = try ProtocolFixtures.data("transfer/valid-v3-retained-unpinned.json")
        guard case .ready(let plan, _) = TransferCodec.parse(data) else {
            return XCTFail("expected a ready import plan")
        }
        let pinned = try XCTUnwrap(plan.books.first { $0.identity.remoteBookId == "pinned-member" })
        let retained = try XCTUnwrap(plan.books.first { $0.identity.remoteBookId == "retained-unpinned" })
        XCTAssertTrue(pinned.localPin)
        XCTAssertEqual(pinned.shelfIds, ["favorites"])
        XCTAssertFalse(retained.localPin)
        XCTAssertTrue(retained.shelfIds.isEmpty)
        XCTAssertEqual(retained.rating, 4)
        XCTAssertTrue(retained.readLater)
        XCTAssertEqual(retained.completedChapterIds, ["chapter-1"])
        let reencoded = try TransferCodec.encode(
            TransferSnapshot(createdAt: plan.sourceCreatedAt, library: plan.books, shelves: plan.shelves)
        )
        XCTAssertEqual(try JSONValue.decode(reencoded), try JSONValue.decode(data))
    }

    func testAnUnpinnedRecordWithAShelfMembershipIsRejected() throws {
        let data = try ProtocolFixtures.data("transfer/invalid-v3-unpinned-shelf-membership.json")
        XCTAssertEqual(TransferCodec.parse(data), .fatal(safeCode: "unpinned-shelf-membership"))
    }

    func testLaterFieldsNeverWidenAnEarlierVersion() throws {
        let v1WithCompletion = """
        {"format":"tsuyomi-transfer","version":1,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "updatedAt":"2026-08-08T00:00:00Z","completedChapterIds":["a"]}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(v1WithCompletion.utf8)), .fatal(safeCode: "invalid-book"))
        let v2WithPin = """
        {"format":"tsuyomi-transfer","version":2,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "updatedAt":"2026-08-08T00:00:00Z","localPin":false}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(v2WithPin.utf8)), .fatal(safeCode: "invalid-book"))
        let v3WithoutPin = """
        {"format":"tsuyomi-transfer","version":3,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "updatedAt":"2026-08-08T00:00:00Z"}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(v3WithoutPin.utf8)), .fatal(safeCode: "invalid-book"))
        let blankCompletion = """
        {"format":"tsuyomi-transfer","version":2,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "updatedAt":"2026-08-08T00:00:00Z","completedChapterIds":[" ", "a", "a"]}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(blankCompletion.utf8)), .fatal(safeCode: "invalid-book"))
    }

    func testNoncanonicalOrderFixtureIsCanonicalisedOnExport() throws {
        let data = try ProtocolFixtures.data("transfer/noncanonical-order.json")
        guard case .ready(let plan, _) = TransferCodec.parse(data) else {
            return XCTFail("expected a ready import plan")
        }
        XCTAssertEqual(plan.books.map(\.identity.sourceId), ["org.tsuyomi.zeta", "org.tsuyomi.alpha"])

        let reencoded = try TransferCodec.encode(
            TransferSnapshot(createdAt: plan.sourceCreatedAt, library: plan.books, shelves: plan.shelves)
        )
        guard let root = try JSONValue.decode(reencoded).objectValue,
              let library = root.array("library") else {
            return XCTFail("expected a library array")
        }
        let orderedSourceIds = library.compactMap { $0.objectValue?.object("identity")?.string("sourceId") }
        XCTAssertEqual(orderedSourceIds, ["org.tsuyomi.alpha", "org.tsuyomi.zeta"])
    }

    func testDuplicateBookIdentityFixtureIsRejected() throws {
        let data = try ProtocolFixtures.data("transfer/duplicate-book-identity.json")
        XCTAssertEqual(TransferCodec.parse(data), .fatal(safeCode: "duplicate-book-identity"))
    }

    func testProgressConflictConformanceCases() throws {
        let data = try ProtocolFixtures.data("transfer/conformance-progress-conflict.json")
        guard let root = try JSONValue.decode(data).objectValue, let cases = root.array("cases") else {
            return XCTFail("expected a conformance case list")
        }
        XCTAssertFalse(cases.isEmpty)
        for element in cases {
            guard let testCase = element.objectValue,
                  let name = testCase.string("name"),
                  let storedJson = testCase.object("stored"),
                  let incomingJson = testCase.object("incoming"),
                  let incomingValid = testCase.bool("incomingValid"),
                  let expectedWinner = testCase.string("expectedWinner") else {
                return XCTFail("malformed conformance case")
            }
            let stored = progress(from: storedJson)
            let incoming = incomingValid ? progress(from: incomingJson) : nil
            let winner = TransferCodec.resolveProgressConflict(stored: stored, incoming: incoming)
            XCTAssertEqual(winner, expectedWinner == "incoming" ? incoming : stored, name)
        }
    }

    func testInvalidIncomingProgressIsRejectedByTheParser() throws {
        let document = """
        {"format":"tsuyomi-transfer","version":1,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "updatedAt":"2026-08-08T00:00:00Z","progress":{"updatedAt":"2026-08-08T12:00:00Z"}}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(document.utf8)), .fatal(safeCode: "invalid-book"))
    }

    func testDanglingShelfReferenceAndCycleAreRejected() throws {
        let dangling = """
        {"format":"tsuyomi-transfer","version":1,"createdAt":"2026-08-08T00:00:00Z","shelves":[],
        "library":[{"identity":{"sourceId":"org.tsuyomi.wenku8","remoteBookId":"1"},"title":"T",
        "shelfIds":["missing"],"updatedAt":"2026-08-08T00:00:00Z"}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(dangling.utf8)), .fatal(safeCode: "dangling-shelf-reference"))

        let cycle = """
        {"format":"tsuyomi-transfer","version":1,"createdAt":"2026-08-08T00:00:00Z","library":[],
        "shelves":[{"id":"a","name":"A","parentId":"b"},{"id":"b","name":"B","parentId":"a"}]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(cycle.utf8)), .fatal(safeCode: "shelf-parent-cycle"))
    }

    func testUnknownRootFieldAndVersionAreRejected() throws {
        let unknownField = """
        {"format":"tsuyomi-transfer","version":1,"createdAt":"2026-08-08T00:00:00Z","library":[],
        "shelves":[],"extra":1}
        """
        XCTAssertEqual(TransferCodec.parse(Data(unknownField.utf8)), .fatal(safeCode: "unknown-root-field"))

        let unsupportedVersion = """
        {"format":"tsuyomi-transfer","version":4,"createdAt":"2026-08-08T00:00:00Z","library":[],"shelves":[]}
        """
        XCTAssertEqual(TransferCodec.parse(Data(unsupportedVersion.utf8)), .fatal(safeCode: "unsupported-version"))

        XCTAssertEqual(TransferCodec.parse(Data("{\"format\":\"other\"}".utf8)), .fatal(safeCode: "unsupported-format"))
        XCTAssertEqual(TransferCodec.parse(Data("not json".utf8)), .fatal(safeCode: "invalid-json"))
    }

    func testImportPlanCodecRoundTrip() throws {
        let identity = try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: "12345")
        let plan = ImportPlan(
            kind: .tsuyomiTransfer,
            sourceCreatedAt: Date(timeIntervalSince1970: 1_775_000_000),
            books: [
                TransferBook(
                    identity: identity,
                    title: "Fixture novel",
                    localTags: ["tag"],
                    updatedAt: Date(timeIntervalSince1970: 1_775_000_000)
                )
            ],
            shelves: [TransferShelf(id: "s1", name: "Shelf")],
            readerPreferences: PortableReaderPreferences(flow: "paged", fontScale: 1.5),
            searchHistory: [
                SourceSearchHistory(
                    sourceId: "org.tsuyomi.wenku8",
                    query: "query",
                    lastUsedAt: Date(timeIntervalSince1970: 1_775_000_001)
                )
            ],
            browsingHistory: [
                SourceBrowsingHistory(identity: identity, lastViewedAt: Date(timeIntervalSince1970: 1_775_000_002))
            ],
            warnings: [ImportWarning(ordinal: 0, safeCode: "example", severity: .conflict)]
        )
        let decoded = try ImportPlanCodec.decode(try ImportPlanCodec.encode(plan))
        XCTAssertEqual(decoded, plan)
    }

    private func progress(from json: [String: JSONValue]) -> TransferProgress? {
        guard let updatedAt = json.instant("updatedAt") else { return nil }
        return TransferProgress(
            chapterId: json.string("chapterId"),
            textAnchor: json.string("textAnchor"),
            characterOffset: json.int("characterOffset"),
            chapterProgress: json.double("chapterProgress"),
            bookProgress: json.double("bookProgress"),
            updatedAt: updatedAt
        )
    }
}
