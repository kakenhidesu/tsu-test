// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol

public enum RepositoryError: String, Error, Equatable, Sendable, CaseIterable {
    case indexTooLarge = "INDEX_TOO_LARGE"
    case invalidIndex = "INVALID_INDEX"
    case unsupportedFormat = "UNSUPPORTED_FORMAT"
    case invalidSignature = "INVALID_SIGNATURE"
    case indexExpired = "INDEX_EXPIRED"
    case insecureTransport = "INSECURE_TRANSPORT"
    case unsafePackagePath = "UNSAFE_PACKAGE_PATH"
    case packageTooLarge = "PACKAGE_TOO_LARGE"
    case packageDigestMismatch = "PACKAGE_DIGEST_MISMATCH"
    case indexManifestMismatch = "INDEX_MANIFEST_MISMATCH"
    case publisherNotTrusted = "PUBLISHER_NOT_TRUSTED"
    case publisherRevoked = "PUBLISHER_REVOKED"
    case packageRevoked = "PACKAGE_REVOKED"
    case hostApiIncompatible = "HOST_API_INCOMPATIBLE"
    case downgradeRejected = "DOWNGRADE_REJECTED"
}

public struct RepositoryPublisher: Hashable, Sendable {
    public let keyId: String
    public let publicKey: Data

    /// The first sixteen bytes of the key digest, grouped for reading aloud. Users compare this, so
    /// it must be derived from the key itself and never from a name the repository chose.
    public var fingerprint: String {
        let hex = Sha256.hex(publicKey).prefix(32)
        return stride(from: 0, to: hex.count, by: 4)
            .map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: 4)
                return String(hex[start..<end])
            }
            .joined(separator: " ")
    }
}

public struct RepositoryPackage: Hashable, Sendable {
    public let id: SourceId
    public let version: SemanticVersion
    public let hostApiMinInclusive: SemanticVersion
    public let hostApiMaxExclusive: SemanticVersion
    public let displayName: String
    public let summary: String
    public let capabilities: HxpCapabilities
    public let file: String
    public let sha256: String
    public let sizeBytes: Int

    public func acceptsHostApi(_ version: SemanticVersion) -> Bool {
        version >= hostApiMinInclusive && version < hostApiMaxExclusive
    }
}

public enum RevocationTarget: Hashable, Sendable {
    case keyId(String)
    case packageDigest(String)
}

public struct RepositoryRevocation: Hashable, Sendable {
    public let target: RevocationTarget
    public let reasonCode: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let signature: Data
}

public struct RepositoryIndex: Hashable, Sendable {
    public let repositoryId: String
    public let displayName: String
    public let summary: String
    public let publisher: RepositoryPublisher
    public let issuedAt: Date
    public let expiresAt: Date
    public let packages: [RepositoryPackage]
    public let revocations: [RepositoryRevocation]
}

/// `tsuyomi-repository` v0. Every field here is information the host is already required to check by
/// `hxp-package-v1` §Trust §Updates; the index only saves a download, it never grants anything.
public enum RepositoryIndexCodec {
    public static let maximumIndexBytes = 1024 * 1024
    public static let maximumPackages = 512
    public static let maximumRevocations = 512
    static let signaturePrefix = Data("tsuyomi-repository-v0\u{0}".utf8)
    static let revocationPrefix = Data("tsuyomi-revocation-v0\u{0}".utf8)

    private static let reasonCodes: Set<String> = ["compromised", "malicious", "superseded", "other"]

