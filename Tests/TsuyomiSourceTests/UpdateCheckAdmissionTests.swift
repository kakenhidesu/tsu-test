// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// The admission rules a check has to pass before the inbox sees it: a silent first baseline, an
/// update only for an exact ordered prefix, and refusal for anything the anchor cannot vouch for.
final class UpdateCheckAdmissionTests: XCTestCase {
    private var identity: BookIdentity {
        get throws { try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: "1234") }
    }

    private func parsed(_ ids: [String], date: String? = "2026-09-07") throws -> UpdateCheckResult {
        try UpdateCheckResult(
            sourceId: try identity.sourceId,
            remoteBookId: try identity.remoteBookId,
            chapters: try ids.map { try UpdateCheckChapter(chapterId: $0, title: "第\($0)章") },
            lastUpdatedDate: date
        )
    }

    func testTheFirstAcceptedCheckIsASilentBaseline() throws {
        let result = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: nil, parsed: try parsed(["a", "b"]))
        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertTrue(result.newChapterIds.isEmpty)
        XCTAssertEqual(result.anchor?.hasPrefix("update-check-v2.2."), true)
        XCTAssertEqual(result.lastUpdatedDate, "2026-09-07")
    }

    func testAnAppendedChapterIsAnUpdateAndATitleCorrectionIsNot() throws {
        let baseline = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: nil, parsed: try parsed(["a", "b"]))
        let anchor = try XCTUnwrap(baseline.anchor)
        let retitled = try UpdateCheckResult(
            sourceId: try identity.sourceId,
            remoteBookId: try identity.remoteBookId,
            chapters: [try UpdateCheckChapter(chapterId: "a", title: "改题"), try UpdateCheckChapter(chapterId: "b", title: "乙")],
            lastUpdatedDate: nil
        )
        let unchanged = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: anchor, parsed: retitled)
        XCTAssertEqual(unchanged.outcome, .unchanged)
        XCTAssertEqual(unchanged.anchor, anchor)

        let appended = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: anchor, parsed: try parsed(["a", "b", "c", "d"]))
        XCTAssertEqual(appended.outcome, .updated)
        XCTAssertEqual(appended.newChapterIds, ["c", "d"])
        XCTAssertEqual(appended.previousAnchor, anchor)
    }

    func testReorderedShortenedOrForeignEvidenceIsUnavailableNeverRebased() throws {
        let anchor = try XCTUnwrap(
            try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: nil, parsed: try parsed(["a", "b", "c"])).anchor
        )
        for ids in [["b", "a", "c", "d"], ["a", "b"], ["x", "y", "z", "w"]] {
            let result = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: anchor, parsed: try parsed(ids))
            XCTAssertEqual(result.outcome, .unavailable, "\(ids)")
            XCTAssertEqual(result.reason, "prior-anchor-not-prefix")
            XCTAssertNil(result.anchor)
        }
        let corrupt = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: "garbage", parsed: try parsed(["a"]))
        XCTAssertEqual(corrupt.reason, "prior-anchor-invalid")
    }

    func testTheWrongBookIsAFailure() throws {
        let other = try UpdateCheckResult(
            sourceId: try identity.sourceId,
            remoteBookId: "9999",
            chapters: [try UpdateCheckChapter(chapterId: "a", title: "A")],
            lastUpdatedDate: nil
        )
        let result = try UpdateCheckAdmission.admit(expected: try identity, previousAnchor: nil, parsed: other)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.reason, "identity-mismatch")
    }

    func testReasonsAreBoundedTokens() {
        let reason = UpdateCheckAdmission.reason(code: .sessionRequired, stage: "update-check-classify", safeCode: "Session Required!")
        XCTAssertEqual(reason, "source-session-required.update-check-classify.sessionrequired")
        XCTAssertTrue(UpdateProbeResult.isReason(reason))
    }
}
