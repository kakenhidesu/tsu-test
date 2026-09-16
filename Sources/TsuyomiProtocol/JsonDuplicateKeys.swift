// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Codable decoding keeps the last of two equal keys silently, so a signed document is scanned
/// for repeated keys before anything in it is trusted: `hxp-package-v1` and
/// `tsuyomi-repository-v1` both reject duplicate JSON keys, because the bytes that were signed and
/// the value that was read must be the same document.
public enum JsonDuplicateKeys {
    public static func found(in data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        var objects: [Set<String>?] = []
        var expectingKey = false
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "{"):
                objects.append(Set())
                expectingKey = true
                index += 1
            case UInt8(ascii: "["):
                objects.append(nil)
                expectingKey = false
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !objects.isEmpty { objects.removeLast() }
                expectingKey = false
                index += 1
            case UInt8(ascii: ","):
                expectingKey = objects.last.flatMap { $0 } != nil
                index += 1
            case UInt8(ascii: "\""):
                let (text, end) = string(bytes, from: index + 1)
                if expectingKey, !objects.isEmpty, var keys = objects[objects.count - 1] {
                    let inserted = keys.insert(text).inserted
                    objects[objects.count - 1] = keys
                    if !inserted { return true }
                }
                expectingKey = false
                index = end
            default:
                index += 1
            }
        }
        return false
    }

    /// Reads a JSON string starting after its opening quote and returns its unescaped text with the
    /// offset after the closing quote. Two spellings of one key compare equal after unescaping.
    private static func string(_ bytes: [UInt8], from start: Int) -> (String, Int) {
        var output: [UInt8] = []
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { return (String(decoding: output, as: UTF8.self), index + 1) }
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                output.append(byte)
                index += 1
                continue
            }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "u"):
                var value = hex(bytes, at: index)
                index += 4
                if (0xD800...0xDBFF).contains(value), index + 5 < bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let low = hex(bytes, at: index + 2)
                    if (0xDC00...0xDFFF).contains(low) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }
                }
                let scalar = Unicode.Scalar(value) ?? Unicode.Scalar(0xFFFD)
                output.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: output.append(escape)
            }
        }
        return (String(decoding: output, as: UTF8.self), index)
    }

    private static func hex(_ bytes: [UInt8], at start: Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 where start + offset < bytes.count {
            let byte = bytes[start + offset]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: return 0xFFFD
            }
            value = value << 4 | digit
        }
        return value
    }
}
