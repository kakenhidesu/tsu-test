// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// One lease-checked remote library snapshot accepted into local persistence.
public struct RemoteLibraryMergeRequest: Sendable {
    public let sourceId: String
    public let books: [LibraryBook]
    public let expectedVersion: String
    public let expectedCapabilityFingerprint: String
    public let expectedGeneration: Int64
    public let importedAt: Date

    public init(
        sourceId: String,
        books: [LibraryBook],
        expectedVersion: String,
        expectedCapabilityFingerprint: String,
        expectedGeneration: Int64,
        importedAt: Date
    ) {
        self.sourceId = sourceId
        self.books = books
        self.expectedVersion = expectedVersion
        self.expectedCapabilityFingerprint = expectedCapabilityFingerprint
        self.expectedGeneration = expectedGeneration
        self.importedAt = importedAt
    }
}

/// Durable identity and package lease for one user-authorised remote add.
public struct RemoteAddRequest: Sendable {
    public let book: LibraryBook
    public let packageDigest: String
    public let packageVersion: String
    public let capabilitySetFingerprint: String
    public let registryGeneration: Int64
    public let startedAt: Date

    public init(
        book: LibraryBook,
        packageDigest: String,
        packageVersion: String,
        capabilitySetFingerprint: String,
        registryGeneration: Int64,
        startedAt: Date
    ) {
        self.book = book
        self.packageDigest = packageDigest
        self.packageVersion = packageVersion
        self.capabilitySetFingerprint = capabilitySetFingerprint
        self.registryGeneration = registryGeneration
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
                capability_set_fingerprint, approved_origin, add_writeback_enabled, first_import_prompt_dismissed)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(policy.sourceId), .text(policy.trustedPublisherFingerprint),
                    .text(policy.capabilitySetFingerprint), .text(policy.approvedOrigin),
                    .integer(policy.addWritebackEnabled ? 1 : 0),
                    .integer(policy.firstImportPromptDismissed ? 1 : 0)
                ]
            )
        }
    }

    /// The lease is checked before and after the merge, so a package or capability change mid-import
    /// aborts instead of admitting rows granted under different terms.
    @discardableResult
    public func merge(_ request: RemoteLibraryMergeRequest) async throws -> Int {
        guard isNonBlank(request.sourceId) else {
            throw DatabaseError.invariantViolated("Remote library source is required")
        }
        guard Set(request.books.map(\.identity)).count == request.books.count else {
            throw DatabaseError.invariantViolated("Duplicate remote library identity")
        }
        guard request.books.allSatisfy({ $0.identity.sourceId == request.sourceId }) else {
            throw DatabaseError.invariantViolated("Remote library source mismatch")
        }
        return try await database.withTransaction { connection in
            guard try RemoteLibraryStore.leaseValid(request, connection) else {
                throw DatabaseError.invariantViolated("Source changed before remote merge")
            }
            var added = 0
            for book in request.books {
                try LibraryCatalog.saveBook(book, connection)
                try connection.execute(
                    """
                    INSERT OR IGNORE INTO library_entries (source_id, remote_book_id, added_at_epoch_second,
                    added_at_nano, rating, read_later, display_order)
                    VALUES (?, ?, ?, ?, NULL, 0, 2147483647)
                    """,
                    [
                        .text(book.identity.sourceId), .text(book.identity.remoteBookId),
                        .integer(request.importedAt.epochSecond), .integer(Int64(request.importedAt.nanoOfSecond))
                    ]
                )
                if connection.changes != 0 { added += 1 }
            }
            guard try RemoteLibraryStore.leaseValid(request, connection) else {
                throw DatabaseError.invariantViolated("Source changed during remote merge")
            }
            return added
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

    @discardableResult
    public func setAddWritebackEnabled(
        sourceId: String,
        capabilityFingerprint: String,
        enabled: Bool
    ) async throws -> Bool {
        try await database.withTransaction { connection in
            try connection.execute(
                """
                UPDATE source_remote_policy SET add_writeback_enabled = ?
                WHERE source_id = ? AND capability_set_fingerprint = ?
                """,
                [.integer(enabled ? 1 : 0), .text(sourceId), .text(capabilityFingerprint)]
            )
            return connection.changes == 1
        }
    }

    public func beginRemoteAdd(_ request: RemoteAddRequest) async throws -> String {
        try await database.withTransaction { connection in
            let identity = request.book.identity
            try LibraryCatalog.saveBook(request.book, connection)
            try connection.execute(
                """
                INSERT OR IGNORE INTO library_entries (source_id, remote_book_id, added_at_epoch_second,
                added_at_nano, rating, read_later, display_order)
                VALUES (?, ?, ?, ?, NULL, 0, 2147483647)
                """,
                [
                    .text(identity.sourceId), .text(identity.remoteBookId),
                    .integer(request.startedAt.epochSecond), .integer(Int64(request.startedAt.nanoOfSecond))
                ]
            )
            let active = try connection.query(
                """
                SELECT id FROM remote_library_reconciliation
                WHERE source_id = ? AND remote_book_id = ? AND state IN ('PENDING_USER_ACTION','IN_FLIGHT') LIMIT 1
                """,
                [.text(identity.sourceId), .text(identity.remoteBookId)]
            )
            guard active.isEmpty else { throw DatabaseError.invariantViolated("Remote add already active") }
            let id = UUID().uuidString
            try connection.execute(
                """
                INSERT INTO remote_library_reconciliation (id, source_id, remote_book_id, package_digest,
                package_version, capability_set_fingerprint, registry_generation, state,
                created_at_epoch_second, updated_at_epoch_second, diagnostic_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                [
                    .text(id), .text(identity.sourceId), .text(identity.remoteBookId),
                    .text(request.packageDigest), .text(request.packageVersion),
                    .text(request.capabilitySetFingerprint), .integer(request.registryGeneration),
                    .text(RemoteReconciliationState.pendingUserAction.rawValue),
                    .integer(request.startedAt.epochSecond), .integer(request.startedAt.epochSecond)
                ]
            )
            return id
        }
    }

    @discardableResult
    public func transitionRemoteAdd(
        id: String,
        expected: RemoteReconciliationState,
        next: RemoteReconciliationState,
        now: Date,
        diagnosticId: String? = nil
    ) async throws -> Bool {
        guard RemoteLibraryStore.allowedNextStates(expected).contains(next) else {
            throw DatabaseError.invariantViolated(
                "Invalid reconciliation transition: \(expected.rawValue) -> \(next.rawValue)"
            )
        }
        return try await database.withTransaction { connection in
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

    static func allowedNextStates(_ state: RemoteReconciliationState) -> Set<RemoteReconciliationState> {
        switch state {
        case .pendingUserAction: return [.inFlight, .cancelled]
        case .inFlight: return [.confirmed, .unresolved]
        case .confirmed, .unresolved, .cancelled: return []
        }
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
            firstImportPromptDismissed: row["first_import_prompt_dismissed"].bool ?? false
        )
    }

    private static func leaseValid(
        _ request: RemoteLibraryMergeRequest,
        _ connection: SQLiteConnection
    ) throws -> Bool {
        guard let availability = try availability(request.sourceId, connection),
              let policy = try policy(request.sourceId, connection) else { return false }
        return availability.available
            && availability.verifiedVersion == request.expectedVersion
            && availability.generation == request.expectedGeneration
            && policy.capabilitySetFingerprint == request.expectedCapabilityFingerprint
    }
}
