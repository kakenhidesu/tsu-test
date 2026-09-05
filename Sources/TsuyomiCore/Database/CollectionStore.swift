// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// `collections`, `manual_collection_memberships`, and `smart_rules`. Presentation hierarchy and
/// membership are separate concerns: reparenting or reordering never changes what a shelf contains.
public struct CollectionStore: Sendable {
    static let maximumDepth = 32

    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    public func collections() async throws -> [LibraryCollection] {
        try await database.read { connection in
            try connection.query(
                "SELECT * FROM collections ORDER BY parent_collection_id, display_order, collection_id"
            ).compactMap(CollectionStore.collection(from:))
        }
    }

    public func collectionEntries(
        _ collectionId: String,
        now: Date = Date()
    ) async throws -> [LibraryEntry] {
        try await database.read { connection in
            guard let collection = try CollectionStore.collection(collectionId, connection) else {
                throw DatabaseError.invariantViolated("Unknown collection")
            }
            let identities: [BookIdentity]
            switch collection.kind {
            case .manual:
                identities = try CollectionStore.manualIdentities(collectionId, connection)
            case .smart:
                guard let astJson = try connection.query(
                    "SELECT ast_json FROM smart_rules WHERE collection_id = ?",
                    [.text(collectionId)]
                ).first?["ast_json"].string else {
                    throw DatabaseError.invariantViolated("Smart collection has no rule")
                }
                let rule = try SmartRuleCodec.decode(astJson)
                let compiled = try SmartShelfQueryCompiler.compile(rule, now: now)
                identities = try connection.query(compiled.sql, compiled.bindings)
                    .compactMap(LibraryCatalog.identity)
            case .subscription:
                identities = []
            }
            return try LibraryCatalog.entries(identities, connection)
        }
    }

    public func createCollection(_ collection: LibraryCollection) async throws {
        try await database.withTransaction { try CollectionStore.insert(collection, $0) }
    }

    public func createSmartCollection(_ collection: LibraryCollection, rule: SmartRule) async throws {
        guard collection.kind == .smart else {
            throw DatabaseError.invariantViolated("Smart rule requires a smart collection")
        }
        let astJson = try SmartRuleCodec.encode(rule)
        try SmartShelfQueryCompiler.requireWithinArgumentLimit(rule)
        try await database.withTransaction { connection in
            try CollectionStore.insert(collection, connection)
            try connection.execute(
                """
                INSERT OR REPLACE INTO smart_rules (collection_id, rule_version, ast_json, compiled_projection_version)
                VALUES (?, ?, ?, 1)
                """,
                [.text(collection.collectionId), .integer(Int64(rule.version)), .text(astJson)]
            )
        }
    }

