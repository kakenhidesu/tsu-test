// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A parsed JSON tree. Protocol codecs decode into it so that unknown-field rejection, lenient
/// legacy parsing, and canonical re-encoding all operate on exactly the bytes that arrived.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProtocolError.malformedJson
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }

    /// JSON has one number type; a protocol integer field accepts any number with no fractional part.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return value.rounded() == value && value.magnitude < 9.2e18 ? Int(value) : nil
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var isNonEmpty: Bool {
        switch self {
        case .object(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .string(let value): return value.contains { !$0.isWhitespace }
        case .bool, .int, .double: return true
        case .null: return false
        }
    }
}

public extension [String: JSONValue] {
    func string(_ name: String) -> String? { self[name]?.stringValue }
    func int(_ name: String) -> Int? { self[name]?.intValue }
    func double(_ name: String) -> Double? { self[name]?.doubleValue }
    func bool(_ name: String) -> Bool? { self[name]?.boolValue }
    func object(_ name: String) -> [String: JSONValue]? { self[name]?.objectValue }
    func array(_ name: String) -> [JSONValue]? { self[name]?.arrayValue }
    func instant(_ name: String) -> Date? { string(name).flatMap(ProtocolTimestamp.parse) }

    /// The first present value among `names`, mirroring the legacy-field fallbacks of older backups.
    func firstString(_ names: String...) -> String? { names.lazy.compactMap { self.string($0) }.first }

    func hasOnly(_ allowed: Set<String>) -> Bool { keys.allSatisfy(allowed.contains) }
}
