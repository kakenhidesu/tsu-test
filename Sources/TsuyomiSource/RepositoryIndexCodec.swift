// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol

public enum RepositoryError: String, Error, Equatable, Sendable, CaseIterable {
    case indexTooLarge = "INDEX_TOO_LARGE"
    case invalidIndex = "INVALID_INDEX"
    case unsupportedFormat = "UNSUPPORTED_FORMAT"
    case invalidSignature = "INVALID_SIGNATURE"
    case invalidRootKey = "INVALID_ROOT_KEY"
    case indexExpired = "INDEX_EXPIRED"
    case indexRollback = "INDEX_ROLLBACK"
    case indexEquivocation = "INDEX_EQUIVOCATION"
    case unauthorizedMigration = "UNAUTHORIZED_MIGRATION"
    case repositoryIdentityMismatch = "REPOSITORY_IDENTITY_MISMATCH"
    case invalidSubscriptionLink = "INVALID_SUBSCRIPTION_LINK"
    case insecureTransport = "INSECURE_TRANSPORT"
    case unsafePackageUrl = "UNSAFE_PACKAGE_URL"
    case packageTooLarge = "PACKAGE_TOO_LARGE"
    case packageDigestMismatch = "PACKAGE_DIGEST_MISMATCH"
    case indexManifestMismatch = "INDEX_MANIFEST_MISMATCH"
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

/// A root-signed statement that this package replaces one signed by an earlier publisher key. It is
/// the only thing that lets a package change publisher without the user re-approving the source.
public struct LegacyMigration: Hashable, Sendable {
    public let fromPublisherFingerprint: String
    public let fromPackageSha256: String

    public init(fromPublisherFingerprint: String, fromPackageSha256: String) {
        self.fromPublisherFingerprint = fromPublisherFingerprint
        self.fromPackageSha256 = fromPackageSha256
    }
}

public struct RepositoryPackage: Hashable, Sendable {
    public let id: SourceId
    public let version: SemanticVersion
    public let hostApiMinInclusive: SemanticVersion
    public let hostApiMaxExclusive: SemanticVersion
    public let displayName: String
    public let summary: String
    public let language: String
    public let license: String
    public let sourceUrl: URL
    public let sourceRevision: String
    public let downloadUrl: URL
    public let sha256: String
    public let sizeBytes: Int
    public let publisherKeyId: String
    public let legacyMigration: LegacyMigration?

    public func acceptsHostApi(_ version: SemanticVersion) -> Bool {
        version >= hostApiMinInclusive && version < hostApiMaxExclusive
    }
}

public struct RepositoryRevocations: Hashable, Sendable {
    public let publisherFingerprints: Set<String>
    public let packageDigests: Set<String>

    public init(publisherFingerprints: Set<String>, packageDigests: Set<String>) {
        self.publisherFingerprints = publisherFingerprints
        self.packageDigests = packageDigests
    }
}

public struct RepositoryIndex: Hashable, Sendable {
    public let repositoryId: String
    public let sequence: Int
    public let rootKeyId: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let publishers: [RepositoryPublisher]
    public let packages: [RepositoryPackage]
    public let revocations: RepositoryRevocations
}

/// `tsuyomi-repository` v1, the catalog `tsuyomi-extensions` publishes. The envelope is signed by a
/// root key the host already holds; the catalog carries the publisher keys packages are signed with,
/// so the root vouches for publishers and the index itself never grants anything.
public enum RepositoryIndexCodec {
    public static let maximumIndexBytes = 1024 * 1024
    public static let maximumPackages = 512
    public static let maximumPublishers = 32
    static let maximumLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maximumClockSkew: TimeInterval = 5 * 60
    static let signaturePrefix = Data("tsuyomi-repository-v1\u{0}".utf8)