    public func renameCollection(_ collectionId: String, title: String, updatedAt: Date = Date()) async throws {
        let normalized = LibraryCatalog.collapseWhitespace(title)
        guard !normalized.isEmpty, normalized.utf16.count <= 512 else {
            throw DatabaseError.invariantViolated("Invalid collection title")
        }
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE collections SET title = ?, updated_at_epoch_second = ?, updated_at_nano = ?
                WHERE collection_id = ?
                """,
                [
                    .text(normalized), .integer(updatedAt.epochSecond),
                    .integer(Int64(updatedAt.nanoOfSecond)), .text(collectionId)
                ]
            )
            guard connection.changes == 1 else { throw DatabaseError.invariantViolated("Unknown collection") }
        }
    }

    @discardableResult
    public func deleteCollection(_ collectionId: String) async throws -> Bool {
        try await database.withTransaction { connection in
            guard let deleted = try CollectionStore.collection(collectionId, connection) else { return false }
            let formerParentId = deleted.parentCollectionId
            try connection.execute(
                "UPDATE collections SET parent_collection_id = NULL WHERE parent_collection_id = ?",
                [.text(collectionId)]
            )
            try connection.execute("DELETE FROM collections WHERE collection_id = ?", [.text(collectionId)])
            guard connection.changes == 1 else { throw DatabaseError.invariantViolated("Unknown collection") }
            try CollectionStore.compactSiblings(formerParentId, connection)
            if formerParentId != nil { try CollectionStore.compactSiblings(nil, connection) }
            return true
        }
    }

    /// Changes only presentation hierarchy; it never changes collection membership semantics.
    public func updateCollectionPresentation(
        _ collectionId: String,
        parentCollectionId: String?,
        displayOrder: Int64
    ) async throws {
        try await database.withTransaction { connection in
            guard try CollectionStore.collection(collectionId, connection) != nil else {
                throw DatabaseError.invariantViolated("Unknown collection")
            }
            guard parentCollectionId != collectionId else {
                throw DatabaseError.invariantViolated("A collection cannot parent itself")
            }
            if let parentCollectionId {
                guard try CollectionStore.collection(parentCollectionId, connection) != nil else {
                    throw DatabaseError.invariantViolated("Unknown parent collection")
                }
                guard try !CollectionStore.wouldCreateCycle(collectionId, parentCollectionId, connection) else {
                    throw DatabaseError.invariantViolated("Collection parent cycle")
                }
            }
            try connection.execute(
                "UPDATE collections SET parent_collection_id = ?, display_order = ? WHERE collection_id = ?",
                [
                    parentCollectionId.map { SQLiteValue.text($0) } ?? .null,
                    .integer(displayOrder), .text(collectionId)
                ]
            )
            guard connection.changes == 1 else { throw DatabaseError.invariantViolated("Unknown collection") }
        }
    }

    public func createManualCollectionWithMemberships(
        _ collection: LibraryCollection,
        identities: [BookIdentity]
    ) async throws {
        guard collection.kind == .manual else {
            throw DatabaseError.invariantViolated("Stored membership requires a manual collection")
        }
        try await database.withTransaction { connection in
            try CollectionStore.insert(collection, connection)
            for (index, identity) in identities.enumerated() {
                try CollectionStore.insertMembership(
                    collection.collectionId,
                    identity,
                    order: Int64(index),
                    connection
                )
            }
        }
    }

    @discardableResult
    public func addManualMembership(_ collectionId: String, _ identity: BookIdentity) async throws -> Bool {
        try await addManualMemberships(collectionId, [identity]) == 1
    }

    @discardableResult
    public func addManualMemberships(_ collectionId: String, _ identities: [BookIdentity]) async throws -> Int {
        try await database.withTransaction { connection in
            guard let collection = try CollectionStore.collection(collectionId, connection) else {
                throw DatabaseError.invariantViolated("Unknown collection")
            }
            guard collection.kind == .manual else {
                throw DatabaseError.invariantViolated("Only manual collections have stored membership")
            }
            var nextOrder = try CollectionStore.nextMembershipOrder(collectionId, connection)
            var inserted = 0
            for identity in identities {
                if try CollectionStore.insertMembership(collectionId, identity, order: nextOrder, connection) {
                    nextOrder += 1
                    inserted += 1
                }
            }
            return inserted
        }
    }

    @discardableResult
    public func removeManualMembership(_ collectionId: String, _ identity: BookIdentity) async throws -> Bool {
        try await removeManualMemberships(collectionId, [identity]) == 1
    }

    @discardableResult
    public func removeManualMemberships(_ collectionId: String, _ identities: [BookIdentity]) async throws -> Int {
        try await database.withTransaction { connection in
            var removed = 0
            for identity in identities {
                try connection.execute(
                    """
                    DELETE FROM manual_collection_memberships
                    WHERE collection_id = ? AND source_id = ? AND remote_book_id = ?
                    """,
                    [.text(collectionId), .text(identity.sourceId), .text(identity.remoteBookId)]
                )
                if connection.changes != 0 { removed += 1 }
            }
            try CollectionStore.compactMemberships(collectionId, connection)
            return removed
        }
    }

    public func reorderManualMemberships(_ collectionId: String, _ identities: [BookIdentity]) async throws {
        try await database.withTransaction { connection in
            let current = try CollectionStore.manualIdentities(collectionId, connection)
            guard identities.count == current.count, Set(identities) == Set(current) else {
                throw DatabaseError.invariantViolated(
                    "Manual collection reorder must contain every current member exactly once"
                )
            }
            for (index, identity) in identities.enumerated() {
                try connection.execute(
                    """
                    UPDATE manual_collection_memberships SET display_order = ?
                    WHERE collection_id = ? AND source_id = ? AND remote_book_id = ?
                    """,
                    [
                        .integer(Int64(index)), .text(collectionId),
                        .text(identity.sourceId), .text(identity.remoteBookId)
                    ]
                )
                guard connection.changes == 1 else {
                    throw DatabaseError.invariantViolated("Manual membership reorder target is missing")
                }
            }
        }
    }
}

extension CollectionStore {
    static func collection(from row: SQLiteRow) -> LibraryCollection? {
        guard let collectionId = row["collection_id"].string,
              let kind = row["kind"].string.flatMap(CollectionKind.init(rawValue:)),
              let title = row["title"].string,
              let displayOrder = row["display_order"].int,
              let createdAt = row.instant("created_at_epoch_second", "created_at_nano"),
              let updatedAt = row.instant("updated_at_epoch_second", "updated_at_nano") else { return nil }
        return try? LibraryCollection(
            collectionId: collectionId,
            kind: kind,
            title: title,
            parentCollectionId: row["parent_collection_id"].string,
            displayOrder: displayOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func collection(_ collectionId: String, _ connection: SQLiteConnection) throws -> LibraryCollection? {
        try connection.query("SELECT * FROM collections WHERE collection_id = ?", [.text(collectionId)])
            .first
            .flatMap(collection(from:))
    }

    static func insert(_ collection: LibraryCollection, _ connection: SQLiteConnection) throws {
        if let parentId = collection.parentCollectionId {
            guard try CollectionStore.collection(parentId, connection) != nil else {
                throw DatabaseError.invariantViolated("Unknown parent collection")
            }
            guard try !wouldCreateCycle(collection.collectionId, parentId, connection) else {
                throw DatabaseError.invariantViolated("Collection hierarchy is cyclic or exceeds its depth bound")
            }
        }
        try connection.execute(
            """
            INSERT INTO collections (collection_id, kind, title, parent_collection_id, display_order,
            created_at_epoch_second, created_at_nano, updated_at_epoch_second, updated_at_nano)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(collection.collectionId), .text(collection.kind.rawValue), .text(collection.title),
                collection.parentCollectionId.map { SQLiteValue.text($0) } ?? .null,
                .integer(collection.displayOrder),
                .integer(collection.createdAt.epochSecond), .integer(Int64(collection.createdAt.nanoOfSecond)),
                .integer(collection.updatedAt.epochSecond), .integer(Int64(collection.updatedAt.nanoOfSecond))
            ]
        )
    }

    static func manualIdentities(_ collectionId: String, _ connection: SQLiteConnection) throws -> [BookIdentity] {
        try connection.query(
            """
            SELECT source_id, remote_book_id FROM manual_collection_memberships
            WHERE collection_id = ? ORDER BY display_order, source_id, remote_book_id
            """,
            [.text(collectionId)]
        ).compactMap(LibraryCatalog.identity)
    }

    static func nextMembershipOrder(_ collectionId: String, _ connection: SQLiteConnection) throws -> Int64 {
        try connection.query(
            """
            SELECT COALESCE(MAX(display_order), -1) + 1 AS next
            FROM manual_collection_memberships WHERE collection_id = ?
            """,
            [.text(collectionId)]
        ).first?["next"].int ?? 0
    }

    @discardableResult
    static func insertMembership(
        _ collectionId: String,
        _ identity: BookIdentity,
        order: Int64,
        _ connection: SQLiteConnection
    ) throws -> Bool {
        guard let entry = try connection.query(
            "SELECT added_at_epoch_second, added_at_nano FROM library_entries WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).first else {
            throw DatabaseError.invariantViolated("Book is not in library")
        }
        try connection.execute(
            """
            INSERT OR IGNORE INTO manual_collection_memberships
            (collection_id, source_id, remote_book_id, added_at_epoch_second, added_at_nano, display_order)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                .text(collectionId), .text(identity.sourceId), .text(identity.remoteBookId),
                .integer(entry["added_at_epoch_second"].int ?? 0),
                .integer(entry["added_at_nano"].int ?? 0),
                .integer(order)
            ]
        )
        return connection.changes != 0
    }

    static func wouldCreateCycle(
        _ collectionId: String,
        _ prospectiveParentId: String,
        _ connection: SQLiteConnection
    ) throws -> Bool {
        var cursor: String? = prospectiveParentId
        var ancestorCount = 0
        while let current = cursor {
            if current == collectionId || ancestorCount >= maximumDepth - 1 { return true }
            cursor = try connection.query(
                "SELECT parent_collection_id FROM collections WHERE collection_id = ?",
                [.text(current)]
            ).first?["parent_collection_id"].string
            ancestorCount += 1
        }
        return false
    }

    static func compactSiblings(_ parentCollectionId: String?, _ connection: SQLiteConnection) throws {
        let rows = try connection.query(
            """
            SELECT collection_id, display_order FROM collections
            WHERE parent_collection_id IS ? ORDER BY display_order, collection_id
            """,
            [parentCollectionId.map { SQLiteValue.text($0) } ?? .null]
        )
        for (index, row) in rows.enumerated() where row["display_order"].int != Int64(index) {
            guard let collectionId = row["collection_id"].string else { continue }
            try connection.execute(
                "UPDATE collections SET display_order = ? WHERE collection_id = ?",
                [.integer(Int64(index)), .text(collectionId)]
            )
        }
    }

    static func compactMemberships(_ collectionId: String, _ connection: SQLiteConnection) throws {
        let rows = try connection.query(
            """
            SELECT source_id, remote_book_id, display_order FROM manual_collection_memberships
            WHERE collection_id = ? ORDER BY display_order, source_id, remote_book_id
            """,
            [.text(collectionId)]
        )
        for (index, row) in rows.enumerated() where row["display_order"].int != Int64(index) {
            guard let identity = LibraryCatalog.identity(from: row) else { continue }
            try connection.execute(
                """
                UPDATE manual_collection_memberships SET display_order = ?
                WHERE collection_id = ? AND source_id = ? AND remote_book_id = ?
                """,
                [
                    .integer(Int64(index)), .text(collectionId),
                    .text(identity.sourceId), .text(identity.remoteBookId)
                ]
            )
        }
    }
}
