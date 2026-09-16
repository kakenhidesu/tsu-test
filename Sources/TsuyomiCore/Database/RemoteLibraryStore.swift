// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Durable identity and package lease for one user-authorised website write.
public struct RemoteMutationRequest: Sendable {
    public let book: LibraryBook
    public let operation: RemoteWriteOperation
    public let targetId: String?
    public let targetName: String?
    public let packageDigest: String
    public let packageVersion: String
    public let capabilitySetFingerprint: String
    public let registryGeneration: Int64
    public let retryingUnresolvedId: String?
    public let startedAt: Date

    public init(
        book: LibraryBook,
        operation: RemoteWriteOperation,
        targetId: String? = nil,
        targetName: String? = nil,
        packageDigest: String,
        packageVersion: String,
        capabilitySetFingerprint: String,
        registryGeneration: Int64,
        retryingUnresolvedId: String? = nil,
        startedAt: Date
    ) {
        self.book = book
        self.operation = operation
        self.targetId = targetId
        self.targetName = targetName
        self.packageDigest = packageDigest
        self.packageVersion = packageVersion
        self.capabilitySetFingerprint = capabilitySetFingerprint
        self.registryGeneration = registryGeneration
        self.retryingUnresolvedId = retryingUnresolvedId
        self.startedAt = startedAt
    }
}

/// `source_availability`, `source_remote_policy`, and `remote_library_reconciliation`.
public struct RemoteLibraryStore: Sendable {
    let database: TsuyomiDatabase

    public init(database: TsuyomiDatabase) {
        self.database = database
    }

