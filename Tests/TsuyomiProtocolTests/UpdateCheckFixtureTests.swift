// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiProtocol

/// The protocol's `hxp-update-check-v2` vectors: the valid result decodes as published, and each
/// invalid vector is refused for the reason it was written.
final class UpdateCheckFixtureTests: XCTestCase {
    func testTheValidVectorDecodes() throws {
        let value = try JSONValue.decode(try ProtocolFixtures.data("hxp/valid-update-check-v2.json"))
        let result = try UpdateCheckResult.decode(value)
        XCTAssertEqual(result.sourceId, "org.tsuyomi.wenku8")
        XCTAssertEqual(result.remoteBookId, "1234")
        XCTAssertEqual(result.chapters.map(\.chapterId), ["10001", "10002", "10003"])
        XCTAssertEqual(result.lastUpdatedDate, "2026-09-07")
    }

    func testEveryInvalidVectorIsRefused() throws {
        for name in ["duplicate", "incomplete", "missing-order", "raw-url"] {
            let value = try JSONValue.decode(try ProtocolFixtures.data("hxp/invalid-update-check-v2-\(name).json"))
            XCTAssertThrowsError(try UpdateCheckResult.decode(value), name)
        }
    }

    func testAnEmptyListOrAnInvalidDateIsRefused() throws {
        XCTAssertThrowsError(
            try UpdateCheckResult(sourceId: "org.tsuyomi.wenku8", remoteBookId: "1", chapters: [], lastUpdatedDate: nil)
        )
        XCTAssertThrowsError(
            try UpdateCheckResult(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1",
                chapters: [try UpdateCheckChapter(chapterId: "a", title: "A")],
                lastUpdatedDate: "2026-02-30"
            )
        )
    }
}
