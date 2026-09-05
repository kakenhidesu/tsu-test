// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// RFC 8785 JSON canonicalisation. Signatures are computed over these bytes, so the output must be
/// byte-identical to the producer's canonical form (`tsuyomi-extensions/tools/build-fixture.mjs`):
/// keys sorted by UTF-16 code unit, no whitespace, ECMAScript number and string serialisation.
public enum Rfc8785 {
    public static func canonicalize(_ value: JSONValue) throws -> Data {
        var output = ""
        try append(value, into: &output)
        return Data(output.utf8)
    }

    private static func append(_ value: JSONValue, into output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .int(let number):
            output += String(number)
        case .double(let number):
            output += try serialize(number)
        case .string(let text):
            output += escape(text)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                try append(item, into: &output)
            }
            output += "]"
        case .object(let fields):
            output += "{"
            for (index, key) in CanonicalOrder.sorted(fields.keys).enumerated() {
                if index > 0 { output += "," }
                output += escape(key)
                output += ":"
                try append(fields[key] ?? .null, into: &output)
            }
            output += "}"
        }
    }

    /// ECMAScript `Number::toString`. Every value the protocol carries is an exact integer, so a
    /// value that is not is rejected rather than serialised with a platform-specific spelling.
    private static func serialize(_ number: Double) throws -> String {
        guard number.isFinite else { throw ProtocolError.malformedJson }
        guard number == number.rounded(), number.magnitude < 1e21 else { throw ProtocolError.malformedJson }
        return String(Int64(number))
    }

    private static func escape(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{09}": output += "\\t"
            case "\u{0A}": output += "\\n"
            case "\u{0C}": output += "\\f"
            case "\u{0D}": output += "\\r"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }
}
