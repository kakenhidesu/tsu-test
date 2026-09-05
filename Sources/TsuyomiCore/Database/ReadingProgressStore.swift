// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// `reading_progress`. A capture is applied only when it is strictly newer; a timestamp tie keeps the
/// existing valid record, and neither percentage nor offset breaks the tie, because a reader may
/// deliberately move backwards (transfer-v1 §Progress conflicts).
public struct ReadingProgressStore: Sendable {
    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    @discardableResult
    public func saveProgress(_ incoming: ReadingProgress) async throws -> ProgressWriteResult {
        try await database.withTransaction { connection in
            let existing = try ReadingProgressStore.rawProgress(incoming.identity, connection)
            if existing == nil {
                try ReadingProgressStore.insert(incoming, connection)
                return connection.changes != 0 ? .applied : .keptExisting
            }
            if try ReadingProgressStore.progress(incoming.identity, connection) == nil {
                try ReadingProgressStore.upsert(incoming, connection)
                return .applied
            }
            try ReadingProgressStore.updateIfNewer(incoming, connection)
            return connection.changes == 1 ? .applied : .keptExisting
        }
    }

    public func progress(_ identity: BookIdentity) async throws -> ReadingProgress? {
        try await database.read { try ReadingProgressStore.progress(identity, $0) }
    }

    @discardableResult
    public func deleteProgress(_ identity: BookIdentity) async throws -> Bool {
        try await database.withTransaction { connection in
            try connection.execute(
                "DELETE FROM reading_progress WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
            return connection.changes != 0
        }
    }

    static func progress(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> ReadingProgress? {
        guard let row = try rawProgress(identity, connection) else { return nil }
        guard let contentId = row["content_id"].string,
              let timestamp = row.instant("updated_at_epoch_second", "updated_at_nano") else { return nil }
        guard let document = try? DocumentIdentity(
            sourceId: identity.sourceId,
            remoteBookId: identity.remoteBookId,
            contentId: contentId,
            revision: row["revision"].string
        ) else { return nil }
        guard let locator = try? ReaderLocator(
            document: document,
            blockId: row["block_id"].string,
            textAnchorDigest: row["text_anchor_digest"].string,
            characterOffset: row["character_offset"].int.map(Int.init),
            chapterProgress: row["chapter_progress"].double,
            bookProgress: row["book_progress"].double,
            capturedAt: timestamp
        ) else { return nil }
        return try? ReadingProgress(identity: identity, locator: locator, updatedAt: timestamp)
    }

    private static func rawProgress(
        _ identity: BookIdentity,
        _ connection: SQLiteConnection
    ) throws -> SQLiteRow? {
        try connection.query(
            "SELECT * FROM reading_progress WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).first
    }

    private static func columns(_ progress: ReadingProgress) -> [SQLiteValue] {
        let locator = progress.locator
        return [
            .text(progress.identity.sourceId), .text(progress.identity.remoteBookId),
            .text(locator.document.contentId),
            locator.document.revision.map { SQLiteValue.text($0) } ?? .null,
            locator.blockId.map { SQLiteValue.text($0) } ?? .null,
            locator.textAnchorDigest.map { SQLiteValue.text($0) } ?? .null,
            locator.characterOffset.map { SQLiteValue.integer(Int64($0)) } ?? .null,
            locator.chapterProgress.map { SQLiteValue.real($0) } ?? .null,
            locator.bookProgress.map { SQLiteValue.real($0) } ?? .null,
            .integer(progress.updatedAt.epochSecond), .integer(Int64(progress.updatedAt.nanoOfSecond))
        ]
    }

    private static let insertColumns = """
        (source_id, remote_book_id, content_id, revision, block_id, text_anchor_digest, character_offset,
        chapter_progress, book_progress, updated_at_epoch_second, updated_at_nano)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static func insert(_ progress: ReadingProgress, _ connection: SQLiteConnection) throws {
        try connection.execute("INSERT OR IGNORE INTO reading_progress \(insertColumns)", columns(progress))
    }

    static func upsert(_ progress: ReadingProgress, _ connection: SQLiteConnection) throws {
        try connection.execute("INSERT OR REPLACE INTO reading_progress \(insertColumns)", columns(progress))
    }

    private static func updateIfNewer(_ progress: ReadingProgress, _ connection: SQLiteConnection) throws {
        let locator = progress.locator
        try connection.execute(
            """
            UPDATE reading_progress SET content_id = ?, revision = ?, block_id = ?, text_anchor_digest = ?,
            character_offset = ?, chapter_progress = ?, book_progress = ?, updated_at_epoch_second = ?,
            updated_at_nano = ?
            WHERE source_id = ? AND remote_book_id = ?
            AND (updated_at_epoch_second < ? OR (updated_at_epoch_second = ? AND updated_at_nano < ?))
            """,
            [
                .text(locator.document.contentId),
                locator.document.revision.map { SQLiteValue.text($0) } ?? .null,
                locator.blockId.map { SQLiteValue.text($0) } ?? .null,
                locator.textAnchorDigest.map { SQLiteValue.text($0) } ?? .null,
                locator.characterOffset.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                locator.chapterProgress.map { SQLiteValue.real($0) } ?? .null,
                locator.bookProgress.map { SQLiteValue.real($0) } ?? .null,
                .integer(progress.updatedAt.epochSecond), .integer(Int64(progress.updatedAt.nanoOfSecond)),
                .text(progress.identity.sourceId), .text(progress.identity.remoteBookId),
                .integer(progress.updatedAt.epochSecond), .integer(progress.updatedAt.epochSecond),
                .integer(Int64(progress.updatedAt.nanoOfSecond))
            ]
        )
    }
}
