// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The update inbox and its sessions (Room v9). Every write to a running session carries the owner
/// token and is refused once the lease lapsed; a terminal session is never resumed; an ignored update
/// can be undone for a short while, and a newer detection wins over the undo.
public struct UpdateStore: Sendable {
    public static let leaseDuration: TimeInterval = 120
    public static let undoLifetime: TimeInterval = 30
    public static let maximumCandidates = 128
    public static let itemPageSize = 100

    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    // MARK: Policy and exclusions

    public func policy() async throws -> UpdatePolicy {
        try await database.read { connection in
            guard let row = try connection.query("SELECT * FROM update_policy WHERE id = 'default'").first,
                  let cadence = row["cadence"].string.flatMap(UpdateCadence.init(rawValue:)) else {
                return UpdatePolicy()
            }
            return UpdatePolicy(
                cadence: cadence,
                unmeteredOnly: row["unmetered_only"].bool ?? true,
                requiresCharging: row["requires_charging"].bool ?? false,
                batteryNotLow: row["battery_not_low"].bool ?? true
            )
        }
    }

    public func savePolicy(_ policy: UpdatePolicy) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO update_policy (id, cadence, unmetered_only, requires_charging, battery_not_low)
                VALUES ('default', ?, ?, ?, ?)
                """,
                [
                    .text(policy.cadence.rawValue), .integer(policy.unmeteredOnly ? 1 : 0),
                    .integer(policy.requiresCharging ? 1 : 0), .integer(policy.batteryNotLow ? 1 : 0)
                ]
            )
        }
    }

    public func setBookExcluded(_ identity: BookIdentity, excluded: Bool) async throws {
        try await database.withTransaction { connection in
            if excluded {
                try connection.execute(
                    "INSERT OR IGNORE INTO update_book_exclusions (source_id, remote_book_id) VALUES (?, ?)",
                    [.text(identity.sourceId), .text(identity.remoteBookId)]
                )
            } else {
                try connection.execute(
                    "DELETE FROM update_book_exclusions WHERE source_id = ? AND remote_book_id = ?",
                    [.text(identity.sourceId), .text(identity.remoteBookId)]
                )
            }
        }
    }

    public func setSourceExcluded(_ sourceId: String, excluded: Bool) async throws {
        try await database.withTransaction { connection in
            if excluded {
                try connection.execute("INSERT OR IGNORE INTO update_source_exclusions (source_id) VALUES (?)", [.text(sourceId)])
            } else {
                try connection.execute("DELETE FROM update_source_exclusions WHERE source_id = ?", [.text(sourceId)])
            }
        }
    }

    public func isBookExcluded(_ identity: BookIdentity) async throws -> Bool {
        try await database.read { try UpdateStore.bookExcluded(identity, $0) }
    }

    public func excludedBooks() async throws -> [BookIdentity] {
        try await database.read { connection in
            try connection.query("SELECT source_id, remote_book_id FROM update_book_exclusions ORDER BY source_id, remote_book_id")
                .compactMap(LibraryCatalog.identity)
        }
    }

    public func excludedSources() async throws -> [String] {
        try await database.read { connection in
            try connection.query("SELECT source_id FROM update_source_exclusions ORDER BY source_id")
                .compactMap { $0["source_id"].string }
        }
    }

    // MARK: Sessions

    /// Opens a running session over the candidates that are still eligible, deduplicated by
    /// identity and bounded. A session already running or queued is left alone: the caller reports
    /// it as busy rather than starting a second one.
    public func startSession(
        trigger: UpdateSessionTrigger,
        candidates: [UpdateCandidate],
        now: Date
    ) async throws -> UpdateSessionLease? {
        try await database.withTransaction { connection in
            let live = try connection.query(
                "SELECT session_id FROM update_sessions WHERE state IN ('QUEUED', 'RUNNING') AND (lease_expires_at_millis IS NULL OR lease_expires_at_millis > ?) LIMIT 1",
                [.integer(UpdateStore.millis(now))]
            )
            guard live.isEmpty else { return nil }
            var seen = Set<BookIdentity>()
            var accepted: [UpdateCandidate] = []
            for candidate in candidates where seen.insert(candidate.identity).inserted {
                guard accepted.count < UpdateStore.maximumCandidates else { break }
                guard try !UpdateStore.bookExcluded(candidate.identity, connection),
                      try !UpdateStore.sourceExcluded(candidate.identity.sourceId, connection) else { continue }
                accepted.append(candidate)
            }
            let sessionId = UUID().uuidString
            let ownerToken = UUID().uuidString
            let expiresAt = now.addingTimeInterval(UpdateStore.leaseDuration)
            try connection.execute(
                """
                INSERT INTO update_sessions (session_id, trigger, state, total, completed, updated, failed, reason,
                lease_expires_at_millis, lease_owner_token, cancellation_requested, started_at_millis, finished_at_millis)
                VALUES (?, ?, 'RUNNING', ?, 0, 0, 0, NULL, ?, ?, 0, ?, NULL)
                """,
                [
                    .text(sessionId), .text(trigger.rawValue), .integer(Int64(accepted.count)),
                    .integer(UpdateStore.millis(expiresAt)), .text(ownerToken), .integer(UpdateStore.millis(now))
                ]
            )
            for candidate in accepted {
                try connection.execute(
                    """
                    INSERT INTO update_session_items (session_id, source_id, remote_book_id, captured_title, state, reason, anchor)
                    VALUES (?, ?, ?, ?, 'PENDING', NULL, NULL)
                    """,
                    [
                        .text(sessionId), .text(candidate.identity.sourceId), .text(candidate.identity.remoteBookId),
                        .text(candidate.title)
                    ]
                )
            }
            if accepted.isEmpty {
                try UpdateStore.finish(sessionId, reason: nil, at: now, connection)
            }
            return UpdateSessionLease(sessionId: sessionId, ownerToken: ownerToken, expiresAt: expiresAt)
        }
    }

    /// A running session whose lease lapsed goes back to the queue with its pending items intact;
    /// terminal sessions are never touched.
    public func recoverExpiredSessions(now: Date) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE update_sessions SET state = 'QUEUED', lease_expires_at_millis = NULL, lease_owner_token = NULL
                WHERE state = 'RUNNING' AND lease_expires_at_millis IS NOT NULL AND lease_expires_at_millis <= ?
                """,
                [.integer(UpdateStore.millis(now))]
            )
        }
    }

    /// Re-claims a queued session's pending items under a fresh lease; candidates are never
    /// re-enumerated.
    public func claimQueuedSession(now: Date) async throws -> UpdateSessionLease? {
        try await database.withTransaction { connection in
            guard let row = try connection.query(
                "SELECT session_id FROM update_sessions WHERE state = 'QUEUED' ORDER BY started_at_millis LIMIT 1"
            ).first, let sessionId = row["session_id"].string else { return nil }
            let ownerToken = UUID().uuidString
            let expiresAt = now.addingTimeInterval(UpdateStore.leaseDuration)
            try connection.execute(
                "UPDATE update_sessions SET state = 'RUNNING', lease_expires_at_millis = ?, lease_owner_token = ? WHERE session_id = ?",
                [.integer(UpdateStore.millis(expiresAt)), .text(ownerToken), .text(sessionId)]
            )
            return UpdateSessionLease(sessionId: sessionId, ownerToken: ownerToken, expiresAt: expiresAt)
        }
    }

    public func renewLease(_ lease: UpdateSessionLease, now: Date) async throws -> UpdateSessionLease? {
        try await database.withTransaction { connection in
            let expiresAt = now.addingTimeInterval(UpdateStore.leaseDuration)
            try connection.execute(
                """
                UPDATE update_sessions SET lease_expires_at_millis = ?
                WHERE session_id = ? AND state = 'RUNNING' AND lease_owner_token = ? AND lease_expires_at_millis > ?
                """,
                [.integer(UpdateStore.millis(expiresAt)), .text(lease.sessionId), .text(lease.ownerToken), .integer(UpdateStore.millis(now))]
            )
            guard connection.changes == 1 else { return nil }
            return UpdateSessionLease(sessionId: lease.sessionId, ownerToken: lease.ownerToken, expiresAt: expiresAt)
        }
    }

    public func pendingCandidates(_ lease: UpdateSessionLease, limit: Int, now: Date) async throws -> [UpdateCandidate] {
        try await database.read { connection in
            guard try UpdateStore.isActive(lease, now, connection) else { return [] }
            return try connection.query(
                """
                SELECT source_id, remote_book_id, captured_title FROM update_session_items
                WHERE session_id = ? AND state = 'PENDING' ORDER BY source_id, remote_book_id LIMIT ?
                """,
                [.text(lease.sessionId), .integer(Int64(limit))]
            ).compactMap { row in
                guard let identity = LibraryCatalog.identity(from: row), let title = row["captured_title"].string else { return nil }
                return UpdateCandidate(identity: identity, title: title)
            }
        }
    }

    public func isCancellationRequested(_ lease: UpdateSessionLease) async throws -> Bool {
        try await database.read { connection in
            try connection.query(
                "SELECT cancellation_requested FROM update_sessions WHERE session_id = ?",
                [.text(lease.sessionId)]
            ).first?["cancellation_requested"].bool ?? true
        }
    }

    /// Records one probe. The item finishes exactly once, the baseline moves only for an accepted
    /// list, and an update reaches the inbox unless every merged new chapter is already completed.
    @discardableResult
    public func recordProbe(
        _ lease: UpdateSessionLease,
        result: UpdateProbeResult,
        completedChapterIds: Set<String>,
        now: Date
    ) async throws -> Bool {
        try await database.withTransaction { connection in
            guard try UpdateStore.isActive(lease, now, connection) else { return false }
            let stored = try UpdateStore.baseline(result.identity, connection)
            guard stored?.anchor == result.previousAnchor else {
                try UpdateStore.finishItem(lease.sessionId, result.identity, state: .failed, reason: "invalid-probe-result", anchor: nil, connection)
                try UpdateStore.refresh(lease.sessionId, at: now, connection)
                return true
            }
            let state: UpdateItemState
            switch result.outcome {
            case .unchanged: state = .unchanged
            case .updated: state = .updated
            case .unavailable: state = .unavailable
            case .failed: state = .failed
            }
            if let anchor = result.anchor {
                try connection.execute(
                    """
                    INSERT OR REPLACE INTO update_baselines
                    (source_id, remote_book_id, anchor, chapters_json, last_updated_date, updated_at_millis)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(result.identity.sourceId), .text(result.identity.remoteBookId), .text(anchor),
                        .text(UpdateStore.encodeChapters(result.chapters)),
                        result.lastUpdatedDate.map { SQLiteValue.text($0) } ?? .null, .integer(UpdateStore.millis(now))
                    ]
                )
            }
            if result.outcome == .updated, let anchor = result.anchor {
                let existing = try UpdateStore.unresolved(result.identity, connection)
                let merged = UpdateStore.mergedIds(existing?.newChapterIds ?? [], result.newChapterIds)
                if !merged.allSatisfy(completedChapterIds.contains) {
                    let title = try connection.query(
                        "SELECT captured_title FROM update_session_items WHERE session_id = ? AND source_id = ? AND remote_book_id = ?",
                        [.text(lease.sessionId), .text(result.identity.sourceId), .text(result.identity.remoteBookId)]
                    ).first?["captured_title"].string ?? existing?.title ?? ""
                    try connection.execute(
                        """
                        INSERT OR REPLACE INTO unresolved_updates
                        (source_id, remote_book_id, title, anchor, chapters_json, new_chapter_ids_json, last_updated_date,
                        detected_at_millis, revision)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(result.identity.sourceId), .text(result.identity.remoteBookId), .text(title), .text(anchor),
                            .text(UpdateStore.encodeChapters(result.chapters)), .text(UpdateStore.encodeIds(merged)),
                            result.lastUpdatedDate.map { SQLiteValue.text($0) } ?? .null,
                            .integer(UpdateStore.millis(now)), .integer((existing?.revision ?? 0) + 1)
                        ]
                    )
                } else if existing != nil {
                    try connection.execute(
                        "DELETE FROM unresolved_updates WHERE source_id = ? AND remote_book_id = ?",
                        [.text(result.identity.sourceId), .text(result.identity.remoteBookId)]
                    )
                }
            }
            try UpdateStore.finishItem(lease.sessionId, result.identity, state: state, reason: result.reason, anchor: result.anchor, connection)
            try UpdateStore.refresh(lease.sessionId, at: now, connection)
            return true
        }
    }

    public func skipItem(_ lease: UpdateSessionLease, _ identity: BookIdentity, reason: String, now: Date) async throws {
        try await database.withTransaction { connection in
            guard try UpdateStore.isActive(lease, now, connection) else { return }
            try UpdateStore.finishItem(lease.sessionId, identity, state: .skipped, reason: reason, anchor: nil, connection)
            try UpdateStore.refresh(lease.sessionId, at: now, connection)
        }
    }

    /// Cancellation is durable first: pending items are cancelled and the session closes with a
    /// composed reason, whether or not the process that ran it is still alive.
    public func cancelActiveSession(now: Date) async throws -> Bool {
        try await database.withTransaction { connection in
            guard let row = try connection.query(
                "SELECT session_id FROM update_sessions WHERE state IN ('QUEUED', 'RUNNING') ORDER BY started_at_millis DESC LIMIT 1"
            ).first, let sessionId = row["session_id"].string else { return false }
            try connection.execute(
                "UPDATE update_sessions SET cancellation_requested = 1 WHERE session_id = ?",
                [.text(sessionId)]
            )
            try connection.execute(
                "UPDATE update_session_items SET state = 'CANCELLED', reason = 'cancelled' WHERE session_id = ? AND state = 'PENDING'",
                [.text(sessionId)]
            )
            try UpdateStore.finish(sessionId, reason: nil, at: now, connection, cancelled: true)
            return true
        }
    }

    public func relinquish(_ lease: UpdateSessionLease) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE update_sessions SET state = 'QUEUED', lease_expires_at_millis = NULL, lease_owner_token = NULL
                WHERE session_id = ? AND state = 'RUNNING' AND lease_owner_token = ?
                """,
                [.text(lease.sessionId), .text(lease.ownerToken)]
            )
        }
    }

    // MARK: Snapshots

    public func latestSession() async throws -> UpdateSessionSummary? {
        try await database.read { connection in
            try connection.query(
                """
                SELECT * FROM update_sessions
                ORDER BY CASE WHEN state IN ('QUEUED', 'RUNNING') THEN 0 ELSE 1 END,
                COALESCE(finished_at_millis, started_at_millis) DESC LIMIT 1
                """
            ).first.flatMap(UpdateStore.summary(from:))
        }
    }

    public func sessionItems(_ sessionId: String, limit: Int, offset: Int = 0) async throws -> [UpdateSessionItemSummary] {
        try await database.read { connection in
            try connection.query(
                """
                SELECT * FROM update_session_items WHERE session_id = ?
                ORDER BY CASE state WHEN 'UPDATED' THEN 0 WHEN 'FAILED' THEN 1 WHEN 'UNAVAILABLE' THEN 2 ELSE 3 END,
                source_id, remote_book_id LIMIT ? OFFSET ?
                """,
                [.text(sessionId), .integer(Int64(limit)), .integer(Int64(offset))]
            ).compactMap { row in
                guard let identity = LibraryCatalog.identity(from: row), let title = row["captured_title"].string,
                      let state = row["state"].string.flatMap(UpdateItemState.init(rawValue:)) else { return nil }
                return UpdateSessionItemSummary(
                    identity: identity, capturedTitle: title, state: state, reason: row["reason"].string, anchor: row["anchor"].string
                )
            }
        }
    }

    public func unresolvedUpdates() async throws -> [UnresolvedUpdate] {
        try await database.read { connection in
            try connection.query("SELECT * FROM unresolved_updates ORDER BY detected_at_millis DESC, source_id, remote_book_id")
                .compactMap(UpdateStore.unresolved(from:))
        }
    }

    public func baseline(_ identity: BookIdentity) async throws -> UpdateBaseline? {
        try await database.read { try UpdateStore.baseline(identity, $0) }
    }

    // MARK: Ignore, undo, completion

    /// Ignoring names the exact revision the reader saw; a newer detection makes the ignore a no-op.
    public func ignore(_ identity: BookIdentity, anchor: String, now: Date) async throws -> String? {
        try await database.withTransaction { connection in
            try UpdateStore.purgeExpiredUndos(now, connection)
            guard let current = try UpdateStore.unresolved(identity, connection), current.anchor == anchor else { return nil }
            let token = UUID().uuidString
            try connection.execute(
                """
                INSERT INTO update_ignore_undos (token_id, source_id, remote_book_id, title, anchor, chapters_json,
                new_chapter_ids_json, last_updated_date, detected_at_millis, revision, expires_at_millis)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(token), .text(identity.sourceId), .text(identity.remoteBookId), .text(current.title),
                    .text(current.anchor), .text(UpdateStore.encodeChapters(current.chapters)),
                    .text(UpdateStore.encodeIds(current.newChapterIds)),
                    current.lastUpdatedDate.map { SQLiteValue.text($0) } ?? .null,
                    .integer(UpdateStore.millis(current.detectedAt)), .integer(current.revision),
                    .integer(UpdateStore.millis(now.addingTimeInterval(UpdateStore.undoLifetime)))
                ]
            )
            try connection.execute(
                "DELETE FROM unresolved_updates WHERE source_id = ? AND remote_book_id = ? AND anchor = ? AND revision = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId), .text(anchor), .integer(current.revision)]
            )
            return token
        }
    }

    @discardableResult
    public func undo(token: String, now: Date) async throws -> Bool {
        try await database.withTransaction { connection in
            try UpdateStore.purgeExpiredUndos(now, connection)
            guard let row = try connection.query("SELECT * FROM update_ignore_undos WHERE token_id = ?", [.text(token)]).first,
                  let identity = LibraryCatalog.identity(from: row), let title = row["title"].string,
                  let anchor = row["anchor"].string, let chapters = row["chapters_json"].string,
                  let ids = row["new_chapter_ids_json"].string else { return false }
            try connection.execute("DELETE FROM update_ignore_undos WHERE token_id = ?", [.text(token)])
            try connection.execute(
                """
                INSERT OR IGNORE INTO unresolved_updates
                (source_id, remote_book_id, title, anchor, chapters_json, new_chapter_ids_json, last_updated_date,
                detected_at_millis, revision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(identity.sourceId), .text(identity.remoteBookId), .text(title), .text(anchor), .text(chapters), .text(ids),
                    row["last_updated_date"].string.map { SQLiteValue.text($0) } ?? .null,
                    .integer(row["detected_at_millis"].int ?? 0), .integer(row["revision"].int ?? 0)
                ]
            )
            return connection.changes != 0
        }
    }

    /// An update resolves itself only when every chapter it announced has been completed.
    public func reconcileCompleted(_ identity: BookIdentity, completedChapterIds: Set<String>) async throws {
        try await database.withTransaction { connection in
            guard let current = try UpdateStore.unresolved(identity, connection),
                  current.newChapterIds.allSatisfy(completedChapterIds.contains) else { return }
            try connection.execute(
                "DELETE FROM unresolved_updates WHERE source_id = ? AND remote_book_id = ? AND revision = ?",
                [.text(identity.sourceId), .text(identity.remoteBookId), .integer(current.revision)]
            )
        }
    }

    // MARK: Internals

    static func isActive(_ lease: UpdateSessionLease, _ now: Date, _ connection: SQLiteConnection) throws -> Bool {
        !(try connection.query(
            """
            SELECT 1 FROM update_sessions WHERE session_id = ? AND state = 'RUNNING' AND lease_owner_token = ?
            AND lease_expires_at_millis > ?
            """,
            [.text(lease.sessionId), .text(lease.ownerToken), .integer(millis(now))]
        )).isEmpty
    }

    static func finishItem(
        _ sessionId: String,
        _ identity: BookIdentity,
        state: UpdateItemState,
        reason: String?,
        anchor: String?,
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            UPDATE update_session_items SET state = ?, reason = ?, anchor = ?
            WHERE session_id = ? AND source_id = ? AND remote_book_id = ? AND state = 'PENDING'
            """,
            [
                .text(state.rawValue), reason.map { SQLiteValue.text($0) } ?? .null, anchor.map { SQLiteValue.text($0) } ?? .null,
                .text(sessionId), .text(identity.sourceId), .text(identity.remoteBookId)
            ]
        )
    }

    /// Counts settle the session: once nothing is pending, every failure makes it failed, any
    /// failure or unavailable item makes it partial, and otherwise it completed.
    static func refresh(_ sessionId: String, at now: Date, _ connection: SQLiteConnection) throws {
        let rows = try connection.query(
            "SELECT state, COUNT(*) AS n FROM update_session_items WHERE session_id = ? GROUP BY state",
            [.text(sessionId)]
        )
        var counts: [UpdateItemState: Int64] = [:]
        for row in rows {
            guard let state = row["state"].string.flatMap(UpdateItemState.init(rawValue:)) else { continue }
            counts[state] = row["n"].int ?? 0
        }
        let pending = counts[.pending] ?? 0
        let total = counts.values.reduce(0, +)
        let failed = (counts[.failed] ?? 0) + (counts[.unavailable] ?? 0)
        try connection.execute(
            "UPDATE update_sessions SET completed = ?, updated = ?, failed = ? WHERE session_id = ?",
            [.integer(total - pending), .integer(counts[.updated] ?? 0), .integer(failed), .text(sessionId)]
        )
        guard pending == 0 else { return }
        try finish(sessionId, reason: nil, at: now, connection)
    }

    static func finish(_ sessionId: String, reason: String?, at now: Date, _ connection: SQLiteConnection, cancelled: Bool = false) throws {
        let rows = try connection.query(
            "SELECT state, COUNT(*) AS n FROM update_session_items WHERE session_id = ? GROUP BY state",
            [.text(sessionId)]
        )
        var counts: [UpdateItemState: Int64] = [:]
        for row in rows {
            guard let state = row["state"].string.flatMap(UpdateItemState.init(rawValue:)) else { continue }
            counts[state] = row["n"].int ?? 0
        }
        let total = counts.values.reduce(0, +)
        let failed = (counts[.failed] ?? 0) + (counts[.unavailable] ?? 0)
        let state: UpdateSessionState
        if cancelled {
            state = .cancelled
        } else if total > 0, failed == total {
            state = .failed
        } else if failed > 0 {
            state = .partial
        } else {
            state = .completed
        }
        let composed = [
            ("skipped", counts[.skipped] ?? 0), ("cancelled", counts[.cancelled] ?? 0),
            ("unavailable", counts[.unavailable] ?? 0), ("failed", counts[.failed] ?? 0)
        ].filter { $0.1 > 0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        try connection.execute(
            """
            UPDATE update_sessions SET state = ?, reason = ?, lease_expires_at_millis = NULL, lease_owner_token = NULL,
            finished_at_millis = ?, completed = ?, updated = ?, failed = ?
            WHERE session_id = ? AND state IN ('QUEUED', 'RUNNING')
            """,
            [
                .text(state.rawValue), composed.isEmpty ? (reason.map { SQLiteValue.text($0) } ?? .null) : .text(composed),
                .integer(millis(now)), .integer(total - (counts[.pending] ?? 0)), .integer(counts[.updated] ?? 0),
                .integer(failed), .text(sessionId)
            ]
        )
    }

    static func summary(from row: SQLiteRow) -> UpdateSessionSummary? {
        guard let id = row["session_id"].string,
              let trigger = row["trigger"].string.flatMap(UpdateSessionTrigger.init(rawValue:)),
              let state = row["state"].string.flatMap(UpdateSessionState.init(rawValue:)) else { return nil }
        return UpdateSessionSummary(
            sessionId: id,
            trigger: trigger,
            state: state,
            total: Int(row["total"].int ?? 0),
            completed: Int(row["completed"].int ?? 0),
            updated: Int(row["updated"].int ?? 0),
            failed: Int(row["failed"].int ?? 0),
            reason: row["reason"].string,
            cancellationRequested: row["cancellation_requested"].bool ?? false,
            startedAt: date(row["started_at_millis"].int ?? 0),
            finishedAt: row["finished_at_millis"].int.map(date)
        )
    }

    static func baseline(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> UpdateBaseline? {
        guard let row = try connection.query(
            "SELECT * FROM update_baselines WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).first, let anchor = row["anchor"].string, let chapters = row["chapters_json"].string else { return nil }
        return UpdateBaseline(
            identity: identity,
            anchor: anchor,
            chapters: decodeChapters(chapters),
            lastUpdatedDate: row["last_updated_date"].string,
            updatedAt: date(row["updated_at_millis"].int ?? 0)
        )
    }

    static func unresolved(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> UnresolvedUpdate? {
        try connection.query(
            "SELECT * FROM unresolved_updates WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).first.flatMap(unresolved(from:))
    }

    static func unresolved(from row: SQLiteRow) -> UnresolvedUpdate? {
        guard let identity = LibraryCatalog.identity(from: row), let title = row["title"].string,
              let anchor = row["anchor"].string, let chapters = row["chapters_json"].string,
              let ids = row["new_chapter_ids_json"].string else { return nil }
        return UnresolvedUpdate(
            identity: identity,
            title: title,
            anchor: anchor,
            chapters: decodeChapters(chapters),
            newChapterIds: decodeIds(ids),
            lastUpdatedDate: row["last_updated_date"].string,
            detectedAt: date(row["detected_at_millis"].int ?? 0),
            revision: row["revision"].int ?? 0
        )
    }

    static func bookExcluded(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> Bool {
        !(try connection.query(
            "SELECT 1 FROM update_book_exclusions WHERE source_id = ? AND remote_book_id = ?",
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        )).isEmpty
    }

    static func sourceExcluded(_ sourceId: String, _ connection: SQLiteConnection) throws -> Bool {
        !(try connection.query("SELECT 1 FROM update_source_exclusions WHERE source_id = ?", [.text(sourceId)])).isEmpty
    }

    static func purgeExpiredUndos(_ now: Date, _ connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM update_ignore_undos WHERE expires_at_millis <= ?", [.integer(millis(now))])
    }

    static func mergedIds(_ prior: [String], _ new: [String]) -> [String] {
        var seen = Set<String>()
        return (prior + new).filter { seen.insert($0).inserted }
    }

    static func encodeChapters(_ chapters: [UpdateCheckChapter]) -> String {
        let value = JSONValue.array(chapters.map { .object(["id": .string($0.chapterId), "title": .string($0.title)]) })
        return (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeChapters(_ text: String) -> [UpdateCheckChapter] {
        guard let rows = try? JSONValue.decode(Data(text.utf8)).arrayValue else { return [] }
        return rows.compactMap { row in
            guard let object = row.objectValue, let id = object.string("id"), let title = object.string("title") else { return nil }
            return try? UpdateCheckChapter(chapterId: id, title: title)
        }
    }

    static func encodeIds(_ ids: [String]) -> String {
        (try? JSONValue.array(ids.map(JSONValue.string)).encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeIds(_ text: String) -> [String] {
        (try? JSONValue.decode(Data(text.utf8)).arrayValue)?.compactMap(\.stringValue) ?? []
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }
}