    public static func decode(_ bytes: Data, rootPublicKey: Data, now: Date) throws -> RepositoryIndex {
        guard bytes.count <= maximumIndexBytes else { throw RepositoryError.indexTooLarge }
        guard !JsonDuplicateKeys.found(in: bytes), let root = try? JSONValue.decode(bytes).objectValue,
              hasKeys(root, ["format", "version", "keyId", "signed", "signature"]) else {
            throw RepositoryError.invalidIndex
        }
        guard root.string("format") == "tsuyomi-repository", root.int("version") == 1 else {
            throw RepositoryError.unsupportedFormat
        }
        guard let rootKeyId = root.string("keyId"), isKeyId(rootKeyId),
              let signature = root.string("signature").flatMap(base64),
              let signed = root.object("signed") else {
            throw RepositoryError.invalidIndex
        }
        guard hasKeys(signed, ["repositoryId", "sequence", "issuedAt", "expiresAt", "publishers", "packages", "revocations"]) else {
            throw RepositoryError.invalidIndex
        }
        guard signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rootPublicKey),
              let canonical = try? Rfc8785.canonicalize(.object(signed)),
              key.isValidSignature(signature, for: signaturePrefix + canonical) else {
            throw RepositoryError.invalidSignature
        }
        guard let repositoryId = signed.string("repositoryId"), Grammar.isStrictSourceId(repositoryId),
              let sequence = signed.int("sequence"), sequence > 0,
              let issuedAt = signed.instant("issuedAt"), let expiresAt = signed.instant("expiresAt"),
              issuedAt < expiresAt, expiresAt.timeIntervalSince(issuedAt) <= maximumLifetime,
              issuedAt.timeIntervalSince(now) <= maximumClockSkew else {
            throw RepositoryError.invalidIndex
        }
        guard now < expiresAt else { throw RepositoryError.indexExpired }
        let publishers = try publishers(signed)
        return RepositoryIndex(
            repositoryId: repositoryId,
            sequence: sequence,
            rootKeyId: rootKeyId,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            publishers: publishers,
            packages: try packages(signed, publisherKeyIds: Set(publishers.map(\.keyId))),
            revocations: try revocations(signed)
        )
    }

    /// The sequence and signed-body digest of a catalog this host already verified. They are read
    /// without a second verification because only verified bytes are ever cached; they exist so a
    /// refresh can refuse a catalog older than, or equal in sequence but different from, the one it
    /// replaces — even after the cached one has expired.
    public static func sequence(of bytes: Data) -> Int? {
        (try? JSONValue.decode(bytes).objectValue)?.object("signed")?.int("sequence")
    }

    public static func signedDigest(of bytes: Data) -> String? {
        guard let signed = (try? JSONValue.decode(bytes).objectValue)?.object("signed"),
              let canonical = try? Rfc8785.canonicalize(.object(signed)) else { return nil }
        return Sha256.hex(canonical)
    }

    private static func publishers(_ signed: [String: JSONValue]) throws -> [RepositoryPublisher] {
        guard let rows = signed.array("publishers"), rows.count <= maximumPublishers else {
            throw RepositoryError.invalidIndex
        }
        var publishers: [RepositoryPublisher] = []
        var keyIds = Set<String>()
        var fingerprints = Set<String>()
        for row in rows {
            guard let object = row.objectValue,
                  hasKeys(object, ["keyId", "publicKey"], optional: ["fingerprint"]),
                  let keyId = object.string("keyId"), isKeyId(keyId),
                  let publicKey = object.string("publicKey").flatMap(base64), publicKey.count == 32 else {
                throw RepositoryError.invalidIndex
            }
            let fingerprint = Sha256.hex(publicKey)
            if let declared = object.string("fingerprint"), declared != fingerprint {
                throw RepositoryError.invalidIndex
            }
            guard keyIds.insert(keyId).inserted, fingerprints.insert(fingerprint).inserted else {
                throw RepositoryError.invalidIndex
            }
            publishers.append(RepositoryPublisher(keyId: keyId, publicKey: publicKey))
        }
        return publishers
    }

