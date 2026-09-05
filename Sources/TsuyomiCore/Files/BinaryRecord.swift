// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Length-prefixed big-endian encoding shared by every host-private record file (credentials,
/// verified sessions, response cache). Records are self-delimiting so a truncated or padded file is
/// rejected instead of being partially trusted.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) { data.append(value) }

    mutating func write(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func write(_ value: Int32) { write(UInt32(bitPattern: value)) }

    mutating func write(bytes: Data) {
        write(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func write(text: String) { write(bytes: Data(text.utf8)) }
}

enum BinaryDecodeError: Error, Equatable {
    case malformed
}

struct BinaryReader {
    private let data: Data
    private var cursor: Int

    init(_ data: Data) {
        self.data = data
        self.cursor = 0
    }

    var remaining: Int { data.count - cursor }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw BinaryDecodeError.malformed }
        defer { cursor += 1 }
        return data[data.startIndex + cursor]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = try readUInt8()
        let low = try readUInt8()
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = value << 8 | UInt32(try readUInt8()) }
        return value
    }

    mutating func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    mutating func readBytes(maximum: Int) throws -> Data {
        let count = Int(try readUInt32())
        guard count >= 0, count <= maximum, count <= remaining else { throw BinaryDecodeError.malformed }
        defer { cursor += count }
        let start = data.startIndex + cursor
        return data[start..<(start + count)]
    }

    mutating func readText(maximum: Int) throws -> String {
        guard let text = String(data: try readBytes(maximum: maximum), encoding: .utf8) else {
            throw BinaryDecodeError.malformed
        }
        return text
    }

    func requireExhausted() throws {
        guard remaining == 0 else { throw BinaryDecodeError.malformed }
    }
}
