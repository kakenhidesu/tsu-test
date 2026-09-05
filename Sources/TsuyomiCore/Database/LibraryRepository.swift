// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The only public persistence boundary for `books`, `library_entries`, `local_book_tags`, and the
/// browsing and search history. Every statement is parameterised; no caller
/// value is ever concatenated into SQL.
public struct LibraryRepository: Sendable {
    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    public func saveBook(_ book: LibraryBook) async throws {
        try await database.withTransaction { try LibraryCatalog.saveBook(book, $0) }
    }

    public func book(_ identity: BookIdentity) async throws -> LibraryBook? {
        try await database.read { try LibraryCatalog.book(identity, $0) }
    }

    public func libraryEntries() async throws -> [LibraryEntry] {
        try await database.read { connection in
            let rows = try connection.query(
                """
                SELECT library_entries.source_id, library_entries.remote_book_id
                FROM library_entries
                INNER JOIN books USING(source_id, remote_book_id)
                ORDER BY library_entries.display_order, library_entries.added_at_epoch_second DESC,
                books.title COLLATE NOCASE, books.source_id, books.remote_book_id
                """
            )
            return try LibraryCatalog.entries(rows.compactMap(LibraryCatalog.identity), connection)
        }
    }

    public func libraryEntry(_ identity: BookIdentity) async throws -> LibraryEntry? {
        try await database.read { try LibraryCatalog.entries([identity], $0).first }
    }

    @discardableResult
    public func addToLibrary(_ book: LibraryBook) async throws -> Bool {
        try await database.withTransaction { connection in
            try LibraryCatalog.saveBook(book, connection)
            try connection.execute(
                """
                INSERT OR IGNORE INTO library_entries
                (source_id, remote_book_id, added_at_epoch_second, added_at_nano, rating, read_later, display_order)
                VALUES (?, ?, ?, ?, NULL, 0, 2147483647)
                """,
                [
                    .text(book.identity.sourceId), .text(book.identity.remoteBookId),
                    .integer(book.addedAt.epochSecond), .integer(Int64(book.addedAt.nanoOfSecond))
                ]
            )
            return connection.changes != 0
        }
    }

    @discardableResult
    public func removeFromLibrary(_ identity: BookIdentity) async throws -> Bool {
        try await removeFromLibrary([identity]) != 0
    }

    @discardableResult
    public func removeFromLibrary(_ identities: Set<BookIdentity>) async throws -> Int {
        try await database.withTransaction { connection in
            var removed = 0
            for identity in identities.sorted() {
                try connection.execute(
                    "DELETE FROM library_entries WHERE source_id = ? AND remote_book_id = ?",
                    [.text(identity.sourceId), .text(identity.remoteBookId)]
                )
                if connection.changes != 0 { removed += 1 }
            }
            return removed
        }
    }

    /// The presented order is durable: the whole current membership must be supplied exactly once,
    /// so a stale screen can never silently drop or duplicate an entry.
    public func reorderLibrary(_ identities: [BookIdentity]) async throws {
        try await database.withTransaction { connection in
            let current = try connection.query("SELECT source_id, remote_book_id FROM library_entries")
                .compactMap(LibraryCatalog.identity)
            guard identities.count == current.count, Set(identities) == Set(current) else {
                throw DatabaseError.invariantViolated("Library reorder must contain every current entry exactly once")
            }
            for (index, identity) in identities.enumerated() {
                try connection.execute(
                    "UPDATE library_entries SET display_order = ? WHERE source_id = ? AND remote_book_id = ?",
                    [.integer(Int64(index)), .text(identity.sourceId), .text(identity.remoteBookId)]
                )
                guard connection.changes == 1 else {
                    throw DatabaseError.invariantViolated("Library reorder target is missing")
                }
            }
        }
    }

    public func setRating(_ identity: BookIdentity, rating: Int?) async throws {
        if let rating, !(1...5).contains(rating) {
            throw DatabaseError.invariantViolated("Rating must be 1..5")
        }
        try await database.withTransaction { connection in
            try connection.execute(
                "UPDATE library_entries SET rating = ? WHERE source_id = ? AND remote_book_id = ?",
                [rating.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                 .text(identity.sourceId), .text(identity.remoteBookId)]
            )
            guard connection.changes == 1 else { throw DatabaseError.invariantViolated("Book is not in library") }
        }
    }

