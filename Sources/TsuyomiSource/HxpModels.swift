// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public struct SemanticVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let original: String

    public init(_ value: String) throws {
        guard let parsed = SemanticVersion.parse(value) else { throw HxpVerificationError.invalidManifest }
        self = parsed
    }

    private init(major: Int, minor: Int, patch: Int, prerelease: [String], original: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.original = original
    }

    public var description: String { original }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { compare(lhs, rhs) < 0 }

    static func compare(_ lhs: SemanticVersion, _ rhs: SemanticVersion) -> Int {
        if lhs.major != rhs.major { return lhs.major < rhs.major ? -1 : 1 }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor ? -1 : 1 }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch ? -1 : 1 }
        if lhs.prerelease.isEmpty && !rhs.prerelease.isEmpty { return 1 }
        if !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return -1 }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return -1 }
            guard index < rhs.prerelease.count else { return 1 }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber ? -1 : 1
            case (_?, nil): return -1
            case (nil, _?): return 1
            default: return CanonicalOrder.compare(left, right)
            }
        }
        return 0
    }

    /// `major.minor.patch[-prerelease][+build]`, with no leading zeroes in the numeric fields.
    private static func parse(_ value: String) -> SemanticVersion? {
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = withoutBuild.first, withoutBuild.count <= 2 else { return nil }
        if withoutBuild.count == 2, !isDotSeparatedIdentifier(String(withoutBuild[1])) { return nil }
        let versionAndPrerelease = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numbers = versionAndPrerelease.first else { return nil }
        var prerelease: [String] = []
        if versionAndPrerelease.count == 2 {
            let text = String(versionAndPrerelease[1])
            guard isDotSeparatedIdentifier(text) else { return nil }
            prerelease = text.split(separator: ".").map(String.init)
        }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), part == "0" || !part.hasPrefix("0"),
                  let number = Int(part) else { return nil }
            parsed.append(number)
        }
        return SemanticVersion(
            major: parsed[0],
            minor: parsed[1],
            patch: parsed[2],
            prerelease: prerelease,
            original: value
        )
    }

    private static func isDotSeparatedIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy { scalar in
                ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar)
                    || ("a"..."z").contains(scalar) || scalar == "-"
            }
        }
    }
}

public struct HxpNetworkCapability: Hashable, Sendable {
    public let origins: Set<HttpsOrigin>
    public let maximumConcurrentRequests: Int
    public let requestTimeoutMs: Int
    public let maximumResponseBytes: Int
}

public struct HxpCookieCapability: Hashable, Sendable {
    public let sourceScoped: Bool
    public let origins: Set<HttpsOrigin>
}

public struct HxpWebLoginCapability: Hashable, Sendable {
    public let enabled: Bool
    public let origins: Set<HttpsOrigin>
}

public struct HxpHomeCapability: Hashable, Sendable {
    public let enabled: Bool
}

public enum RemoteOperation: String, Hashable, Sendable, CaseIterable {
    case read
    case add
}

public enum HxpRemoteParameter: Hashable, Sendable {
    case fixed(name: String, value: String)
    case remoteBookId(name: String)
    case cursor(name: String)

    public var name: String {
        switch self {
        case .fixed(let name, _): return name
        case .remoteBookId(let name): return name
        case .cursor(let name): return name
        }
    }
}

public struct HxpRemoteRedirectTarget: Hashable, Sendable {
    public let origin: HttpsOrigin
    public let method: NetworkMethod
    public let path: String
    public let referrerPath: String?
    public let parameters: [String: String]
}

public struct HxpRemoteOperationPolicy: Hashable, Sendable {
    public let operation: RemoteOperation
    public let origin: HttpsOrigin
    public let method: NetworkMethod
    public let path: String
    public let referrerPath: String?
    public let parameters: [HxpRemoteParameter]
    public let redirects: [HxpRemoteRedirectTarget]
}

public struct HxpRemoteLibraryCapability: Hashable, Sendable {
    public let read: Bool
    public let writeOperations: Set<String>
    public let policies: [RemoteOperation: HxpRemoteOperationPolicy]
}

public struct HxpCapabilities: Hashable, Sendable {
    public let network: HxpNetworkCapability
    public let cookies: HxpCookieCapability
    public let webLogin: HxpWebLoginCapability
    public let home: HxpHomeCapability
    public let remoteLibrary: HxpRemoteLibraryCapability
    public let storageQuotaBytes: Int
}

