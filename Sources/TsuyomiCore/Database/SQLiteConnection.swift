// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SQLite3

public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int: Int64? { if case .integer(let value) = self { return value } else { return nil } }
    public var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
    public var string: String? { if case .text(let value) = self { return value } else { return nil } }
    public var data: Data? { if case .blob(let value) = self { return value } else { return nil } }
    public var bool: Bool? { int.map { $0 != 0 } }
}

public enum DatabaseError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case statementFailed(String)
    case constraintViolated(String)
    case invariantViolated(String)
}

public struct SQLiteRow: Sendable {
    private let columns: [String: Int]
    private let values: [SQLiteValue]

    init(columns: [String: Int], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    public subscript(name: String) -> SQLiteValue {
        columns[name].map { values[$0] } ?? .null
    }
}

/// A live SQLite handle. It is only reachable inside a `TsuyomiDatabase` closure, so every statement
/// runs on the database actor and no handle escapes to another task.
public struct SQLiteConnection {
    let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        _ = try run(sql, bindings) { _ in false }
    }

    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var rows: [SQLiteRow] = []
        var columns: [String: Int] = [:]
        _ = try run(sql, bindings) { statement in
            if columns.isEmpty {
                for index in 0..<sqlite3_column_count(statement) {
                    columns[String(cString: sqlite3_column_name(statement, index))] = Int(index)
                }
            }
            var values: [SQLiteValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                values.append(SQLiteConnection.value(statement, index))
            }
            rows.append(SQLiteRow(columns: columns, values: values))
            return true
        }
        return rows
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    private func run(
        _ sql: String,
        _ bindings: [SQLiteValue],
        _ onRow: (OpaquePointer) -> Bool
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.statementFailed(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .null: status = sqlite3_bind_null(statement, index)
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .real(let value): status = sqlite3_bind_double(statement, index, value)
            case .text(let value): status = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .blob(let value):
                status = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw DatabaseError.statementFailed(lastMessage()) }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if !onRow(statement) { return true }
            case SQLITE_DONE:
                return true
            case SQLITE_CONSTRAINT:
                throw DatabaseError.constraintViolated(lastMessage())
            default:
                throw DatabaseError.statementFailed(lastMessage())
            }
        }
    }

    private static func value(_ statement: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    private func lastMessage() -> String {
        guard let message = sqlite3_errmsg(handle) else { return "sqlite error" }
        return String(cString: message)
    }
}
