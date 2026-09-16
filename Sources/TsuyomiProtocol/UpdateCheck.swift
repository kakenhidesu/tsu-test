// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One chapter as the update check reports it: an identity and its current display title. Titles
/// are metadata, not identity, so a corrected title never counts as a change in order.
public struct UpdateCheckChapter: Hashable, Sendable {
    public let chapterId: String
    public let title: String

    public init(chapterId: String, title: String) throws {
        guard Grammar.hasCodePoints(chapterId, in: 1...256) else { throw ProtocolError.invalidUpdateCheck(field: "chapterId") }
        guard Grammar.hasCodePoints(title, in: 1...512) else { throw ProtocolError.invalidUpdateCheck(field: "title") }
        self.chapterId = chapterId
        self.title = title
    }
}

/// `hxp-update-check-v2`: the complete, source-ordered chapter list a signed update check returns.
/// `complete` and `order` are required assertions rather than defaults, so a future adapter cannot
/// imply completeness from a list that merely has entries; a URL, body text or any other field is
/// refused outright.
public struct UpdateCheckResult: Hashable, Sendable {
    public static let maximumChapters = 20_000

    public let sourceId: String
    public let remoteBookId: String
    public let chapters: [UpdateCheckChapter]
    public let lastUpdatedDate: String?

    public init(sourceId: String, remoteBookId: String, chapters: [UpdateCheckChapter], lastUpdatedDate: String?) throws {
        guard Grammar.isStrictSourceId(sourceId), Grammar.hasCodePoints(sourceId, in: 1...128) else {
            throw ProtocolError.invalidUpdateCheck(field: "sourceId")
        }
        guard Grammar.hasCodePoints(remoteBookId, in: 1...256) else {
            throw ProtocolError.invalidUpdateCheck(field: "remoteBookId")
        }
        guard (1...UpdateCheckResult.maximumChapters).contains(chapters.count),
              chapters.map(\.chapterId).hasDistinctElements else {
            throw ProtocolError.invalidUpdateCheck(field: "chapters")
        }
        if let lastUpdatedDate, !Grammar.isCalendarDate(lastUpdatedDate) {
            throw ProtocolError.invalidUpdateCheck(field: "lastUpdatedDate")
        }
        self.sourceId = sourceId
        self.remoteBookId = remoteBookId
        self.chapters = chapters
        self.lastUpdatedDate = lastUpdatedDate
    }

    public static func decode(_ value: JSONValue) throws -> UpdateCheckResult {
        guard let object = value.objectValue,
              object.hasOnly(["sourceId", "remoteBookId", "complete", "order", "chapters", "lastUpdatedDate"]),
              Set(object.keys).count == 6 else {
            throw ProtocolError.invalidUpdateCheck(field: "result")
        }
        guard object.bool("complete") == true else { throw ProtocolError.invalidUpdateCheck(field: "complete") }
        guard object.string("order") == "source" else { throw ProtocolError.invalidUpdateCheck(field: "order") }
        guard let rows = object.array("chapters") else { throw ProtocolError.invalidUpdateCheck(field: "chapters") }
        let chapters = try rows.map { row -> UpdateCheckChapter in
            guard let chapter = row.objectValue, chapter.hasOnly(["chapterId", "title"]),
                  let chapterId = chapter.string("chapterId"), let title = chapter.string("title") else {
                throw ProtocolError.invalidUpdateCheck(field: "chapters")
            }
            return try UpdateCheckChapter(chapterId: chapterId, title: title)
        }
        let lastUpdatedDate: String?
        switch object["lastUpdatedDate"] {
        case .null?: lastUpdatedDate = nil
        case .string(let date)?: lastUpdatedDate = date
        default: throw ProtocolError.invalidUpdateCheck(field: "lastUpdatedDate")
        }
        return try UpdateCheckResult(
            sourceId: object.string("sourceId") ?? "",
            remoteBookId: object.string("remoteBookId") ?? "",
            chapters: chapters,
            lastUpdatedDate: lastUpdatedDate
        )
    }
}