    public func setReadLater(_ identity: BookIdentity, readLater: Bool) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                "UPDATE library_entries SET read_later = ? WHERE source_id = ? AND remote_book_id = ?",
                [.integer(readLater ? 1 : 0), .text(identity.sourceId), .text(identity.remoteBookId)]
            )
            guard connection.changes == 1 else { throw DatabaseError.invariantViolated("Book is not in library") }
        }
    }

    public func setLocalTags(_ identity: BookIdentity, tags: [String]) async throws {
        try await database.withTransaction { connection in
            let present = try connection.query(
                "SELECT 1 FROM library_entries WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
            guard !present.isEmpty else { throw DatabaseError.invariantViolated("Book is not in library") }
            var normalized: [(key: String, display: String)] = []
            var seen = Set<String>()
            for raw in tags {
                let display = LibraryCatalog.collapseWhitespace(raw)
                guard !display.isEmpty else { continue }
                let key = display.precomposedStringWithCompatibilityMapping.lowercased()
                guard seen.insert(key).inserted else { continue }
                normalized.append((key, display))
            }
            guard normalized.count <= 64 else { throw DatabaseError.invariantViolated("Too many local tags") }
            try connection.execute(
                "DELETE FROM local_book_tags WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
            for tag in normalized {
                try connection.execute(
                    """
                    INSERT INTO local_book_tags (source_id, remote_book_id, normalized_tag, display_tag)
                    VALUES (?, ?, ?, ?)
                    """,
                    [.text(identity.sourceId), .text(identity.remoteBookId), .text(tag.key), .text(tag.display)]
                )
            }
        }
    }
}

enum LibraryCatalog {
    static func saveBook(_ book: LibraryBook, _ connection: SQLiteConnection) throws {
        let authors = canonicalStringSet(book.authors)
        let bindings: [SQLiteValue] = [
            .text(book.identity.sourceId), .text(book.identity.remoteBookId), .text(book.title),
            .text(encodeStringList(authors)),
            authorSortKey(authors).map { SQLiteValue.blob($0) } ?? .null,
            book.coverUrl.map { SQLiteValue.text($0) } ?? .null,
            book.canonicalUrl.map { SQLiteValue.text($0) } ?? .null,
            book.status.map { SQLiteValue.text($0) } ?? .null,
            .text(encodeStringList(canonicalStringSet(book.remoteTags))),
            book.sourceUpdateKey.map { SQLiteValue.text($0) } ?? .null,
            .integer(book.hasUnreadUpdate ? 1 : 0),
            .integer(book.addedAt.epochSecond), .integer(Int64(book.addedAt.nanoOfSecond)),
            .integer(book.metadataUpdatedAt.epochSecond), .integer(Int64(book.metadataUpdatedAt.nanoOfSecond))
        ]
        try connection.execute(
            """
            INSERT INTO books (source_id, remote_book_id, title, authors_json, author_sort_key, cover_url,
            canonical_url, status, remote_tags_json, source_update_key, has_unread_update,
            added_at_epoch_second, added_at_nano, metadata_updated_at_epoch_second, metadata_updated_at_nano)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, remote_book_id) DO UPDATE SET
            title = excluded.title, authors_json = excluded.authors_json,
            author_sort_key = excluded.author_sort_key, cover_url = excluded.cover_url,
            canonical_url = excluded.canonical_url, status = excluded.status,
            remote_tags_json = excluded.remote_tags_json, source_update_key = excluded.source_update_key,
            has_unread_update = excluded.has_unread_update,
            metadata_updated_at_epoch_second = excluded.metadata_updated_at_epoch_second,
            metadata_updated_at_nano = excluded.metadata_updated_at_nano
            """,
            bindings
        )
    }

    static func book(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> LibraryBook? {
        let rows = try connection.query(
            "SELECT * FROM books WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        )
        return try rows.first.flatMap(book(from:))
    }

    static func book(from row: SQLiteRow) throws -> LibraryBook? {
        guard let sourceId = row["source_id"].string, let remoteBookId = row["remote_book_id"].string,
              let title = row["title"].string,
              let addedAt = row.instant("added_at_epoch_second", "added_at_nano"),
              let metadataUpdatedAt = row.instant("metadata_updated_at_epoch_second", "metadata_updated_at_nano")
        else { return nil }
        return LibraryBook(
            identity: try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
            title: title,
            addedAt: addedAt,
            metadataUpdatedAt: metadataUpdatedAt,
            authors: Set(decodeStringList(row["authors_json"].string ?? "[]")),
            coverUrl: row["cover_url"].string,
            canonicalUrl: row["canonical_url"].string,
            status: row["status"].string,
            remoteTags: Set(decodeStringList(row["remote_tags_json"].string ?? "[]")),
            sourceUpdateKey: row["source_update_key"].string,
            hasUnreadUpdate: row["has_unread_update"].bool ?? false
        )
    }

    static func identity(from row: SQLiteRow) -> BookIdentity? {
        guard let sourceId = row["source_id"].string, let remoteBookId = row["remote_book_id"].string else {
            return nil
        }
        return try? BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId)
    }

    static func entries(_ identities: [BookIdentity], _ connection: SQLiteConnection) throws -> [LibraryEntry] {
        var result: [LibraryEntry] = []
        for identity in identities {
            guard let book = try book(identity, connection) else { continue }
            let entryRows = try connection.query(
                "SELECT * FROM library_entries WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
            guard let entry = entryRows.first,
                  let libraryAddedAt = entry.instant("added_at_epoch_second", "added_at_nano") else { continue }
            let available = try connection.query(
                "SELECT available FROM source_availability WHERE source_id = ?",
                [.text(identity.sourceId)]
            ).first?["available"].bool ?? false
            let tags = try connection.query(
                "SELECT display_tag FROM local_book_tags WHERE source_id = ? AND remote_book_id = ? ORDER BY normalized_tag",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            ).compactMap { $0["display_tag"].string }
            let reconciliation = try connection.query(
                """
                SELECT state FROM remote_library_reconciliation WHERE source_id = ? AND remote_book_id = ?
                ORDER BY rowid DESC LIMIT 1
                """,
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            ).first?["state"].string.flatMap(RemoteReconciliationState.init(rawValue:))
            result.append(
                try LibraryEntry(
                    book: book,
                    libraryAddedAt: libraryAddedAt,
                    rating: entry["rating"].int.map(Int.init),
                    localTags: tags,
                    readLater: entry["read_later"].bool ?? false,
                    sourceAvailable: available,
                    reconciliation: reconciliation,
                    progress: try ReadingProgressStore.progress(identity, connection)
                )
            )
        }
        return result
    }

    static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func canonicalStringSet(_ values: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        let normalized = values
            .map { collapseWhitespace($0.precomposedStringWithCompatibilityMapping) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return normalized.sorted { lhs, rhs in
            var left = lhs.unicodeScalars.makeIterator()
            var right = rhs.unicodeScalars.makeIterator()
            while true {
                switch (left.next(), right.next()) {
                case (nil, nil): return false
                case (nil, _): return true
                case (_, nil): return false
                case let (leftScalar?, rightScalar?):
                    if leftScalar != rightScalar { return leftScalar.value < rightScalar.value }
                }
            }
        }
    }

    static func encodeStringList(_ values: [String]) -> String {
        guard let data = try? JSONValue.array(values.map { .string($0) }).encoded(),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeStringList(_ value: String) -> [String] {
        guard let parsed = try? JSONValue.decode(Data(value.utf8)), let array = parsed.arrayValue else { return [] }
        return array.compactMap(\.stringValue)
    }

    /// A NUL-terminated, NUL-escaped concatenation so that SQLite orders authors by the same rule on
    /// both hosts without depending on a collation.
    static func authorSortKey(_ authors: [String]) -> Data? {
        guard !authors.isEmpty else { return nil }
        var bytes = Data()
        for author in authors {
            for byte in Array(author.lowercased().utf8) {
                if byte == 0 {
                    bytes.append(0)
                    bytes.append(0xFF)
                } else {
                    bytes.append(byte)
                }
            }
            bytes.append(0)
            bytes.append(0)
        }
        return bytes
    }
}

public extension LibraryRepository {
    /// `search_history` and `browsing_history`. Both are local-only records of what the user did on
    /// this device; neither is ever sent to a source.
    func recordSearch(sourceId: String, query: String, at moment: Date) async throws {
        let display = LibraryCatalog.collapseWhitespace(query)
        guard !display.isEmpty, display.utf16.count <= 256 else {
            throw DatabaseError.invariantViolated("Invalid search query")
        }
        let normalized = display.precomposedStringWithCompatibilityMapping.lowercased()
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO search_history (source_id, normalized_query, display_query,
                last_used_at_epoch_second, last_used_at_nano)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(sourceId), .text(normalized), .text(display),
                    .integer(moment.epochSecond), .integer(Int64(moment.nanoOfSecond))
                ]
            )
        }
    }

    func searchHistory(sourceId: String, limit: Int = 20) async throws -> [String] {
        try await database.read { connection in
            try connection.query(
                """
                SELECT display_query FROM search_history WHERE source_id = ?
                ORDER BY last_used_at_epoch_second DESC, last_used_at_nano DESC LIMIT ?
                """,
                [.text(sourceId), .integer(Int64(limit))]
            ).compactMap { $0["display_query"].string }
        }
    }

    func clearSearchHistory(sourceId: String) async throws {
        try await database.withTransaction { connection in
            try connection.execute("DELETE FROM search_history WHERE source_id = ?", [.text(sourceId)])
        }
    }

    func recordBrowsingVisit(_ identity: BookIdentity, at moment: Date) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO browsing_history (source_id, remote_book_id,
                last_viewed_at_epoch_second, last_viewed_at_nano)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(identity.sourceId), .text(identity.remoteBookId),
                    .integer(moment.epochSecond), .integer(Int64(moment.nanoOfSecond))
                ]
            )
        }
    }

    func browsingHistory(limit: Int = 100) async throws -> [BookIdentity] {
        try await database.read { connection in
            try connection.query(
                """
                SELECT source_id, remote_book_id FROM browsing_history
                ORDER BY last_viewed_at_epoch_second DESC, last_viewed_at_nano DESC LIMIT ?
                """,
                [.integer(Int64(limit))]
            ).compactMap(LibraryCatalog.identity)
        }
    }
}
