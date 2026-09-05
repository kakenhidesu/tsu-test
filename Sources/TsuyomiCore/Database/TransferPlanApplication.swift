// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public extension TransferRepository {
    /// Applies one prepared plan inside a single transaction. Re-running it after `ROOM_APPLIED` is a
    /// no-op, so a crash between the database and preference stages cannot double-apply the import.
    func applyPlan(sessionId: String, digest: String, plan: ImportPlan) async throws {
        try await database.withTransaction { connection in
            guard let session = try connection.query(
                "SELECT * FROM import_sessions WHERE id = ?",
                [.text(sessionId)]
            ).first.flatMap(TransferRepository.session(from:)) else {
                throw DatabaseError.invariantViolated("Unknown import session")
            }
            guard session.planDigest == digest else {
                throw DatabaseError.invariantViolated("Import digest mismatch")
            }
            if session.status == .roomApplied { return }
            guard session.status == .prepared else {
                throw DatabaseError.invariantViolated("Import is not prepared")
            }

            let shelves = try TransferRepository.parentFirst(plan.shelves)
            for shelf in shelves {
                try TransferRepository.insertCollectionIfAbsent(
                    id: shelf.id,
                    kind: .manual,
                    title: shelf.name,
                    parentCollectionId: shelf.parentId,
                    displayOrder: Int64(shelf.position),
                    at: plan.sourceCreatedAt,
                    connection
                )
            }
            let smart = plan.smartCollections.sorted { CanonicalOrder.precedes($0.collectionId, $1.collectionId) }
            for (index, collection) in smart.enumerated() {
                let inserted = try TransferRepository.insertCollectionIfAbsent(
                    id: collection.collectionId,
                    kind: .smart,
                    title: collection.title,
                    parentCollectionId: nil,
                    displayOrder: Int64(shelves.count + index),
                    at: plan.sourceCreatedAt,
                    connection
                )
                guard inserted else { continue }
                let rule = try SmartRuleCodec.decode(collection.astJson)
                try SmartShelfQueryCompiler.requireWithinArgumentLimit(rule)
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO smart_rules (collection_id, rule_version, ast_json,
                    compiled_projection_version) VALUES (?, ?, ?, 1)
                    """,
                    [.text(collection.collectionId), .integer(Int64(rule.version)), .text(collection.astJson)]
                )
            }
            let drafts = plan.subscriptionDrafts.sorted { CanonicalOrder.precedes($0.collectionId, $1.collectionId) }
            for (index, draft) in drafts.enumerated() {
                let inserted = try TransferRepository.insertCollectionIfAbsent(
                    id: draft.collectionId,
                    kind: .subscription,
                    title: draft.title,
                    parentCollectionId: nil,
                    displayOrder: Int64(shelves.count + smart.count + index),
                    at: plan.sourceCreatedAt,
                    connection
                )
                guard inserted else { continue }
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO subscription_drafts (collection_id, mode, source_scope_json,
                    query_json, enabled, import_session_id) VALUES (?, ?, ?, ?, 0, ?)
                    """,
                    [
                        .text(draft.collectionId), .text(draft.mode), .text(draft.sourceScopeJson),
                        .text(draft.queryJson), .text(sessionId)
                    ]
                )
            }

            for incoming in plan.books {
                try TransferRepository.applyBook(incoming, plan: plan, connection)
            }

            for row in plan.searchHistory {
                let display = LibraryCatalog.collapseWhitespace(row.query)
                guard !display.isEmpty else { continue }
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO search_history (source_id, normalized_query, display_query,
                    last_used_at_epoch_second, last_used_at_nano) VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        .text(row.sourceId), .text(display.lowercased()), .text(display),
                        .integer(row.lastUsedAt.epochSecond), .integer(Int64(row.lastUsedAt.nanoOfSecond))
                    ]
                )
            }
            for row in plan.browsingHistory {
                guard try LibraryCatalog.book(row.identity, connection) != nil else { continue }
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO browsing_history (source_id, remote_book_id,
                    last_viewed_at_epoch_second, last_viewed_at_nano) VALUES (?, ?, ?, ?)
                    """,
                    [
                        .text(row.identity.sourceId), .text(row.identity.remoteBookId),
                        .integer(row.lastViewedAt.epochSecond), .integer(Int64(row.lastViewedAt.nanoOfSecond))
                    ]
                )
            }
            // An import never inherits remote write consent: every source must be re-approved.
            try connection.execute("UPDATE source_remote_policy SET add_writeback_enabled = 0 WHERE add_writeback_enabled = 1")
            try connection.execute(
                """
                UPDATE import_sessions SET status = ? WHERE id = ? AND plan_digest = ? AND status = ?
                """,
                [
                    .text(ImportSessionStatus.roomApplied.rawValue), .text(sessionId), .text(digest),
                    .text(ImportSessionStatus.prepared.rawValue)
                ]
            )
            guard connection.changes == 1 else {
                throw DatabaseError.invariantViolated("Import session transition failed")
            }
        }
    }

    func exportSnapshot(
        createdAt: Date,
        readerPreferences: PortableReaderPreferences?
    ) async throws -> TransferSnapshot {
        try await database.read { connection in
            var books: [TransferBook] = []
            let entryRows = try connection.query(
                "SELECT * FROM library_entries ORDER BY source_id, remote_book_id"
            )
            for entry in entryRows {
                guard let identity = LibraryCatalog.identity(from: entry),
                      let book = try LibraryCatalog.book(identity, connection),
                      let addedAt = entry.instant("added_at_epoch_second", "added_at_nano") else { continue }
                let localTags = try connection.query(
                    "SELECT display_tag FROM local_book_tags WHERE source_id = ? AND remote_book_id = ?",
                    [.text(identity.sourceId), .text(identity.remoteBookId)]
                ).compactMap { $0["display_tag"].string }
                let shelfIds = try connection.query(
                    """
                    SELECT collection_id FROM manual_collection_memberships
                    WHERE source_id = ? AND remote_book_id = ?
                    """,
                    [.text(identity.sourceId), .text(identity.remoteBookId)]
                ).compactMap { $0["collection_id"].string }
                let progress = try ReadingProgressStore.progress(identity, connection).map { stored in
                    TransferProgress(
                        chapterId: stored.locator.document.contentId,
                        textAnchor: stored.locator.textAnchorDigest,
                        characterOffset: stored.locator.characterOffset,
                        chapterProgress: stored.locator.chapterProgress,
                        bookProgress: stored.locator.bookProgress,
                        updatedAt: stored.updatedAt
                    )
                }
                books.append(
                    TransferBook(
                        identity: identity,
                        title: book.title,
                        authors: book.authors,
                        canonicalUrl: book.canonicalUrl,
                        coverUrl: book.coverUrl,
                        status: book.status ?? "unknown",
                        remoteTags: book.remoteTags,
                        localTags: Set(localTags),
                        shelfIds: Set(shelfIds),
                        rating: entry["rating"].int.map(Double.init),
                        readLater: entry["read_later"].bool ?? false,
                        addedAt: addedAt,
                        updatedAt: book.metadataUpdatedAt,
                        progress: progress
                    )
                )
            }
            let shelves = try connection.query(
                "SELECT * FROM collections WHERE kind = 'MANUAL' ORDER BY parent_collection_id, display_order, collection_id"
            ).compactMap(CollectionStore.collection(from:)).map { collection in
                TransferShelf(
                    id: collection.collectionId,
                    name: collection.title,
                    parentId: collection.parentCollectionId,
                    position: Int(collection.displayOrder)
                )
            }
            return TransferSnapshot(
                createdAt: createdAt,
                library: books,
                shelves: shelves,
                readerPreferences: readerPreferences
            )
        }
    }
}

extension TransferRepository {
    @discardableResult
    static func insertCollectionIfAbsent(
        id: String,
        kind: CollectionKind,
        title: String,
        parentCollectionId: String?,
        displayOrder: Int64,
        at moment: Date,
        _ connection: SQLiteConnection
    ) throws -> Bool {
        try connection.execute(
            """
            INSERT OR IGNORE INTO collections (collection_id, kind, title, parent_collection_id, display_order,
            created_at_epoch_second, created_at_nano, updated_at_epoch_second, updated_at_nano)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), .text(kind.rawValue), .text(title),
                parentCollectionId.map { SQLiteValue.text($0) } ?? .null,
                .integer(displayOrder),
                .integer(moment.epochSecond), .integer(Int64(moment.nanoOfSecond)),
                .integer(moment.epochSecond), .integer(Int64(moment.nanoOfSecond))
            ]
        )
        return connection.changes != 0
    }

    static func applyBook(_ incoming: TransferBook, plan: ImportPlan, _ connection: SQLiteConnection) throws {
        let identity = incoming.identity
        let existing = try LibraryCatalog.book(identity, connection)
        let accepted = existing.map { incoming.updatedAt > $0.metadataUpdatedAt } ?? true
        let addedAt = incoming.addedAt ?? plan.sourceCreatedAt
        let book: LibraryBook
        if accepted {
            book = LibraryBook(
                identity: identity,
                title: incoming.title,
                addedAt: addedAt,
                metadataUpdatedAt: incoming.updatedAt,
                authors: incoming.authors,
                coverUrl: incoming.coverUrl,
                canonicalUrl: incoming.canonicalUrl,
                status: incoming.status,
                remoteTags: incoming.remoteTags
            )
        } else if let existing {
            book = existing
        } else {
            return
        }
        try LibraryCatalog.saveBook(book, connection)

        let rating = TransferRepository.rating(incoming.rating)
        try connection.execute(
            """
            INSERT OR IGNORE INTO library_entries (source_id, remote_book_id, added_at_epoch_second,
            added_at_nano, rating, read_later, display_order) VALUES (?, ?, ?, ?, ?, ?, 2147483647)
            """,
            [
                .text(identity.sourceId), .text(identity.remoteBookId),
                .integer(addedAt.epochSecond), .integer(Int64(addedAt.nanoOfSecond)),
                rating.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                .integer(incoming.readLater ? 1 : 0)
            ]
        )
        let entryInserted = connection.changes != 0
        if !entryInserted, accepted, let rating {
            try connection.execute(
                "UPDATE library_entries SET rating = ? WHERE source_id = ? AND remote_book_id = ?",
                [.integer(Int64(rating)), .text(identity.sourceId), .text(identity.remoteBookId)]
            )
        }
        if !entryInserted, incoming.readLater {
            try connection.execute(
                "UPDATE library_entries SET read_later = 1 WHERE source_id = ? AND remote_book_id = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
        }

        var mergedTags: [(key: String, display: String)] = []
        var seen = Set<String>()
        for stored in try connection.query(
            "SELECT display_tag FROM local_book_tags WHERE source_id = ? AND remote_book_id = ? ORDER BY normalized_tag",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).compactMap({ $0["display_tag"].string }) {
            guard let tag = TransferRepository.normalizedTag(stored), seen.insert(tag.key).inserted else { continue }
            mergedTags.append(tag)
        }
        for raw in CanonicalOrder.sorted(incoming.localTags) {
            guard let tag = TransferRepository.normalizedTag(raw), !seen.contains(tag.key) else { continue }
            guard mergedTags.count < TransferRepository.maximumLocalTags else { continue }
            seen.insert(tag.key)
            mergedTags.append(tag)
        }
        try connection.execute(
            "DELETE FROM local_book_tags WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        )
        for tag in mergedTags {
            try connection.execute(
                """
                INSERT INTO local_book_tags (source_id, remote_book_id, normalized_tag, display_tag)
                VALUES (?, ?, ?, ?)
                """,
                [.text(identity.sourceId), .text(identity.remoteBookId), .text(tag.key), .text(tag.display)]
            )
        }

        if let progress = incoming.progress,
           let record = try TransferRepository.readingProgress(progress, identity) {
            let existingProgress = try ReadingProgressStore.progress(identity, connection)
            if existingProgress == nil || progress.updatedAt > (existingProgress?.updatedAt ?? Date.distantPast) {
                try ReadingProgressStore.upsert(record, connection)
            }
        }

        for shelfId in CanonicalOrder.sorted(incoming.shelfIds) {
            guard try CollectionStore.collection(shelfId, connection)?.kind == .manual else { continue }
            let members = try CollectionStore.manualIdentities(shelfId, connection)
            guard !members.contains(identity) else { continue }
            try CollectionStore.insertMembership(
                shelfId,
                identity,
                order: try CollectionStore.nextMembershipOrder(shelfId, connection),
                connection
            )
        }
    }

    static func readingProgress(_ progress: TransferProgress, _ identity: BookIdentity) throws -> ReadingProgress? {
        let blockId = (progress.textAnchor != nil || progress.characterOffset != nil) ? "transfer-anchor" : nil
        guard let locator = try? ReaderLocator(
            document: try DocumentIdentity(
                sourceId: identity.sourceId,
                remoteBookId: identity.remoteBookId,
                contentId: progress.chapterId ?? "unknown"
            ),
            blockId: blockId,
            textAnchorDigest: progress.textAnchor,
            characterOffset: progress.characterOffset,
            chapterProgress: progress.chapterProgress,
            bookProgress: progress.bookProgress,
            capturedAt: progress.updatedAt
        ) else { return nil }
        return try ReadingProgress(identity: identity, locator: locator)
    }

    /// Shelves are inserted parent-first so a foreign key never points at a row that does not exist yet.
    static func parentFirst(_ shelves: [TransferShelf]) throws -> [TransferShelf] {
        var remaining = shelves
        var result: [TransferShelf] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { shelf in
                    shelf.parentId == nil || result.contains { $0.id == shelf.parentId }
                }
                .sorted { lhs, rhs in
                    let byParent = CanonicalOrder.compare(lhs.parentId ?? "", rhs.parentId ?? "")
                    if byParent != 0 { return byParent < 0 }
                    if lhs.position != rhs.position { return lhs.position < rhs.position }
                    return CanonicalOrder.precedes(lhs.id, rhs.id)
                }
            guard !ready.isEmpty else { throw DatabaseError.invariantViolated("Shelf graph is cyclic") }
            let readyIds = Set(ready.map(\.id))
            result.append(contentsOf: ready)
            remaining.removeAll { readyIds.contains($0.id) }
        }
        return result
    }
}