    private static func packages(
        _ signed: [String: JSONValue],
        publisherKeyIds: Set<String>
    ) throws -> [RepositoryPackage] {
        guard let rows = signed.array("packages"), rows.count <= maximumPackages else {
            throw RepositoryError.invalidIndex
        }
        var packages: [RepositoryPackage] = []
        var seen = Set<String>()
        for row in rows {
            guard let object = row.objectValue,
                  hasKeys(
                      object,
                      [
                          "id", "name", "version", "summary", "language", "license", "sourceUrl",
                          "sourceRevision", "downloadUrl", "size", "sha256", "hostApi", "publisherKeyId"
                      ],
                      optional: ["legacyMigration"]
                  ),
                  let rawId = object.string("id"), let id = try? SourceId(rawId),
                  let name = object.string("name"), Grammar.hasCodePoints(name, in: 1...128),
                  let version = object.string("version").flatMap({ try? SemanticVersion($0) }),
                  let summary = object.string("summary"), Grammar.hasCodePoints(summary, in: 1...1024),
                  let language = object.string("language"), Grammar.hasCodePoints(language, in: 1...64),
                  let license = object.string("license"), Grammar.hasCodePoints(license, in: 1...128),
                  let sourceUrl = object.string("sourceUrl"),
                  let sourceRevision = object.string("sourceRevision"), isCommit(sourceRevision),
                  let downloadUrl = object.string("downloadUrl"),
                  let size = object.int("size"), size > 0,
                  let digest = object.string("sha256"), Grammar.isSha256(digest),
                  let hostApi = object.object("hostApi"), hasKeys(hostApi, ["minInclusive", "maxExclusive"]),
                  let minimum = hostApi.string("minInclusive").flatMap({ try? SemanticVersion($0) }),
                  let maximum = hostApi.string("maxExclusive").flatMap({ try? SemanticVersion($0) }),
                  minimum < maximum,
                  let publisherKeyId = object.string("publisherKeyId"), publisherKeyIds.contains(publisherKeyId),
                  seen.insert(rawId).inserted else {
                throw RepositoryError.invalidIndex
            }
            guard size <= HxpArchiveLimits().maximumArchiveBytes else { throw RepositoryError.packageTooLarge }
            packages.append(
                RepositoryPackage(
                    id: id,
                    version: version,
                    hostApiMinInclusive: minimum,
                    hostApiMaxExclusive: maximum,
                    displayName: name,
                    summary: summary,
                    language: language,
                    license: license,
                    sourceUrl: try requireHttpsUrl(sourceUrl),
                    sourceRevision: sourceRevision,
                    downloadUrl: try requireHttpsUrl(downloadUrl),
                    sha256: digest,
                    sizeBytes: size,
                    publisherKeyId: publisherKeyId,
                    legacyMigration: try legacyMigration(object["legacyMigration"])
                )
            )
        }
        return packages
    }

    private static func legacyMigration(_ value: JSONValue?) throws -> LegacyMigration? {
        guard let value else { return nil }
        guard let object = value.objectValue,
              hasKeys(object, ["fromPublisherFingerprint", "fromPackageSha256"]),
              let publisher = object.string("fromPublisherFingerprint"), Grammar.isSha256(publisher),
              let package = object.string("fromPackageSha256"), Grammar.isSha256(package) else {
            throw RepositoryError.invalidIndex
        }
        return LegacyMigration(fromPublisherFingerprint: publisher, fromPackageSha256: package)
    }

    private static func revocations(_ signed: [String: JSONValue]) throws -> RepositoryRevocations {
        guard let object = signed.object("revocations"),
              hasKeys(object, ["publisherFingerprints", "packageDigests"]) else {
            throw RepositoryError.invalidIndex
        }
        return RepositoryRevocations(
            publisherFingerprints: try digests(object, "publisherFingerprints", limit: maximumPublishers),
            packageDigests: try digests(object, "packageDigests", limit: maximumPackages)
        )
    }

    private static func digests(_ object: [String: JSONValue], _ name: String, limit: Int) throws -> Set<String> {
        guard let rows = object.array(name), rows.count <= limit else { throw RepositoryError.invalidIndex }
        var digests = Set<String>()
        for row in rows {
            guard let digest = row.stringValue, Grammar.isSha256(digest), digests.insert(digest).inserted else {
                throw RepositoryError.invalidIndex
            }
        }
        return digests
    }

    /// A catalog URL is fetched as written and a package URL is downloaded as written, so both are
    /// held to the same shape: HTTPS, a host, no credentials, no fragment, printable ASCII only.
    static func requireHttpsUrl(_ text: String) throws -> URL {
        guard text.utf8.count <= 4_096,
              text.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\\" && $0 != "#" }),
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw RepositoryError.unsafePackageUrl
        }
        return url
    }

    static func isKeyId(_ value: String) -> Bool {
        Grammar.isToken(value, limit: 128) && (8...128).contains(value.unicodeScalars.count)
    }

    static func base64(_ text: String) -> Data? {
        guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else { return nil }
        return bytes
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func hasKeys(_ object: [String: JSONValue], _ required: Set<String>, optional: Set<String> = []) -> Bool {
        required.isSubset(of: object.keys) && object.keys.allSatisfy { required.contains($0) || optional.contains($0) }
    }
}
