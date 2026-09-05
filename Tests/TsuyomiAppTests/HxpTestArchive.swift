// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// Rebuilds the acceptance fixture archive with a different version and re-signs it with the public
/// fixture seed. The market's update path cannot be exercised without a second, higher version, and
/// nothing signed with this seed can load in a release build.
enum HxpTestArchive {
    static let seed = Data((1...32).map(UInt8.init))

    static func repackaged(_ original: Data, version: String) throws -> Data {
        let limits = HxpArchiveLimits()
        let reader = try ZipReader(
            original,
            maximumFileBytes: limits.maximumFileBytes,
            maximumFileCount: limits.maximumFileCount
        )
        var entries: [(name: String, bytes: Data)] = []
        for header in reader.entries {
            entries.append(
                (header.name, try reader.read(header, maximumCompressionRatio: limits.maximumCompressionRatio))
            )
        }
        guard let manifestBytes = entries.first(where: { $0.name == "manifest.json" })?.bytes,
              var manifest = try JSONDecoder().decode(JSONValue.self, from: manifestBytes).objectValue else {
            throw HxpVerificationError.invalidManifest
        }
        manifest["version"] = .string(version)
        let canonicalManifest = try Rfc8785.canonicalize(.object(manifest))
        // The digest covers the file list, not the version, so bumping the version leaves it intact.
        guard let contentDigest = manifest.object("integrity")?.string("contentDigest") else {
            throw HxpVerificationError.invalidManifest
        }
        var message = HxpArchiveVerifier.signaturePrefix
        message.append(canonicalManifest)
        message.append(0)
        message.append(Data(contentDigest.utf8))
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)

        var rebuilt: [(name: String, bytes: Data)] = []
        for entry in entries {
            switch entry.name {
            case "manifest.json": rebuilt.append((entry.name, canonicalManifest))
            case "signature.ed25519": rebuilt.append((entry.name, signature))
            default: rebuilt.append(entry)
            }
        }
        return zip(rebuilt)
    }

    /// A stored-only zip. The reader accepts stored and deflated entries; stored keeps this helper
    /// small enough to be obviously correct.
    private static func zip(_ entries: [(name: String, bytes: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(archive.count)
            let name = Data(entry.name.utf8)
            archive.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            archive.append(uint16(20))
            archive.append(uint16(0))
            archive.append(uint16(0))
            archive.append(uint16(0))
            archive.append(uint16(0))
            archive.append(uint32(crc32(entry.bytes)))
            archive.append(uint32(UInt32(entry.bytes.count)))
            archive.append(uint32(UInt32(entry.bytes.count)))
            archive.append(uint16(UInt16(name.count)))
            archive.append(uint16(0))
            archive.append(name)
            archive.append(entry.bytes)
        }
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.name.utf8)
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            directory.append(uint16(20))
            directory.append(uint16(20))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(crc32(entry.bytes)))
            directory.append(uint32(UInt32(entry.bytes.count)))
            directory.append(uint32(UInt32(entry.bytes.count)))
            directory.append(uint16(UInt16(name.count)))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(0))
            directory.append(uint32(UInt32(offsets[index])))
            directory.append(name)
        }
        let directoryOffset = archive.count
        archive.append(directory)
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.append(uint16(0))
        archive.append(uint16(0))
        archive.append(uint16(UInt16(entries.count)))
        archive.append(uint16(UInt16(entries.count)))
        archive.append(uint32(UInt32(directory.count)))
        archive.append(uint32(UInt32(directoryOffset)))
        archive.append(uint16(0))
        return archive
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