public struct HxpResourceLimits: Hashable, Sendable {
    public let maximumExecutionWallTimeMs: Int
    public let maximumMemoryBytes: Int
}

public struct HxpManifest: Hashable, Sendable {
    public let sourceId: SourceId
    public let version: SemanticVersion
    public let displayName: String
    public let summary: String
    public let homepage: String?
    public let hostApiMinInclusive: SemanticVersion
    public let hostApiMaxExclusive: SemanticVersion
    public let entry: String
    public let contentDigest: String
    public let files: [String: String]
    public let publisherKeyId: String
    public let capabilities: HxpCapabilities
    public let resourceLimits: HxpResourceLimits
    public let updateChannel: String
}

public enum PublisherTrust: String, Sendable, CaseIterable, Codable {
    case builtInTest = "BUILT_IN_TEST"
    case userAdded = "USER_ADDED"
}

public struct PublisherKey: Hashable, Sendable {
    public let keyId: String
    public let publicKey: Data
    public let trust: PublisherTrust
    public let fingerprint: String

    public init(keyId: String, publicKey: Data, trust: PublisherTrust) throws {
        guard Grammar.isToken(keyId, limit: 128), (8...128).contains(keyId.unicodeScalars.count) else {
            throw HxpVerificationError.invalidManifest
        }
        guard publicKey.count == 32 else { throw HxpVerificationError.invalidManifest }
        self.keyId = keyId
        self.publicKey = publicKey
        self.trust = trust
        self.fingerprint = Sha256.hex(publicKey)
    }
}

/// Trust is keyed by public-key fingerprint, never by display name (hxp-package-v1 §Trust).
public protocol PublisherKeyResolver: Sendable {
    func resolve(keyId: String) -> PublisherKey?
    func isRevokedFingerprint(_ fingerprint: String) -> Bool
    func isRevokedPackage(_ contentDigest: String) -> Bool
}

public enum HxpVerificationError: String, Error, Equatable, Sendable, CaseIterable {
    case archiveTooLarge = "ARCHIVE_TOO_LARGE"
    case tooManyFiles = "TOO_MANY_FILES"
    case invalidArchiveEntry = "INVALID_ARCHIVE_ENTRY"
    case unsupportedCompression = "UNSUPPORTED_COMPRESSION"
    case encryptedEntry = "ENCRYPTED_ENTRY"
    case symlinkEntry = "SYMLINK_ENTRY"
    case fileTooLarge = "FILE_TOO_LARGE"
    case compressionRatioExceeded = "COMPRESSION_RATIO_EXCEEDED"
    case missingRequiredFile = "MISSING_REQUIRED_FILE"
    case invalidManifest = "INVALID_MANIFEST"
    case hostApiIncompatible = "HOST_API_INCOMPATIBLE"
    case capabilityPolicyViolation = "CAPABILITY_POLICY_VIOLATION"
    case integrityMismatch = "INTEGRITY_MISMATCH"
    case unknownPublisher = "UNKNOWN_PUBLISHER"
    case revokedPublisher = "REVOKED_PUBLISHER"
    case revokedPackage = "REVOKED_PACKAGE"
    case invalidSignature = "INVALID_SIGNATURE"
}

public struct VerifiedHxpPackage: Sendable {
    public let manifest: HxpManifest
    public let packageSha256: String
    public let publisherFingerprint: String
    public let archiveBytes: Data
    public let entryModuleBytes: Data
}

public struct HxpArchiveLimits: Hashable, Sendable {
    public let maximumArchiveBytes: Int
    public let maximumUncompressedBytes: Int
    public let maximumFileBytes: Int
    public let maximumFileCount: Int
    public let maximumCompressionRatio: Int

    public init(
        maximumArchiveBytes: Int = 16 * 1024 * 1024,
        maximumUncompressedBytes: Int = 32 * 1024 * 1024,
        maximumFileBytes: Int = 8 * 1024 * 1024,
        maximumFileCount: Int = 256,
        maximumCompressionRatio: Int = 100
    ) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumUncompressedBytes = maximumUncompressedBytes
        self.maximumFileBytes = maximumFileBytes
        self.maximumFileCount = maximumFileCount
        self.maximumCompressionRatio = maximumCompressionRatio
    }
}