    public func setSourceAvailability(
        sourceId: String,
        version: String?,
        available: Bool,
        generation: Int64
    ) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO source_availability (source_id, verified_version, available, generation)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(sourceId), version.map { SQLiteValue.text($0) } ?? .null,
                    .integer(available ? 1 : 0), .integer(generation)
                ]
            )
        }
    }

    /// Cold-start reconciliation: every source whose archive is gone becomes dormant once. The
    /// `available = 1` guard is what keeps a dormant source from being re-invalidated, and its
    /// generation from churning, on every launch.
    public func markMissingSourcesUnavailable(installed: Set<String>) async throws {
        try await database.withTransaction { connection in
            let rows = try connection.query("SELECT source_id FROM source_availability WHERE available = 1")
            for row in rows {
                guard let sourceId = row["source_id"].string, !installed.contains(sourceId) else { continue }
                try connection.execute(
                    "UPDATE source_availability SET available = 0, generation = generation + 1 WHERE source_id = ? AND available = 1",
                    [.text(sourceId)]
                )
            }
        }
    }

    public func sourceAvailability(_ sourceId: String) async throws -> SourceAvailability? {
        try await database.read { try RemoteLibraryStore.availability(sourceId, $0) }
    }

    public func sourceRemotePolicy(_ sourceId: String) async throws -> SourceRemotePolicy? {
        try await database.read { try RemoteLibraryStore.policy(sourceId, $0) }
    }

    public func saveSourceRemotePolicy(_ policy: SourceRemotePolicy) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                INSERT OR REPLACE INTO source_remote_policy (source_id, trusted_publisher_fingerprint,
                capability_set_fingerprint, approved_origin, add_writeback_enabled, first_import_prompt_dismissed,
                remove_writeback_enabled, move_writeback_enabled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(policy.sourceId), .text(policy.trustedPublisherFingerprint),
                    .text(policy.capabilitySetFingerprint), .text(policy.approvedOrigin),
                    .integer(policy.addWritebackEnabled ? 1 : 0),
                    .integer(policy.firstImportPromptDismissed ? 1 : 0),
                    .integer(policy.removeWritebackEnabled ? 1 : 0),
                    .integer(policy.moveWritebackEnabled ? 1 : 0)
                ]
            )
        }
    }

    @discardableResult
    public func dismissFirstRemoteImportPrompt(
        sourceId: String,
        capabilityFingerprint: String
    ) async throws -> Bool {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE source_remote_policy SET first_import_prompt_dismissed = 1
                WHERE source_id = ? AND capability_set_fingerprint = ? AND first_import_prompt_dismissed = 0
                """,
                [.text(sourceId), .text(capabilityFingerprint)]
            )
            return connection.changes == 1
        }
    }

    /// One receipt per operation, written only under the capability fingerprint it was given for:
    /// a manifest that changes what a write can do silently retires the consent.
    @discardableResult
    public func setWritebackEnabled(
        _ operation: RemoteWriteOperation,
        sourceId: String,
        capabilityFingerprint: String,
        enabled: Bool
    ) async throws -> Bool {
        let column: String
        switch operation {
        case .add: column = "add_writeback_enabled"
        case .remove: column = "remove_writeback_enabled"
        case .move: column = "move_writeback_enabled"
        }
        return try await database.withTransaction { connection in
            try connection.execute(
                "UPDATE source_remote_policy SET \(column) = ? WHERE source_id = ? AND capability_set_fingerprint = ?",
                [.integer(enabled ? 1 : 0), .text(sourceId), .text(capabilityFingerprint)]
            )
            return connection.changes == 1
        }
    }

    /// Opens one attempt. A second attempt while any row still blocks is refused unless it retries
    /// exactly the unresolved row for the same operation; a website book never gets a library entry
    /// from here — pinning is the reader's own act.
    public func beginRemoteMutation(_ request: RemoteMutationRequest) async throws -> String {
        try await database.withTransaction { connection in
            let identity = request.book.identity
            try RemoteMirrorStore.mergeBook(request.book, connection)
            let blocking = try RemoteLibraryStore.records(identity, connection).filter {
                [.pendingUserAction, .inFlight, .unresolved].contains($0.state)
            }
            if let retrying = request.retryingUnresolvedId {
                guard blocking.count == 1, let current = blocking.first, current.id == retrying,
                      current.state == .unresolved, current.operation == request.operation else {
                    throw DatabaseError.invariantViolated("Remote mutation is not retryable")
                }
            } else if !blocking.isEmpty {
                throw DatabaseError.invariantViolated("Remote mutation already active")
            }
            let id = UUID().uuidString
            try connection.execute(
                """
                INSERT INTO remote_library_reconciliation (id, source_id, remote_book_id, package_digest,
                package_version, capability_set_fingerprint, registry_generation, state,
                created_at_epoch_second, updated_at_epoch_second, diagnostic_id, operation, target_id, target_name)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                """,
                [
                    .text(id), .text(identity.sourceId), .text(identity.remoteBookId),
                    .text(request.packageDigest), .text(request.packageVersion),
                    .text(request.capabilitySetFingerprint), .integer(request.registryGeneration),
                    .text(RemoteReconciliationState.pendingUserAction.rawValue),
                    .integer(request.startedAt.epochSecond), .integer(request.startedAt.epochSecond),
                    .text(request.operation.rawValue),
                    request.targetId.map { SQLiteValue.text($0) } ?? .null,
                    request.targetName.map { SQLiteValue.text($0) } ?? .null
                ]
            )
            return id
        }
    }

    @discardableResult
    public func transitionRemoteMutation(
        id: String,
        expected: RemoteReconciliationState,
        next: RemoteReconciliationState,
        now: Date,
        diagnosticId: String? = nil
    ) async throws -> Bool {
        try await database.withTransaction { connection in
            guard let record = try RemoteLibraryStore.record(id, connection) else { return false }
            guard RemoteLibraryStore.allowedNextStates(expected, operation: record.operation).contains(next) else {
                throw DatabaseError.invariantViolated(
                    "Invalid reconciliation transition: \(expected.rawValue) -> \(next.rawValue)"
                )
            }
            try connection.execute(
                """
                UPDATE remote_library_reconciliation SET state = ?, updated_at_epoch_second = ?, diagnostic_id = ?
                WHERE id = ? AND state = ?
                """,
                [
                    .text(next.rawValue), .integer(now.epochSecond),
                    diagnosticId.map { SQLiteValue.text($0) } ?? .null,
                    .text(id), .text(expected.rawValue)
                ]
            )
            return connection.changes == 1
        }
    }

    /// A retry that the website answered closes the whole unresolved chain for that operation: the
    /// site has now said what happened to every earlier attempt too.
    public func confirmUnresolvedMutations(
        _ identity: BookIdentity,
        operation: RemoteWriteOperation,
        now: Date
    ) async throws {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE remote_library_reconciliation SET state = ?, updated_at_epoch_second = ?
                WHERE source_id = ? AND remote_book_id = ? AND operation = ? AND state = ?
                """,
                [
                    .text(RemoteReconciliationState.confirmed.rawValue), .integer(now.epochSecond),
                    .text(identity.sourceId), .text(identity.remoteBookId), .text(operation.rawValue),
                    .text(RemoteReconciliationState.unresolved.rawValue)
                ]
            )
        }
    }

    public func latestReconciliation(_ identity: BookIdentity) async throws -> RemoteReconciliationRecord? {
        try await database.read { try RemoteLibraryStore.records(identity, $0).first }
    }

    public func reconciliation(id: String) async throws -> RemoteReconciliationRecord? {
        try await database.read { try RemoteLibraryStore.record(id, $0) }
    }

    /// `CANCELLED` is reachable from `UNRESOLVED` only for a move or removal: an add the website may
    /// already have applied cannot be declared undone by this side.
    static func allowedNextStates(
        _ state: RemoteReconciliationState,
        operation: RemoteWriteOperation
    ) -> Set<RemoteReconciliationState> {
        switch state {
        case .pendingUserAction: return [.inFlight, .cancelled]
        case .inFlight: return [.confirmed, .unresolved]
        case .unresolved: return operation == .add ? [.inFlight, .confirmed] : [.inFlight, .confirmed, .cancelled]
        case .confirmed, .cancelled: return []
        }
    }

    static func records(_ identity: BookIdentity, _ connection: SQLiteConnection) throws -> [RemoteReconciliationRecord] {
        try connection.query(
            """
            SELECT * FROM remote_library_reconciliation WHERE source_id = ? AND remote_book_id = ?
            ORDER BY rowid DESC
            """,
            [.text(identity.sourceId), .text(identity.remoteBookId)]
        ).compactMap(RemoteLibraryStore.record(from:))
    }

    static func record(_ id: String, _ connection: SQLiteConnection) throws -> RemoteReconciliationRecord? {
        try connection.query("SELECT * FROM remote_library_reconciliation WHERE id = ?", [.text(id)])
            .first.flatMap(RemoteLibraryStore.record(from:))
    }

    private static func record(from row: SQLiteRow) -> RemoteReconciliationRecord? {
        guard let id = row["id"].string, let identity = LibraryCatalog.identity(from: row),
              let operation = row["operation"].string.flatMap(RemoteWriteOperation.init(rawValue:)),
              let state = row["state"].string.flatMap(RemoteReconciliationState.init(rawValue:)) else { return nil }
        return RemoteReconciliationRecord(
            id: id,
            identity: identity,
            operation: operation,
            state: state,
            targetId: row["target_id"].string,
            targetName: row["target_name"].string,
            diagnosticId: row["diagnostic_id"].string,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at_epoch_second"].int ?? 0)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at_epoch_second"].int ?? 0))
        )
    }

    static func availability(_ sourceId: String, _ connection: SQLiteConnection) throws -> SourceAvailability? {
        guard let row = try connection.query(
            "SELECT * FROM source_availability WHERE source_id = ?",
            [.text(sourceId)]
        ).first, let id = row["source_id"].string else { return nil }
        return SourceAvailability(
            sourceId: id,
            verifiedVersion: row["verified_version"].string,
            available: row["available"].bool ?? false,
            generation: row["generation"].int ?? 0
        )
    }

    static func policy(_ sourceId: String, _ connection: SQLiteConnection) throws -> SourceRemotePolicy? {
        guard let row = try connection.query(
            "SELECT * FROM source_remote_policy WHERE source_id = ?",
            [.text(sourceId)]
        ).first,
            let id = row["source_id"].string,
            let publisher = row["trusted_publisher_fingerprint"].string,
            let capability = row["capability_set_fingerprint"].string,
            let origin = row["approved_origin"].string else { return nil }
        return SourceRemotePolicy(
            sourceId: id,
            trustedPublisherFingerprint: publisher,
            capabilitySetFingerprint: capability,
            approvedOrigin: origin,
            addWritebackEnabled: row["add_writeback_enabled"].bool ?? false,
            firstImportPromptDismissed: row["first_import_prompt_dismissed"].bool ?? false,
            removeWritebackEnabled: row["remove_writeback_enabled"].bool ?? false,
            moveWritebackEnabled: row["move_writeback_enabled"].bool ?? false
        )
    }

    static func leaseValid(
        sourceId: String,
        version: String,
        capabilityFingerprint: String,
        generation: Int64,
        _ connection: SQLiteConnection
    ) throws -> Bool {
        guard let availability = try availability(sourceId, connection),
              let policy = try policy(sourceId, connection) else { return false }
        return availability.available
            && availability.verifiedVersion == version
            && availability.generation == generation
            && policy.capabilitySetFingerprint == capabilityFingerprint
    }
}
