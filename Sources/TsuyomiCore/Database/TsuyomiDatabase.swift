// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SQLite3

/// Owns the raw handle so the connection is closed exactly once, when the database is released.
final class SQLiteHandle {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) { self.pointer = pointer }

    deinit { sqlite3_close_v2(pointer) }
}

/// The single SQLite handle for the library database. Every statement runs on this actor, so
/// callers never share a connection across tasks.
public actor TsuyomiDatabase {
    private let handleBox: SQLiteHandle
    private var handle: OpaquePointer { handleBox.pointer }
    private var changeSequence: Int64 = 0
    private var observers: [UUID: @Sendable (Int64) -> Void] = [:]

    public static let schemaVersion: Int32 = 10

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(status)
        }
        self.handleBox = SQLiteHandle(pointer: handle)
        let connection = SQLiteConnection(handle: handle)
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.execute("PRAGMA busy_timeout=5000")
        let current = try connection.query("PRAGMA user_version").first?["user_version"].int ?? 0
        guard current <= Int64(TsuyomiDatabase.schemaVersion) else {
            throw DatabaseError.invariantViolated("unsupported schema version \(current)")
        }
        guard current < Int64(TsuyomiDatabase.schemaVersion) else { return }
        // Each migration is its own transaction and stamps its own version, so an interrupted
        // upgrade resumes from the last version that fully landed instead of replaying a step.
        try connection.execute("PRAGMA foreign_keys=OFF")
        defer { try? connection.execute("PRAGMA foreign_keys=ON") }
        if current == 0 {
            try TsuyomiDatabase.apply(TsuyomiSchema.version4, version: 4, connection)
        }
        for migration in TsuyomiSchema.migrations where Int64(migration.version) > max(current, 4) {
            try TsuyomiDatabase.apply(migration.statements, version: migration.version, connection)
        }
    }

    private static func apply(_ statements: [String], version: Int32, _ connection: SQLiteConnection) throws {
        try connection.execute("BEGIN")
        do {
            for statement in statements { try connection.execute(statement) }
            try connection.execute("PRAGMA user_version=\(version)")
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// An in-memory database for tests and for the deterministic query fixtures.
    public static func inMemory() throws -> TsuyomiDatabase {
        try TsuyomiDatabase(path: ":memory:")
    }

    public func read<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) throws -> T {
        try body(SQLiteConnection(handle: handle))
    }

    public func withTransaction<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) throws -> T {
        let connection = SQLiteConnection(handle: handle)
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let value = try body(connection)
            try connection.execute("COMMIT")
            bumpChangeSequence()
            return value
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// One database-level sequence drives every repository snapshot stream; observers re-query
    /// rather than diff rows, which keeps read models honest about the committed state.
    public nonisolated func observeChanges() -> AsyncStream<Int64> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addObserver(id) { continuation.yield($0) } }
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    public func bumpChangeSequence() {
        changeSequence += 1
        for observer in observers.values { observer(changeSequence) }
    }

    private func addObserver(_ id: UUID, _ sink: @escaping @Sendable (Int64) -> Void) {
        observers[id] = sink
        sink(changeSequence)
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
