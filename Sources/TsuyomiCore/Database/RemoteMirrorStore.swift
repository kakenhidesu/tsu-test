// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// `remote_mirror_bindings`, `remote_mirror_targets` and `remote_mirror_items`: the durable website
/// library. A snapshot replaces the items and refreshes the binding in one transaction, freezes
/// every target first so the ones the site no longer lists survive frozen, and never creates a
/// library entry or a manual membership — a mirror-only book has a `books` row and nothing else.
public struct RemoteMirrorStore: Sendable {
    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    public func save(_ snapshot: RemoteMirrorSnapshot) async throws {
        guard isNonBlank(snapshot.sourceId), isNonBlank(snapshot.displayName) else {
            throw DatabaseError.invariantViolated("Remote mirror source is required")
        }
        guard Set(snapshot.books.map(\.identity)).count == snapshot.books.count else {
            throw DatabaseError.invariantViolated("Duplicate remote mirror identity")
        }
        guard snapshot.books.allSatisfy({ $0.identity.sourceId == snapshot.sourceId }),
              snapshot.targets.allSatisfy({ $0.sourceId == snapshot.sourceId }) else {
            throw DatabaseError.invariantViolated("Remote mirror source mismatch")
        }
        try await database.withTransaction { connection in
            guard try RemoteLibraryStore.leaseValid(
                sourceId: snapshot.sourceId,
                version: snapshot.expectedVersion,
                capabilityFingerprint: snapshot.expectedCapabilityFingerprint,
                generation: snapshot.expectedGeneration,
                connection
            ) else {
                throw DatabaseError.invariantViolated("Source changed before remote mirror snapshot")
            }
            let observed = snapshot.observedAt.epochSecond
            try connection.execute(
                """
                INSERT OR REPLACE INTO remote_mirror_bindings (source_id, display_name, frozen, updated_at_epoch_second)
                VALUES (?, ?, 0, ?)
                """,
                [.text(snapshot.sourceId), .text(snapshot.displayName), .integer(observed)]
            )
            try connection.execute(
                "UPDATE remote_mirror_targets SET frozen = 1 WHERE source_id = ?",
                [.text(snapshot.sourceId)]
            )
            for target in snapshot.targets {
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO remote_mirror_targets
                    (source_id, target_id, display_name, parent_id, kind, frozen, updated_at_epoch_second)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """,
                    [
                        .text(target.sourceId), .text(target.targetId), .text(target.displayName),
                        target.parentId.map { SQLiteValue.text($0) } ?? .null, .text(target.kind), .integer(observed)
                    ]
                )
            }
            for book in snapshot.books {
                try RemoteMirrorStore.mergeBook(book, connection)
            }
            try connection.execute(
                "DELETE FROM remote_mirror_items WHERE source_id = ?",
                [.text(snapshot.sourceId)]
            )
            for book in snapshot.books {
                let target = snapshot.memberships[book.identity] ?? nil
                try connection.execute(
                    """
                    INSERT INTO remote_mirror_items (source_id, remote_book_id, target_id, updated_at_epoch_second)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        .text(book.identity.sourceId), .text(book.identity.remoteBookId),
                        target.map { SQLiteValue.text($0) } ?? .null, .integer(observed)
                    ]
                )
            }
        }
    }

    /// Records one book's membership after a confirmed website write, without waiting for a refresh.
    public func setMembership(_ identity: BookIdentity, targetId: String?, at moment: Date) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO remote_mirror_items (source_id, remote_book_id, target_id, updated_at_epoch_second)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(identity.sourceId), .text(identity.remoteBookId),
                    targetId.map { SQLiteValue.text($0) } ?? .null, .integer(moment.epochSecond)
                ]
            )
        }
    }

    public func removeMembership(_ identity: BookIdentity) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                "DELETE FROM remote_mirror_items WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
        }
    }

    public func freeze(sourceId: String, frozen: Bool, at moment: Date) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                "UPDATE remote_mirror_bindings SET frozen = ?, updated_at_epoch_second = ? WHERE source_id = ?",
                [.integer(frozen ? 1 : 0), .integer(moment.epochSecond), .text(sourceId)]
            )
        }
    }

    public func mirror(sourceId: String) async throws -> RemoteMirror? {
        try await database.read { connection in
            guard let row = try connection.query(
                "SELECT * FROM remote_mirror_bindings WHERE source_id = ?",
                [.text(sourceId)]
            ).first, let name = row["display_name"].string else { return nil }
            let binding = RemoteMirrorBinding(
                sourceId: sourceId,
                displayName: name,
                frozen: row["frozen"].bool ?? false,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at_epoch_second"].int ?? 0))
            )
            let targets = try connection.query(
                "SELECT * FROM remote_mirror_targets WHERE source_id = ? ORDER BY display_name COLLATE NOCASE, target_id",
                [.text(sourceId)]
            ).compactMap { row -> RemoteMirrorTarget? in
                guard let targetId = row["target_id"].string, let displayName = row["display_name"].string,
                      let kind = row["kind"].string else { return nil }
                return RemoteMirrorTarget(
                    sourceId: sourceId,
                    targetId: targetId,
                    displayName: displayName,
                    parentId: row["parent_id"].string,
                    kind: kind,
                    frozen: row["frozen"].bool ?? false
                )
            }
            let items = try connection.query(
                "SELECT * FROM remote_mirror_items WHERE source_id = ? ORDER BY updated_at_epoch_second DESC, remote_book_id",
                [.text(sourceId)]
            ).compactMap { row -> RemoteMirrorItem? in
                guard let identity = LibraryCatalog.identity(from: row) else { return nil }
                return RemoteMirrorItem(
                    identity: identity,
                    targetId: row["target_id"].string,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at_epoch_second"].int ?? 0))
                )
            }
            return RemoteMirror(binding: binding, targets: targets, items: items)
        }
    }

    public func bindings() async throws -> [RemoteMirrorBinding] {
        try await database.read { connection in
            try connection.query("SELECT * FROM remote_mirror_bindings ORDER BY display_name COLLATE NOCASE, source_id")
                .compactMap { row -> RemoteMirrorBinding? in
                    guard let sourceId = row["source_id"].string, let name = row["display_name"].string else { return nil }
                    return RemoteMirrorBinding(
                        sourceId: sourceId,
                        displayName: name,
                        frozen: row["frozen"].bool ?? false,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at_epoch_second"].int ?? 0))
                    )
                }
        }
    }

    public func membership(_ identity: BookIdentity) async throws -> RemoteMirrorItem? {
        try await database.read { connection in
            guard let row = try connection.query(
                "SELECT * FROM remote_mirror_items WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            ).first else { return nil }
            return RemoteMirrorItem(
                identity: identity,
                targetId: row["target_id"].string,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at_epoch_second"].int ?? 0))
            )
        }
    }

    /// A sparse website listing must not erase what the catalog already knows: the author, cover
    /// and canonical address fall back to the stored row, and status and remote tags are always kept.
    static func mergeBook(_ incoming: LibraryBook, _ connection: SQLiteConnection) throws {
        guard let existing = try LibraryCatalog.book(incoming.identity, connection) else {
            try LibraryCatalog.saveBook(incoming, connection)
            return
        }
        try LibraryCatalog.saveBook(
            LibraryBook(
                identity: incoming.identity,
                title: incoming.title,
                addedAt: existing.addedAt,
                metadataUpdatedAt: incoming.metadataUpdatedAt,
                authors: existing.authors.union(incoming.authors),
                coverUrl: incoming.coverUrl ?? existing.coverUrl,
                canonicalUrl: incoming.canonicalUrl ?? existing.canonicalUrl,
                status: existing.status,
                remoteTags: existing.remoteTags
            ),
            connection
        )
    }
}
