// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Decrypted source credentials plus a non-secret revision derived from the randomised encrypted
/// record. The revision changes on every explicit credential write without revealing cookie bytes.
public struct SourceCredentialSnapshot: Sendable {
    public let plaintext: Data
    public let cachePartitionId: String
}

/// Source/origin-partitioned protected credential store. Files are opaque by name, excluded from
/// backup, and hold only a versioned AEAD record. It never uses SQLite, `UserDefaults`, or logs.
public actor SourceCredentialStore {
    private let directory: URL
    private let aead: any AeadPort

    private static let recordMagic: UInt32 = 0x5453_4352
    private static let headerBytes = 4 + 2 + 2 + 1 + 4
    private static let maximumPlaintextBytes = 1024 * 1024
    private static let maximumCiphertextBytes = maximumPlaintextBytes + 16

    public init(roots: StorageRoots, aead: any AeadPort = KeychainAesGcm()) throws {
        let directory = roots.directory(.credentials).appendingPathComponent("records", isDirectory: true)
        try StorageRoots.createDirectory(at: directory)
        self.directory = directory.resolvingSymlinksInPath()
        self.aead = aead
    }

    public func put(_ partition: SourceCredentialPartition, plaintext: Data) throws {
        guard plaintext.count <= Self.maximumPlaintextBytes else { throw CredentialStorageError.unavailable }
        let encrypted = try aead.encrypt(
            plaintext: plaintext,
            additionalAuthenticatedData: partition.additionalAuthenticatedData
        )
        guard encrypted.iv.count == gcmIvBytes, encrypted.ciphertext.count <= Self.maximumCiphertextBytes else {
            throw CredentialStorageError.unavailable
        }
        do {
            try encode(encrypted).write(
                to: file(for: partition),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw CredentialStorageError.unavailable
        }
    }

    /// Returns the decrypted value together with an opaque revision for credential-bound caches.
    public func snapshot(_ partition: SourceCredentialPartition) throws -> SourceCredentialSnapshot? {
        let source = file(for: partition)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        guard let encoded = try? Data(contentsOf: source) else { throw CredentialStorageError.unavailable }
        guard let record = try? decode(encoded) else {
            try invalidate(source)
            throw CredentialStorageError.corruptOrUnauthenticated
        }
        do {
            let plaintext = try aead.decrypt(
                record,
                additionalAuthenticatedData: partition.additionalAuthenticatedData
            )
            return SourceCredentialSnapshot(plaintext: plaintext, cachePartitionId: Sha256.hex(encoded))
        } catch CredentialStorageError.corruptOrUnauthenticated {
            try invalidate(source)
            throw CredentialStorageError.corruptOrUnauthenticated
        }
    }

    /// Returns nil only for a missing partition. Confirmed corrupt records are cleared in place.
    public func get(_ partition: SourceCredentialPartition) throws -> Data? {
        try snapshot(partition)?.plaintext
    }

    /// Deletes exactly one source/origin partition and leaves every other record untouched.
    @discardableResult
    public func delete(_ partition: SourceCredentialPartition) throws -> Bool {
        let target = file(for: partition)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw CredentialStorageError.deleteFailed
        }
        return true
    }

    private func invalidate(_ url: URL) throws {
        // Failure stays scoped to this file. Adjacent source partitions are never scanned or cleared.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CredentialStorageError.deleteFailed
        }
    }

    private func file(for partition: SourceCredentialPartition) -> URL {
        let digest = Sha256.hex(Array("\(partition.sourceId)\u{0}\(partition.origin.value)".utf8))
        return directory.appendingPathComponent("\(digest).record")
    }

    private func encode(_ value: AeadCiphertext) -> Data {
        var writer = BinaryWriter()
        writer.write(Self.recordMagic)
        writer.write(credentialSchemaVersion)
        writer.write(credentialKeyVersion)
        writer.write(UInt8(value.iv.count))
        writer.write(UInt32(value.ciphertext.count))
        var data = writer.data
        data.append(value.iv)
        data.append(value.ciphertext)
        return data
    }

    private func decode(_ encoded: Data) throws -> AeadCiphertext {
        var reader = BinaryReader(encoded)
        guard try reader.readUInt32() == Self.recordMagic,
              try reader.readUInt16() == credentialSchemaVersion,
              try reader.readUInt16() == credentialKeyVersion else {
            throw BinaryDecodeError.malformed
        }
        let ivLength = Int(try reader.readUInt8())
        let ciphertextLength = Int(try reader.readUInt32())
        guard ivLength == gcmIvBytes,
              (16...Self.maximumCiphertextBytes).contains(ciphertextLength),
              encoded.count == Self.headerBytes + ivLength + ciphertextLength else {
            throw BinaryDecodeError.malformed
        }
        let start = encoded.startIndex + Self.headerBytes
        return AeadCiphertext(
            iv: encoded[start..<(start + ivLength)],
            ciphertext: encoded[(start + ivLength)...]
        )
    }
}
