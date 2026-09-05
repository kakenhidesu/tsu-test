// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public enum ImportSessionStatus: String, Sendable, CaseIterable {
    case prepared = "PREPARED"
    case roomApplied = "ROOM_APPLIED"
    case preferencesApplied = "PREFERENCES_APPLIED"
    case completed = "COMPLETED"
    case aborted = "ABORTED"
    case abortedCleanupPending = "ABORTED_CLEANUP_PENDING"

    static let pendingStates: [ImportSessionStatus] = [
        .prepared, .roomApplied, .preferencesApplied, .abortedCleanupPending
    ]
}

public struct ImportSession: Hashable, Sendable {
    public let id: String
    public let kind: ImportKind
    public let planDigest: String
    public let normalizedPlanPath: String
    public let status: ImportSessionStatus
    public let sourceCreatedAt: Date
    public let startedAt: Date
    public let completedAt: Date?
    public let preferencePatchJson: String
    public let summaryJson: String?
}

/// `import_sessions` and `import_warnings`. An import is a staged, digest-pinned state machine so a
/// crash cannot leave the library half-migrated with no record of what was attempted.
public struct TransferRepository: Sendable {
    static let maximumLocalTags = 64
    static let maximumImportWarnings = 10_000

    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    /// Adds `CONFLICT` warnings for everything the host will keep instead of the incoming record, so
    /// the preview shows the real outcome before anything is written.
    public func withDatabaseConflicts(_ plan: ImportPlan) async throws -> ImportPlan {
        try await database.read { connection in
            var conflicts: [ImportWarning] = []
            let capacity = max(TransferRepository.maximumImportWarnings - plan.warnings.count, 0)
            func conflict(_ safeCode: String, _ safeRecordRef: String, _ fieldName: String) {
                guard conflicts.count < capacity else { return }
                conflicts.append(
                    ImportWarning(
                        ordinal: plan.warnings.count + conflicts.count,
                        safeCode: safeCode,
                        safeRecordRef: safeRecordRef,
                        fieldName: fieldName,
                        severity: .conflict
                    )
                )
            }

            for shelf in plan.shelves {
                guard let existing = try CollectionStore.collection(shelf.id, connection) else { continue }
                if existing.kind != .manual || existing.title != shelf.name
                    || existing.parentCollectionId != shelf.parentId
                    || existing.displayOrder != Int64(shelf.position) {
                    conflict("existing-shelf-retained", shelf.id, "shelf")
                }
            }
            for smart in plan.smartCollections {
                if try CollectionStore.collection(smart.collectionId, connection) != nil {
                    conflict("existing-smart-collection-retained", smart.collectionId, "smartCollection")
                }
            }
            for draft in plan.subscriptionDrafts {
                if try CollectionStore.collection(draft.collectionId, connection) != nil {
                    conflict("existing-subscription-draft-retained", draft.collectionId, "subscriptionDraft")
                }
            }
            for incoming in plan.books {
                let safeRef = "\(incoming.identity.sourceId):\(incoming.identity.remoteBookId)"
                let existingBook = try LibraryCatalog.book(incoming.identity, connection)
                let metadataAccepted = existingBook.map { incoming.updatedAt > $0.metadataUpdatedAt } ?? true
                if let existingBook, !metadataAccepted,
                   TransferRepository.metadataDiffers(incoming, existingBook) {
                    conflict("existing-book-metadata-retained", safeRef, "metadata")
                }
                let existingEntry = try connection.query(
                    "SELECT rating FROM library_entries WHERE source_id = ? AND remote_book_id = ?",
                    [.text(incoming.identity.sourceId), .text(incoming.identity.remoteBookId)]
                ).first
                let incomingRating = TransferRepository.rating(incoming.rating)
                if let incomingRating, let existingEntry,
                   Int64(incomingRating) != existingEntry["rating"].int, !metadataAccepted {
                    conflict("existing-rating-retained", safeRef, "rating")
                }
                let existingTags = Set(
                    try connection.query(
                        "SELECT display_tag FROM local_book_tags WHERE source_id = ? AND remote_book_id = ?",
                        [.text(incoming.identity.sourceId), .text(incoming.identity.remoteBookId)]
                    ).compactMap { $0["display_tag"].string }
                        .compactMap { TransferRepository.normalizedTag($0)?.key }
                )
                let incomingTags = Set(incoming.localTags.compactMap { TransferRepository.normalizedTag($0)?.key })
                let free = max(TransferRepository.maximumLocalTags - existingTags.count, 0)
                if incomingTags.subtracting(existingTags).count > free {
                    conflict("local-tags-capacity-conflict", safeRef, "localTags")
                }
                if let progress = incoming.progress {
                    let existing = try ReadingProgressStore.progress(incoming.identity, connection)
                    if let existing, progress.updatedAt <= existing.updatedAt {
                        conflict("existing-progress-retained", safeRef, "progress")
                    }
                }
            }
            return ImportPlan(
                kind: plan.kind,
                sourceCreatedAt: plan.sourceCreatedAt,
                books: plan.books,
                shelves: plan.shelves,
                readerPreferences: plan.readerPreferences,
                searchHistory: plan.searchHistory,
                browsingHistory: plan.browsingHistory,
                warnings: plan.warnings + conflicts,
                smartCollections: plan.smartCollections,
                subscriptionDrafts: plan.subscriptionDrafts
            )
        }
    }

