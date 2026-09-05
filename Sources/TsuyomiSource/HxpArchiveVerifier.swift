// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import os
import TsuyomiProtocol

/// Verifies one `.hxp` in the fixed order archive limits → path safety → declared file digests →
/// content digest → Ed25519 signature. Nothing is installed, executed, or cached before the last
/// step succeeds (hxp-package-v1 §Verification).
public struct HxpArchiveVerifier: Sendable {
    static let signaturePrefix = Data("tsuyomi-hxp-v1\u{0}".utf8)

    private let publisherKeys: any PublisherKeyResolver
    private let hostApiVersion: SemanticVersion
    private let limits: HxpArchiveLimits

    public init(
        publisherKeys: any PublisherKeyResolver,
        hostApiVersion: SemanticVersion,
        limits: HxpArchiveLimits = HxpArchiveLimits()
    ) {
        self.publisherKeys = publisherKeys
        self.hostApiVersion = hostApiVersion
        self.limits = limits
    }

    public func verify(archiveBytes: Data) throws -> VerifiedHxpPackage {
        guard (1...limits.maximumArchiveBytes).contains(archiveBytes.count) else {
            throw HxpVerificationError.archiveTooLarge
        }
        let reader: ZipReader
        do {
            reader = try ZipReader(
                archiveBytes,
                maximumFileBytes: limits.maximumFileBytes,
                maximumFileCount: limits.maximumFileCount
            )
        } catch {
            throw HxpArchiveVerifier.map(error)
        }
        guard reader.entries.count <= limits.maximumFileCount else { throw HxpVerificationError.tooManyFiles }

        var entries: [String: Data] = [:]
        var totalUncompressed = 0
        for header in reader.entries {
            totalUncompressed += header.uncompressedSize
            guard totalUncompressed <= limits.maximumUncompressedBytes else {
                throw HxpVerificationError.archiveTooLarge
            }
            do {
                entries[header.name] = try reader.read(header, maximumCompressionRatio: limits.maximumCompressionRatio)
            } catch {
                throw HxpArchiveVerifier.map(error)
            }
        }

        guard let manifestBytes = entries[HxpManifestParser.manifestFile] else {
            throw HxpVerificationError.missingRequiredFile
        }
        guard let signature = entries[HxpManifestParser.signatureFile] else {
            throw HxpVerificationError.missingRequiredFile
        }
        guard signature.count == 64 else { throw HxpVerificationError.invalidSignature }

        let parsed = try HxpManifestParser.parse(manifestBytes, hostApiVersion: hostApiVersion)
        let manifest = parsed.manifest
        guard entries[manifest.entry] != nil else { throw HxpVerificationError.missingRequiredFile }

        let expected = Set(manifest.files.keys)
            .union([HxpManifestParser.manifestFile, HxpManifestParser.signatureFile])
        guard Set(entries.keys) == expected else { throw HxpVerificationError.integrityMismatch }
        for (path, expectedDigest) in manifest.files {
            guard let bytes = entries[path], Sha256.hex(bytes) == expectedDigest else {
                throw HxpVerificationError.integrityMismatch
            }
        }
        let canonicalFiles = try canonicalFileDigests(manifest.files)
        guard Sha256.hex(canonicalFiles) == manifest.contentDigest else {
            throw HxpVerificationError.integrityMismatch
        }

        guard let publisher = publisherKeys.resolve(keyId: manifest.publisherKeyId) else {
            throw HxpVerificationError.unknownPublisher
        }
        guard !publisherKeys.isRevokedFingerprint(publisher.fingerprint) else {
            throw HxpVerificationError.revokedPublisher
        }
        guard !publisherKeys.isRevokedPackage(manifest.contentDigest) else {
            throw HxpVerificationError.revokedPackage
        }
        var message = HxpArchiveVerifier.signaturePrefix
        message.append(parsed.canonicalBytes)
        message.append(0)
        message.append(Data(manifest.contentDigest.utf8))
        guard HxpArchiveVerifier.isValidEd25519(
            publicKey: publisher.publicKey,
            message: message,
            signature: signature
        ) else {
            throw HxpVerificationError.invalidSignature
        }

        return VerifiedHxpPackage(
            manifest: manifest,
            packageSha256: Sha256.hex(archiveBytes),
            publisherFingerprint: publisher.fingerprint,
            archiveBytes: archiveBytes,
            entryModuleBytes: entries[manifest.entry] ?? Data()
        )
    }

    private func canonicalFileDigests(_ files: [String: String]) throws -> Data {
        let value = JSONValue.object(files.mapValues { JSONValue.string($0) })
        guard let canonical = try? Rfc8785.canonicalize(value) else {
            throw HxpVerificationError.integrityMismatch
        }
        return canonical
    }

    static func isValidEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    static func map(_ error: any Error) -> HxpVerificationError {
        guard let zipError = error as? ZipReadError else {
            return (error as? HxpVerificationError) ?? .invalidArchiveEntry
        }
        switch zipError {
        case .unsupportedCompression: return .unsupportedCompression
        case .encryptedEntry: return .encryptedEntry
        case .symlinkEntry: return .symlinkEntry
        case .unsafePath, .duplicateEntry, .malformedArchive, .checksumMismatch: return .invalidArchiveEntry
        case .fileTooLarge: return .fileTooLarge
        case .compressionRatioExceeded: return .compressionRatioExceeded
        }
    }
}

/// In-memory trust for the DEBUG fixture publisher and for tests; the durable store is
/// `PublisherTrustStore`.
public final class InMemoryPublisherKeyStore: PublisherKeyResolver {
    private struct State: Sendable {
        var byId: [String: PublisherKey] = [:]
        var revokedFingerprints = Set<String>()
        var revokedPackages = Set<String>()
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(keys: [PublisherKey] = []) {
        var initial = State()
        for key in keys { initial.byId[key.keyId] = key }
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func resolve(keyId: String) -> PublisherKey? {
        state.withLock { $0.byId[keyId] }
    }

    public func isRevokedFingerprint(_ fingerprint: String) -> Bool {
        state.withLock { $0.revokedFingerprints.contains(fingerprint) }
    }

    public func isRevokedPackage(_ contentDigest: String) -> Bool {
        state.withLock { $0.revokedPackages.contains(contentDigest) }
    }

    /// A key ID may never be rebound to a different public key: trust follows the fingerprint.
    public func add(_ key: PublisherKey) throws {
        try state.withLock { current in
            if let existing = current.byId[key.keyId], existing.publicKey != key.publicKey {
                throw HxpVerificationError.unknownPublisher
            }
            current.byId[key.keyId] = key
        }
    }

    public func revokeFingerprint(_ fingerprint: String) {
        state.withLock { _ = $0.revokedFingerprints.insert(fingerprint) }
    }

    public func revokePackage(_ contentDigest: String) {
        state.withLock { _ = $0.revokedPackages.insert(contentDigest) }
    }
}
