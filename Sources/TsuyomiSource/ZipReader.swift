// SPDX-License-Identifier: AGPL-3.0-only

import Compression
import Foundation

public enum ZipReadError: Error, Equatable, Sendable {
    case malformedArchive
    case unsupportedCompression
    case encryptedEntry
    case symlinkEntry
    case unsafePath
    case duplicateEntry
    case fileTooLarge
    case compressionRatioExceeded
    case checksumMismatch
}

public struct ZipEntryHeader: Hashable, Sendable {
    public let name: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    let method: UInt16
    let crc32: UInt32
    let localHeaderOffset: Int
}

/// Minimal ZIP reader: it parses only the central directory, supports only stored and raw-deflate
/// entries, and validates every limit before a single byte is inflated (hxp-package-v1 §Archive).
public struct ZipReader {
    private let bytes: Data
    public let entries: [ZipEntryHeader]

    public init(_ bytes: Data, maximumFileBytes: Int, maximumFileCount: Int) throws {
        self.bytes = bytes
        guard bytes.count >= 22 else { throw ZipReadError.malformedArchive }
        guard let directory = ZipReader.findEndOfCentralDirectory(bytes) else {
            throw ZipReadError.malformedArchive
        }
        guard directory.entryCount <= maximumFileCount else { throw ZipReadError.malformedArchive }

        var parsed: [ZipEntryHeader] = []
        var seen = Set<String>()
        var cursor = directory.offset
        for _ in 0..<directory.entryCount {
            guard ZipReader.readUInt32(bytes, cursor) == 0x0201_4B50 else { throw ZipReadError.malformedArchive }
            guard cursor + 46 <= bytes.count else { throw ZipReadError.malformedArchive }
            let generalPurpose = ZipReader.readUInt16(bytes, cursor + 8)
            let method = ZipReader.readUInt16(bytes, cursor + 10)
            let crc32 = ZipReader.readUInt32(bytes, cursor + 16)
            let compressedSize = Int(ZipReader.readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(ZipReader.readUInt32(bytes, cursor + 24))
            let nameLength = Int(ZipReader.readUInt16(bytes, cursor + 28))
            let extraLength = Int(ZipReader.readUInt16(bytes, cursor + 30))
            let commentLength = Int(ZipReader.readUInt16(bytes, cursor + 32))
            let externalAttributes = ZipReader.readUInt32(bytes, cursor + 38)
            let localHeaderOffset = Int(ZipReader.readUInt32(bytes, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipReadError.malformedArchive }
            guard let name = String(
                data: bytes.subdata(in: (bytes.startIndex + nameStart)..<(bytes.startIndex + nameStart + nameLength)),
                encoding: .utf8
            ) else { throw ZipReadError.unsafePath }

            if generalPurpose & 0x1 != 0 { throw ZipReadError.encryptedEntry }
            if (externalAttributes >> 16) & 0xF000 == 0xA000 { throw ZipReadError.symlinkEntry }
            if method != 0 && method != 8 { throw ZipReadError.unsupportedCompression }
            guard ZipReader.isSafeArchivePath(name) else { throw ZipReadError.unsafePath }
            guard seen.insert(name).inserted else { throw ZipReadError.duplicateEntry }
            guard uncompressedSize <= maximumFileBytes else { throw ZipReadError.fileTooLarge }
            guard compressedSize >= 0, localHeaderOffset >= 0 else { throw ZipReadError.malformedArchive }

            parsed.append(
                ZipEntryHeader(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    crc32: crc32,
                    localHeaderOffset: localHeaderOffset
                )
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = parsed
    }

    public func read(_ entry: ZipEntryHeader, maximumCompressionRatio: Int) throws -> Data {
        if entry.uncompressedSize > 0 && entry.compressedSize == 0 {
            throw ZipReadError.compressionRatioExceeded
        }
        if entry.compressedSize > 0, entry.uncompressedSize > entry.compressedSize * maximumCompressionRatio {
            throw ZipReadError.compressionRatioExceeded
        }
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, ZipReader.readUInt32(bytes, offset) == 0x0403_4B50 else {
            throw ZipReadError.malformedArchive
        }
        let nameLength = Int(ZipReader.readUInt16(bytes, offset + 26))
        let extraLength = Int(ZipReader.readUInt16(bytes, offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart + entry.compressedSize <= bytes.count else { throw ZipReadError.malformedArchive }
        let start = bytes.startIndex + dataStart
        let payload = bytes.subdata(in: start..<(start + entry.compressedSize))

        let content: Data
        if entry.method == 0 {
            guard payload.count == entry.uncompressedSize else { throw ZipReadError.malformedArchive }
            content = payload
        } else {
            content = try ZipReader.inflate(payload, expectedSize: entry.uncompressedSize)
        }
        guard content.count == entry.uncompressedSize else { throw ZipReadError.malformedArchive }
        guard ZipReader.crc32(content) == entry.crc32 else { throw ZipReadError.checksumMismatch }
        return content
    }

    /// `..`, absolute paths, backslashes, and non-NFC names are refused before any extraction.
    static func isSafeArchivePath(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.hasSuffix("/") else { return false }
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\u{0}") else { return false }
        guard name == name.precomposedStringWithCanonicalMapping else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func inflate(_ payload: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipReadError.malformedArchive }
        return output
    }

    private struct EndOfCentralDirectory {
        let entryCount: Int
        let offset: Int
    }

    private static func findEndOfCentralDirectory(_ bytes: Data) -> EndOfCentralDirectory? {
        let maximumComment = 0xFFFF
        let lowest = max(0, bytes.count - 22 - maximumComment)
        var index = bytes.count - 22
        while index >= lowest {
            if readUInt32(bytes, index) == 0x0605_4B50 {
                let entryCount = Int(readUInt16(bytes, index + 10))
                let directorySize = Int(readUInt32(bytes, index + 12))
                let directoryOffset = Int(readUInt32(bytes, index + 16))
                guard directoryOffset >= 0, directorySize >= 0,
                      directoryOffset + directorySize <= bytes.count else { return nil }
                return EndOfCentralDirectory(entryCount: entryCount, offset: directoryOffset)
            }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        let base = bytes.startIndex + offset
        return UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
    }

    private static func readUInt32(_ bytes: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        let base = bytes.startIndex + offset
        return UInt32(bytes[base])
            | UInt32(bytes[base + 1]) << 8
            | UInt32(bytes[base + 2]) << 16
            | UInt32(bytes[base + 3]) << 24
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()
}