    public func prepare(
        sessionId: String,
        plan: ImportPlan,
        planDigest: String,
        normalizedPlanPath: String,
        preferencePatchJson: String,
        startedAt: Date
    ) async throws {
        try await database.withTransaction { connection in
            guard try TransferRepository.pendingSession(connection) == nil else {
                throw DatabaseError.invariantViolated("Another import session is active")
            }
            try connection.execute(
                """
                INSERT INTO import_sessions (id, kind, plan_digest, normalized_plan_path, status,
                source_created_at_epoch_second, started_at_epoch_second, completed_at_epoch_second,
                preference_patch_json, summary_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL)
                """,
                [
                    .text(sessionId), .text(plan.kind.rawValue), .text(planDigest), .text(normalizedPlanPath),
                    .text(ImportSessionStatus.prepared.rawValue),
                    .integer(plan.sourceCreatedAt.epochSecond), .integer(startedAt.epochSecond),
                    .text(preferencePatchJson)
                ]
            )
            for warning in plan.warnings {
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO import_warnings (session_id, ordinal, safe_code, safe_record_ref,
                    field_name, severity) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(sessionId), .integer(Int64(warning.ordinal)), .text(warning.safeCode),
                        warning.safeRecordRef.map { SQLiteValue.text($0) } ?? .null,
                        warning.fieldName.map { SQLiteValue.text($0) } ?? .null,
                        .text(warning.severity.rawValue)
                    ]
                )
            }
        }
    }

    @discardableResult
    public func markPreferencesApplied(sessionId: String, digest: String) async throws -> Bool {
        try await transition(sessionId, digest, from: .roomApplied, to: .preferencesApplied)
    }

    @discardableResult
    public func complete(sessionId: String, digest: String, summary: ImportSummary) async throws -> Bool {
        try await transition(
            sessionId,
            digest,
            from: .preferencesApplied,
            to: .completed,
            completedAt: summary.completedAt,
            summaryJson: TransferRepository.safeJson(summary)
        )
    }

    @discardableResult
    public func abort(sessionId: String, digest: String, cleanupPending: Bool) async throws -> Bool {
        try await transition(
            sessionId,
            digest,
            from: .prepared,
            to: cleanupPending ? .abortedCleanupPending : .aborted
        )
    }

    @discardableResult
    public func markAbortCleanupComplete(sessionId: String, digest: String) async throws -> Bool {
        try await transition(sessionId, digest, from: .abortedCleanupPending, to: .aborted)
    }

    public func pending() async throws -> ImportSession? {
        try await database.read { try TransferRepository.pendingSession($0) }
    }

    public func latest() async throws -> ImportSession? {
        try await database.read { connection in
            try connection.query("SELECT * FROM import_sessions ORDER BY started_at_epoch_second DESC LIMIT 1")
                .first
                .flatMap(TransferRepository.session(from:))
        }
    }

    public func warnings(sessionId: String) async throws -> [ImportWarning] {
        try await database.read { connection in
            try connection.query(
                "SELECT * FROM import_warnings WHERE session_id = ? ORDER BY ordinal",
                [.text(sessionId)]
            ).compactMap { row in
                guard let ordinal = row["ordinal"].int, let safeCode = row["safe_code"].string,
                      let severity = row["severity"].string.flatMap(ImportSeverity.init(rawValue:)) else {
                    return nil
                }
                return ImportWarning(
                    ordinal: Int(ordinal),
                    safeCode: safeCode,
                    safeRecordRef: row["safe_record_ref"].string,
                    fieldName: row["field_name"].string,
                    severity: severity
                )
            }
        }
    }

    private func transition(
        _ sessionId: String,
        _ digest: String,
        from expected: ImportSessionStatus,
        to next: ImportSessionStatus,
        completedAt: Date? = nil,
        summaryJson: String? = nil
    ) async throws -> Bool {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE import_sessions SET status = ?, completed_at_epoch_second = ?,
                summary_json = COALESCE(?, summary_json)
                WHERE id = ? AND plan_digest = ? AND status = ?
                """,
                [
                    .text(next.rawValue),
                    completedAt.map { SQLiteValue.integer($0.epochSecond) } ?? .null,
                    summaryJson.map { SQLiteValue.text($0) } ?? .null,
                    .text(sessionId), .text(digest), .text(expected.rawValue)
                ]
            )
            return connection.changes == 1
        }
    }

    static func pendingSession(_ connection: SQLiteConnection) throws -> ImportSession? {
        let states = ImportSessionStatus.pendingStates.map { SQLiteValue.text($0.rawValue) }
        return try connection.query(
            """
            SELECT * FROM import_sessions WHERE status IN (?, ?, ?, ?)
            ORDER BY started_at_epoch_second LIMIT 1
            """,
            states
        ).first.flatMap(session(from:))
    }

    static func session(from row: SQLiteRow) -> ImportSession? {
        guard let id = row["id"].string,
              let kind = row["kind"].string.flatMap(ImportKind.init(rawValue:)),
              let planDigest = row["plan_digest"].string,
              let normalizedPlanPath = row["normalized_plan_path"].string,
              let status = row["status"].string.flatMap(ImportSessionStatus.init(rawValue:)),
              let sourceCreatedAt = row["source_created_at_epoch_second"].int,
              let startedAt = row["started_at_epoch_second"].int,
              let preferencePatchJson = row["preference_patch_json"].string else { return nil }
        return ImportSession(
            id: id,
            kind: kind,
            planDigest: planDigest,
            normalizedPlanPath: normalizedPlanPath,
            status: status,
            sourceCreatedAt: Date(epochSecond: sourceCreatedAt, nano: 0),
            startedAt: Date(epochSecond: startedAt, nano: 0),
            completedAt: row["completed_at_epoch_second"].int.map { Date(epochSecond: $0, nano: 0) },
            preferencePatchJson: preferencePatchJson,
            summaryJson: row["summary_json"].string
        )
    }

    static func metadataDiffers(_ incoming: TransferBook, _ existing: LibraryBook) -> Bool {
        incoming.title != existing.title
            || incoming.authors != existing.authors
            || incoming.canonicalUrl != existing.canonicalUrl
            || incoming.coverUrl != existing.coverUrl
            || (incoming.status != "unknown" && incoming.status != existing.status)
            || incoming.remoteTags != existing.remoteTags
    }

    static func normalizedTag(_ raw: String) -> (key: String, display: String)? {
        let display = LibraryCatalog.collapseWhitespace(raw)
        guard !display.isEmpty, Grammar.codePointCount(display) <= 64 else { return nil }
        return (display.lowercased(), display)
    }

    static func rating(_ value: Double?) -> Int? {
        guard let value, value > 0 else { return nil }
        return min(max(Int(value), 1), 5)
    }

    static func safeJson(_ summary: ImportSummary) -> String {
        let escaped = summary.sessionId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"sessionId\":\"\(escaped)\",\"kind\":\"\(summary.kind.rawValue)\","
            + "\"importedBooks\":\(summary.importedBooks),\"importedShelves\":\(summary.importedShelves),"
            + "\"warningCount\":\(summary.warningCount),"
            + "\"completedAt\":\"\(ProtocolTimestamp.format(summary.completedAt))\"}"
    }
}
