// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// Turns a parsed update-check result into what the inbox may act on. The anchor binds source,
/// book and the ordered chapter ids — never titles, so a corrected title is not a change — and a
/// later list counts as an update only when it reproduces the earlier one as an exact ordered
/// prefix; anything reordered, shortened or unmatched is reported unavailable, never rebased.
public enum UpdateCheckAdmission {
    static let anchorPrefix = "update-check-v2"

    public static func admit(
        expected identity: BookIdentity,
        previousAnchor: String?,
        parsed: UpdateCheckResult
    ) throws -> UpdateProbeResult {
        guard parsed.sourceId == identity.sourceId, parsed.remoteBookId == identity.remoteBookId else {
            return try refused(identity, .failed, previousAnchor: previousAnchor, reason: "identity-mismatch")
        }
        let ids = parsed.chapters.map(\.chapterId)
        guard (1...UpdateCheckResult.maximumChapters).contains(ids.count) else {
            return try refused(identity, .failed, previousAnchor: previousAnchor, reason: "invalid-chapter-evidence")
        }
        guard ids.hasDistinctElements else {
            return try refused(identity, .failed, previousAnchor: previousAnchor, reason: "duplicate-chapter-id")
        }
        let anchor = anchor(identity, ids)
        guard let previousAnchor else {
            return try UpdateProbeResult(
                identity: identity, outcome: .unchanged, previousAnchor: nil, anchor: anchor,
                chapters: parsed.chapters, newChapterIds: [], lastUpdatedDate: parsed.lastUpdatedDate, reason: nil
            )
        }
        guard let priorCount = chapterCount(in: previousAnchor) else {
            return try refused(identity, .unavailable, previousAnchor: previousAnchor, reason: "prior-anchor-invalid")
        }
        guard priorCount <= ids.count, self.anchor(identity, Array(ids.prefix(priorCount))) == previousAnchor else {
            return try refused(identity, .unavailable, previousAnchor: previousAnchor, reason: "prior-anchor-not-prefix")
        }
        let delta = Array(ids.dropFirst(priorCount))
        return try UpdateProbeResult(
            identity: identity,
            outcome: delta.isEmpty ? .unchanged : .updated,
            previousAnchor: previousAnchor,
            anchor: anchor,
            chapters: parsed.chapters,
            newChapterIds: delta,
            lastUpdatedDate: parsed.lastUpdatedDate,
            reason: nil
        )
    }

    /// A source failure folded into a bounded reason token the interface can label.
    public static func refused(
        _ identity: BookIdentity,
        _ outcome: UpdateProbeOutcome,
        previousAnchor: String?,
        reason: String
    ) throws -> UpdateProbeResult {
        try UpdateProbeResult(
            identity: identity, outcome: outcome, previousAnchor: previousAnchor, anchor: nil,
            chapters: [], newChapterIds: [], lastUpdatedDate: nil, reason: reason
        )
    }

    public static func reason(code: SourceErrorCode, stage: String, safeCode: String) -> String {
        let parts = ["source-" + code.rawValue.lowercased().replacingOccurrences(of: "_", with: "-"), stage, safeCode]
            .map { part -> String in
                let scalars = part.lowercased().unicodeScalars.filter {
                    ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
                }
                let token = String(String.UnicodeScalarView(scalars))
                return token.isEmpty ? "unknown" : String(token.prefix(40))
            }
        return parts.joined(separator: ".")
    }

    /// `update-check-v2.<count>.<sha256>` over length-prefixed fields, so a shorter or reordered
    /// list can never produce the same digest as a prefix of a longer one.
    static func anchor(_ identity: BookIdentity, _ chapterIds: [String]) -> String {
        var text = ""
        func field(_ name: String, _ value: String) {
            text += "\(name):\(value.utf8.count):\(value)\n"
        }
        field("version", anchorPrefix)
        field("source", identity.sourceId)
        field("book", identity.remoteBookId)
        for chapterId in chapterIds { field("chapter-id", chapterId) }
        return "\(anchorPrefix).\(chapterIds.count).\(Sha256.hex(text))"
    }

    static func chapterCount(in anchor: String) -> Int? {
        let parts = anchor.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == anchorPrefix, let count = Int(parts[1]), count > 0,
              parts[2].count == 64 else { return nil }
        return count
    }
}
