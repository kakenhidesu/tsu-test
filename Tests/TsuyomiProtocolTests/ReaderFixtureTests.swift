// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiProtocol

final class ReaderFixtureTests: XCTestCase {
    func testReaderLocatorFixtureRoundTripsSemantically() throws {
        let data = try ProtocolFixtures.data("reader/valid-reader-locator.json")
        let locator = try JSONDecoder().decode(ReaderLocator.self, from: data)
        XCTAssertEqual(locator.document.sourceId, "org.tsuyomi.yamibo")
        XCTAssertEqual(locator.document.contentId, "thread-42-page-3")
        XCTAssertEqual(locator.document.revision, "2026-08-08T00:00:00Z")
        XCTAssertEqual(locator.blockId, "post-9001")
        XCTAssertEqual(locator.characterOffset, 0)
        XCTAssertEqual(locator.precision, .exact)
        try assertSemanticRoundTrip(locator, original: data)
    }

    func testForumNavigationFixtureRoundTripsSemantically() throws {
        let data = try ProtocolFixtures.data("reader/valid-forum-navigation.json")
        let navigation = try JSONDecoder().decode(ForumThreadNavigation.self, from: data)
        XCTAssertEqual(navigation.identity.threadId, "42")
        XCTAssertEqual(navigation.catalogueEntries.count, 3)
        XCTAssertEqual(navigation.catalogueEntries[0].selectionRole, .alias)
        XCTAssertEqual(navigation.catalogueEntries[0].postId, "9001")
        XCTAssertEqual(navigation.ownerCatalogue?.entries.count, 2)
        try assertSemanticRoundTrip(navigation, original: data)
    }

    func testThreadPageDocumentFixtureRoundTripsSemantically() throws {
        let data = try ProtocolFixtures.data("reader/valid-thread-page-document.json")
        let document = try JSONDecoder().decode(ReaderDocument.self, from: data)
        XCTAssertEqual(document.kind, .threadPage)
        XCTAssertEqual(document.blocks.count, 1)
        guard case .post(let post) = document.blocks[0] else { return XCTFail("expected a post block") }
        XCTAssertEqual(post.postId, "9001")
        XCTAssertEqual(post.floor, 21)
        XCTAssertEqual(post.blocks.count, 1)
        try assertSemanticRoundTrip(document, original: data)
    }

    func testLocatorRequiresAnchorOrProgressFallback() throws {
        let document = try DocumentIdentity(
            sourceId: "org.tsuyomi.wenku8",
            remoteBookId: "1",
            contentId: "c1"
        )
        XCTAssertThrowsError(
            try ReaderLocator(document: document, capturedAt: Date(timeIntervalSince1970: 0))
        ) { error in
            XCTAssertEqual(error as? ProtocolError, .locatorAnchorMissing)
        }
        XCTAssertThrowsError(
            try ReaderLocator(document: document, characterOffset: 4, capturedAt: Date(timeIntervalSince1970: 0))
        ) { error in
            XCTAssertEqual(error as? ProtocolError, .characterOffsetRequiresBlockId)
        }
        XCTAssertThrowsError(
            try ReaderLocator(
                document: document,
                blockId: "b1",
                textAnchorDigest: "NOTADIGEST",
                capturedAt: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolError, .textAnchorDigest)
        }
    }

    func testPostBlockRejectsNestedPost() throws {
        let inner = try ReaderBlock.Post(
            blockId: "inner",
            postId: "1",
            authorId: "1",
            authorName: "author",
            floor: nil,
            createdAt: nil,
            replyToPostId: nil,
            blocks: [.paragraph(try ReaderBlock.Paragraph(blockId: "p", text: "text"))]
        )
        XCTAssertThrowsError(
            try ReaderBlock.Post(
                blockId: "outer",
                postId: "2",
                authorId: "1",
                authorName: "author",
                floor: nil,
                createdAt: nil,
                replyToPostId: nil,
                blocks: [.post(inner)]
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolError, .invalidPostBlocks)
        }
    }

    func testDocumentRejectsDuplicateBlockIdentity() throws {
        let identity = try DocumentIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: "1", contentId: "c1")
        let first = ReaderBlock.paragraph(try ReaderBlock.Paragraph(blockId: "b1", text: "one"))
        let second = ReaderBlock.paragraph(try ReaderBlock.Paragraph(blockId: "b1", text: "two"))
        XCTAssertThrowsError(
            try ReaderDocument(
                kind: .chapter,
                identity: identity,
                title: "title",
                revision: "r1",
                contentDigest: String(repeating: "0", count: 64),
                blocks: [first, second]
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolError, .duplicateBlockIdentity)
        }
    }

    private func assertSemanticRoundTrip(
        _ value: some Encodable,
        original: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let reencoded = try encoder.encode(value)
        XCTAssertEqual(
            try JSONValue.decode(reencoded),
            try JSONValue.decode(original),
            file: file,
            line: line
        )
    }
}