    public static func decode(
        indexBytes: Data,
        signature: Data,
        now: Date,
        expectedPublicKey: Data? = nil
    ) throws -> RepositoryIndex {
        guard indexBytes.count <= maximumIndexBytes else { throw RepositoryError.indexTooLarge }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: indexBytes).objectValue else {
            throw RepositoryError.invalidIndex
        }
        guard root.string("format") == "tsuyomi-repository", root.int("version") == 0 else {
            throw RepositoryError.unsupportedFormat
        }
        let publisher = try publisher(root)
        if let expectedPublicKey, expectedPublicKey != publisher.publicKey {
            throw RepositoryError.publisherNotTrusted
        }
        try verify(
            message: signaturePrefix + (try canonical(root)),
            signature: signature,
            publicKey: publisher.publicKey
        )
        guard let repositoryId = root.string("repositoryId"), Grammar.isStrictSourceId(repositoryId) else {
            throw RepositoryError.invalidIndex
        }
        let display = try display(root.object("display"))
        guard let issuedAt = root.instant("issuedAt"), let expiresAt = root.instant("expiresAt"),
              issuedAt < expiresAt else {
            throw RepositoryError.invalidIndex
        }
        guard now < expiresAt else { throw RepositoryError.indexExpired }
        return RepositoryIndex(
            repositoryId: repositoryId,
            displayName: display.name,
            summary: display.summary,
            publisher: publisher,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            packages: try packages(root),
            revocations: try revocations(root, publisher: publisher)
        )
    }

    private static func publisher(_ root: [String: JSONValue]) throws -> RepositoryPublisher {
        guard let object = root.object("publisher"),
              let keyId = object.string("keyId"), Grammar.hasCodePoints(keyId, in: 1...128),
              let hex = object.string("publicKey"), hex.count == 64,
              let publicKey = Data(hex: hex) else {
            throw RepositoryError.invalidIndex
        }
        return RepositoryPublisher(keyId: keyId, publicKey: publicKey)
    }

    private static func display(_ object: [String: JSONValue]?) throws -> (name: String, summary: String) {
        guard let object,
              let name = object.string("name"), Grammar.hasCodePoints(name, in: 1...120),
              let summary = object.string("summary"), Grammar.hasCodePoints(summary, in: 1...120) else {
            throw RepositoryError.invalidIndex
        }
        return (name, summary)
    }

    private static func packages(_ root: [String: JSONValue]) throws -> [RepositoryPackage] {
        guard let rows = root.array("packages"), rows.count <= maximumPackages else {
            throw RepositoryError.invalidIndex
        }
        var packages: [RepositoryPackage] = []
        var seen = Set<String>()
        for row in rows {
            guard let object = row.objectValue,
                  let rawId = object.string("id"), let id = try? SourceId(rawId),
                  let rawVersion = object.string("version"),
                  let version = try? SemanticVersion(rawVersion),
                  let hostApi = object.object("hostApi"),
                  let rawMinimum = hostApi.string("minInclusive"),
                  let minimum = try? SemanticVersion(rawMinimum),
                  let rawMaximum = hostApi.string("maxExclusive"),
                  let maximum = try? SemanticVersion(rawMaximum),
                  minimum < maximum,
                  let capabilities = object.object("capabilities"),
                  let parsed = try? HxpCapabilityParser.parse(capabilities),
                  let file = object.string("file"),
                  let digest = object.string("sha256"), Grammar.isSha256(digest),
                  let size = object.int("sizeBytes"), size > 0 else {
                throw RepositoryError.invalidIndex
            }
            guard seen.insert("\(rawId)\u{0}\(rawVersion)").inserted else {
                throw RepositoryError.invalidIndex
            }
            try requireSafeRelativePath(file)
            guard size <= HxpArchiveLimits().maximumArchiveBytes else { throw RepositoryError.packageTooLarge }
            let display = try display(object.object("display"))
            packages.append(
                RepositoryPackage(
                    id: id,
                    version: version,
                    hostApiMinInclusive: minimum,
                    hostApiMaxExclusive: maximum,
                    displayName: display.name,
                    summary: display.summary,
                    capabilities: parsed,
                    file: file,
                    sha256: digest,
                    sizeBytes: size
                )
            )
        }
        return packages
    }

    /// A revocation is only honoured when the repository's own publisher signed it, so a mirror
    /// cannot inject a revocation for someone else's key.
    private static func revocations(
        _ root: [String: JSONValue],
        publisher: RepositoryPublisher
    ) throws -> [RepositoryRevocation] {
        guard let rows = root.array("revocations"), rows.count <= maximumRevocations else {
            throw RepositoryError.invalidIndex
        }
        var revocations: [RepositoryRevocation] = []
        for row in rows {
            guard var object = row.objectValue,
                  let hex = object.string("signature"), hex.count == 128,
                  let signature = Data(hex: hex),
                  let reasonCode = object.string("reasonCode"), reasonCodes.contains(reasonCode),
                  let issuedAt = object.instant("issuedAt"),
                  let expiresAt = object.instant("expiresAt"), issuedAt < expiresAt,
                  let target = object.object("target") else {
                throw RepositoryError.invalidIndex
            }
            let resolved: RevocationTarget
            if let keyId = target.string("keyId"), Grammar.hasCodePoints(keyId, in: 1...128) {
                resolved = .keyId(keyId)
            } else if let digest = target.string("packageDigest"), Grammar.isSha256(digest) {
                resolved = .packageDigest(digest)
            } else {
                throw RepositoryError.invalidIndex
            }
            object.removeValue(forKey: "signature")
            try verify(
                message: revocationPrefix + (try canonical(object)),
                signature: signature,
                publicKey: publisher.publicKey
            )
            revocations.append(
                RepositoryRevocation(
                    target: resolved,
                    reasonCode: reasonCode,
                    issuedAt: issuedAt,
                    expiresAt: expiresAt,
                    signature: signature
                )
            )
        }
        return revocations
    }

    /// Package paths are joined onto the repository base, so anything that could climb out of it or
    /// point at another host is rejected before a request is built.
    static func requireSafeRelativePath(_ path: String) throws {
        guard !path.isEmpty, path.utf16.count <= 512,
              !path.hasPrefix("/"), !path.contains("//"), !path.contains(".."),
              !path.contains(":"), !path.contains("\\"), !path.contains("?"), !path.contains("#"),
              path.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw RepositoryError.unsafePackagePath
        }
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonical(_ object: [String: JSONValue]) throws -> Data {
        guard let bytes = try? Rfc8785.canonicalize(.object(object)) else {
            throw RepositoryError.invalidIndex
        }
        return bytes
    }

    private static func verify(message: Data, signature: Data, publicKey: Data) throws {
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: message) else {
            throw RepositoryError.invalidSignature
        }
    }
}
