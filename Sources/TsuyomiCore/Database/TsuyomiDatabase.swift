// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SQLite3

/// The single SQLite handle for the library database. Every statement runs on this actor, so
/// callers never share a connection across tasks.
public actor TsuyomiDatabase {
    private let handle: OpaquePointer
    private var changeSequence: Int64 = 0
    private var observers: [UUID: @Sendable (Int64) -> Void] = [:]

    public static let schemaVersion: Int32 = 4

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.openFailed(status)
        }
        self.handle = handle
        let connection = SQLiteConnection(handle: handle)
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.execute("PRAGMA busy_timeout=5000")
        let current = try connection.query("PRAGMA user_version").first?["user_version"].int ?? 0
        if current == 0 {
            try connection.execute("BEGIN")
            do {
                for statement in TsuyomiSchema.version4 { try connection.execute(statement) }
                try connection.execute("PRAGMA user_version=\(TsuyomiDatabase.schemaVersion)")
                try connection.execute("COMMIT")
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
        } else if current != Int64(TsuyomiDatabase.schemaVersion) {
            throw DatabaseError.invariantViolated("unsupported schema version \(current)")
        }
    }

    /// An in-memory database for tests and for the deterministic query fixtures.
    public static func inMemory() throws -> TsuyomiDatabase {
        try TsuyomiDatabase(path: ":memory:")
    }

    deinit {
        sqlite3_close_v2(handle)
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
