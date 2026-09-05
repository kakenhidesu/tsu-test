// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiProtocol

final class ProtocolPrimitiveTests: XCTestCase {
    func testSha256MatchesPublishedVectors() {
        XCTAssertEqual(
            Sha256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            Sha256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            Sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            Sha256.hex(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testTimestampParsesRfc3339AndEmitsUtcWithoutFractions() {
        guard let parsed = ProtocolTimestamp.parse("2026-08-08T00:00:00Z") else {
            return XCTFail("expected a parsed instant")
        }
        XCTAssertEqual(ProtocolTimestamp.format(parsed), "2026-08-08T00:00:00Z")
        XCTAssertEqual(
            ProtocolTimestamp.parse("2026-08-08T00:00:00.512Z").map(ProtocolTimestamp.format),
            "2026-08-08T00:00:00Z"
        )
        XCTAssertEqual(
            ProtocolTimestamp.parse("2026-08-08T09:30:00+09:30").map(ProtocolTimestamp.format),
            "2026-08-08T00:00:00Z"
        )
        XCTAssertEqual(
            ProtocolTimestamp.parse("1969-12-31T23:59:59Z").map(ProtocolTimestamp.format),
            "1969-12-31T23:59:59Z"
        )
        XCTAssertEqual(
            ProtocolTimestamp.parse("2024-02-29T12:00:00Z").map(ProtocolTimestamp.format),
            "2024-02-29T12:00:00Z"
        )
        XCTAssertNil(ProtocolTimestamp.parse("2026-02-30T00:00:00Z"))
        XCTAssertNil(ProtocolTimestamp.parse("2026-08-08 00:00:00Z"))
        XCTAssertNil(ProtocolTimestamp.parse("2026-08-08T00:00:00"))
        XCTAssertNil(ProtocolTimestamp.parse("2026-08-08T00:00:00Z "))
    }

    func testSourceIdGrammars() throws {
        XCTAssertNoThrow(try SourceId("org.tsuyomi.wenku8"))
        XCTAssertThrowsError(try SourceId("wenku8")) { XCTAssertEqual($0 as? ProtocolError, .invalidSourceId) }
        XCTAssertThrowsError(try SourceId("Org.Tsuyomi")) { XCTAssertEqual($0 as? ProtocolError, .invalidSourceId) }
        XCTAssertThrowsError(try SourceId("org..tsuyomi")) { XCTAssertEqual($0 as? ProtocolError, .invalidSourceId) }
        XCTAssertThrowsError(try SourceId("org.tsuyomi.")) { XCTAssertEqual($0 as? ProtocolError, .invalidSourceId) }

        XCTAssertNoThrow(try BookIdentity(sourceId: "wenku8", remoteBookId: "1"))
        XCTAssertThrowsError(try BookIdentity(sourceId: "-bad", remoteBookId: "1")) {
            XCTAssertEqual($0 as? ProtocolError, .sourceIdGrammar)
        }
        XCTAssertThrowsError(try BookIdentity(sourceId: "wenku8", remoteBookId: "")) {
            XCTAssertEqual($0 as? ProtocolError, .remoteIdCodePoints(field: "remoteBookId"))
        }
    }

    func testBookIdentityOrdersByUtf16CodeUnits() throws {
        let alpha = try BookIdentity(sourceId: "org.tsuyomi.alpha", remoteBookId: "2")
        let zeta = try BookIdentity(sourceId: "org.tsuyomi.zeta", remoteBookId: "1")
        XCTAssertTrue(alpha < zeta)
        let first = try BookIdentity(sourceId: "org.tsuyomi.alpha", remoteBookId: "10")
        XCTAssertTrue(first < alpha)
    }

    func testHttpsOriginCanonicalisation() throws {
        XCTAssertEqual(try HttpsOrigin("https://WWW.Wenku8.net").canonical, "https://www.wenku8.net")
        XCTAssertEqual(try HttpsOrigin("https://www.wenku8.net:443").canonical, "https://www.wenku8.net")
        XCTAssertEqual(try HttpsOrigin("https://www.wenku8.net:8443").canonical, "https://www.wenku8.net:8443")
        XCTAssertEqual(try HttpsOrigin("https://www.wenku8.net/").canonical, "https://www.wenku8.net")
        XCTAssertThrowsError(try HttpsOrigin("http://www.wenku8.net")) {
            XCTAssertEqual($0 as? ProtocolError, .originNotHttps)
        }
        XCTAssertThrowsError(try HttpsOrigin("https://www.wenku8.net/path")) {
            XCTAssertEqual($0 as? ProtocolError, .originContainsPath)
        }
        XCTAssertThrowsError(try HttpsOrigin("https://user@www.wenku8.net")) {
            XCTAssertEqual($0 as? ProtocolError, .invalidHttpsOrigin)
        }
        XCTAssertThrowsError(try HttpsOrigin("https://www.wenku8.net?a=1")) {
            XCTAssertEqual($0 as? ProtocolError, .invalidHttpsOrigin)
        }
    }

    func testNetworkRequestRules() throws {
        XCTAssertNoThrow(
            try SourceNetworkRequest(
                url: "https://www.wenku8.net/x",
                method: .post,
                form: ["a": "b"],
                cache: .networkOnly
            )
        )
        XCTAssertThrowsError(
            try SourceNetworkRequest(url: "https://www.wenku8.net/x", method: .post, form: ["a": "b"])
        ) { XCTAssertEqual($0 as? ProtocolError, .postMustBypassCache) }
        XCTAssertThrowsError(
            try SourceNetworkRequest(url: "https://www.wenku8.net/x", method: .get, form: ["a": "b"])
        ) { XCTAssertEqual($0 as? ProtocolError, .bodyRequiresPost) }
        XCTAssertThrowsError(
            try SourceNetworkRequest(
                url: "https://www.wenku8.net/x",
                method: .post,
                form: ["a": "b"],
                utf8Body: "c",
                cache: .networkOnly
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .requestBodyConflict) }
        XCTAssertThrowsError(
            try SourceNetworkRequest(url: "https://www.wenku8.net/x", method: .get, semanticCacheKey: "bad key")
        ) { XCTAssertEqual($0 as? ProtocolError, .invalidSemanticCacheKey) }
    }

    func testNetworkResponseRequiresExactlyOneBodyRepresentation() throws {
        XCTAssertThrowsError(
            try SourceNetworkResponse(
                status: 200,
                finalUrl: "https://www.wenku8.net/x",
                headers: [:],
                text: "a",
                bytes: Data(),
                decodeUsed: .utf8,
                cacheState: .fresh,
                diagnosticId: "diag_1234"
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .responseBodyRepresentation) }
        XCTAssertThrowsError(
            try SourceNetworkResponse(
                status: 200,
                finalUrl: "https://www.wenku8.net/x",
                headers: [:],
                text: "a",
                bytes: nil,
                decodeUsed: .utf8,
                cacheState: .fresh,
                diagnosticId: "short"
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .invalidDiagnosticId) }
    }

    func testSourceHomePageBounds() throws {
        let filter = try SourceHomeFilter(
            id: "sort",
            label: "排序",
            options: [try SourceHomeFilterOption(value: "hot", label: "热门")]
        )
        let section = try SourceHomeSection(
            id: "s1",
            title: "推荐",
            items: [
                try SourceBookSummary(
                    identity: try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: "1"),
                    title: "书",
                    author: nil,
                    coverUrl: nil,
                    canonicalUrl: "https://www.wenku8.net/b/1"
                )
            ]
        )
        XCTAssertNoThrow(
            try SourceHomePage(
                title: "首页",
                schemaVersion: 1,
                filters: [filter],
                selectedFilters: ["sort": "hot"],
                sections: [section],
                nextCursor: nil,
                complete: true
            )
        )
        XCTAssertThrowsError(
            try SourceHomePage(
                title: "首页",
                schemaVersion: 1,
                filters: [filter],
                selectedFilters: ["sort": "cold"],
                sections: [section],
                nextCursor: nil,
                complete: true
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .invalidSelectedHomeFilterOption) }
        XCTAssertThrowsError(
            try SourceHomePage(
                title: "首页",
                schemaVersion: 1,
                filters: [filter],
                selectedFilters: [:],
                sections: [section],
                nextCursor: nil,
                complete: false
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .incompleteSourceHomePageRequiresCursor) }
        XCTAssertThrowsError(
            try SourceHomePage(
                title: "首页",
                schemaVersion: 2,
                filters: [],
                selectedFilters: [:],
                sections: [section],
                nextCursor: nil,
                complete: true
            )
        ) { XCTAssertEqual($0 as? ProtocolError, .unsupportedSourceHomeSchemaVersion) }
    }

    func testDirectoryRejectsDuplicateChapters() throws {
        let identity = try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: "1")
        let chapter = try SourceChapter(chapterId: "c1", title: "一", url: "https://www.wenku8.net/c/1")
        XCTAssertThrowsError(try SourceDirectory(bookIdentity: identity, chapters: [chapter, chapter])) {
            XCTAssertEqual($0 as? ProtocolError, .duplicateChapterIdentity)
        }
        XCTAssertThrowsError(try SourceDirectory(bookIdentity: identity, chapters: [])) {
            XCTAssertEqual($0 as? ProtocolError, .emptyDirectory)
        }
    }
}
