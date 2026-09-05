// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// The six inputs §6.8 requires a host to refuse, plus the accepted baseline they are each one step
/// away from. Indexes are built and signed here with the fixture seed; nothing is committed.
final class RepositoryIndexTests: XCTestCase {
    private static let seed = Data((1...32).map(UInt8.init))
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private var signingKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: RepositoryIndexTests.seed) }
    }

    private func archive() throws -> Data {
        try ExtensionFixtures.data("fixtures/wenku8/wenku8-fixture.hxp")
    }

    private func manifest() throws -> HxpManifest {
        #if DEBUG
        let keys = InMemoryPublisherKeyStore(keys: [try Phase2TestPublisher.key()])
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
        let verifier = HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try SemanticVersion("1.1.0"))
        return try verifier.verify(archiveBytes: try archive()).manifest
    }

    private func indexObject(
        expiresAt: Date? = nil,
        packageOverrides: [String: JSONValue] = [:]
    ) throws -> [String: JSONValue] {
        let manifest = try manifest()
        let bytes = try archive()
        var package: [String: JSONValue] = [
            "id": .string(manifest.sourceId.value),
            "version": .string(manifest.version.original),
            "hostApi": .object([
                "minInclusive": .string(manifest.hostApiMinInclusive.original),
                "maxExclusive": .string(manifest.hostApiMaxExclusive.original)
            ]),
            "display": .object([
                "name": .string(manifest.displayName),
                "summary": .string(manifest.summary)
            ]),
            "capabilities": try capabilitiesJson(),
            "file": .string("packages/wenku8-fixture.hxp"),
            "sha256": .string(Sha256.hex(bytes)),
            "sizeBytes": .int(bytes.count)
        ]
        for (key, value) in packageOverrides { package[key] = value }
        return [
            "format": .string("tsuyomi-repository"),
            "version": .int(0),
            "repositoryId": .string("org.example.repo"),
            "display": .object(["name": .string("示例仓库"), "summary": .string("测试用仓库")]),
            "publisher": .object([
                "keyId": .string(Phase2TestPublisher.keyId),
                "publicKey": .string(Phase2TestPublisher.publicKeyHex)
            ]),
            "issuedAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(-3600))),
            "expiresAt": .string(ProtocolTimestamp.format(expiresAt ?? now.addingTimeInterval(86_400))),
            "packages": .array([.object(package)]),
            "revocations": .array([])
        ]
    }

    /// The capability block the fixture manifest declares, read back out of the archive so the index
    /// and the manifest agree by construction unless a test deliberately changes one.
    private func capabilitiesJson() throws -> JSONValue {
        let limits = HxpArchiveLimits()
        let reader = try ZipReader(
            try archive(),
            maximumFileBytes: limits.maximumFileBytes,
            maximumFileCount: limits.maximumFileCount
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "manifest.json" })
        let manifestBytes = try reader.read(entry, maximumCompressionRatio: limits.maximumCompressionRatio)
        let root = try XCTUnwrap(
            try JSONDecoder().decode(JSONValue.self, from: manifestBytes).objectValue
        )
        return try XCTUnwrap(root["capabilities"])
    }

    private func signed(_ object: [String: JSONValue]) throws -> (index: Data, signature: Data) {
        let canonical = try Rfc8785.canonicalize(.object(object))
        let signature = try signingKey.signature(
            for: RepositoryIndexCodec.signaturePrefix + canonical
        )
        return (canonical, signature)
    }

    func testAWellFormedIndexIsAccepted() throws {
        let payload = try signed(try indexObject())
        let index = try RepositoryIndexCodec.decode(
            indexBytes: payload.index,
            signature: payload.signature,
            now: now
        )
        XCTAssertEqual(index.repositoryId, "org.example.repo")
        XCTAssertEqual(index.packages.count, 1)
        XCTAssertEqual(index.packages[0].id.value, "org.tsuyomi.wenku8")
        XCTAssertFalse(index.publisher.fingerprint.isEmpty)
    }

    func testAnHttpBaseIsRefusedBeforeAnyRequest() throws {
        XCTAssertThrowsError(try ExtensionRepositoryClient.normalize("http://example.org/repo")) { error in
            XCTAssertEqual(error as? RepositoryError, .insecureTransport)
        }
        XCTAssertThrowsError(try ExtensionRepositoryClient.normalize("https://example.org/repo?token=1"))
    }

    func testAnExpiredIndexIsRefused() throws {
        let payload = try signed(try indexObject(expiresAt: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(
            try RepositoryIndexCodec.decode(
                indexBytes: payload.index,
                signature: payload.signature,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .indexExpired)
        }
    }

    func testAWrongSignatureIsRefused() throws {
        let payload = try signed(try indexObject())
        var tampered = payload.signature
        tampered[0] ^= 0xFF
        XCTAssertThrowsError(
            try RepositoryIndexCodec.decode(indexBytes: payload.index, signature: tampered, now: now)
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidSignature)
        }
    }

    func testADigestMismatchIsRefusedBeforeVerification() throws {
        let manifest = try manifest()
        let bytes = try archive()
        let listed = RepositoryPackage(
            id: manifest.sourceId,
            version: manifest.version,
            hostApiMinInclusive: manifest.hostApiMinInclusive,
            hostApiMaxExclusive: manifest.hostApiMaxExclusive,
            displayName: manifest.displayName,
            summary: manifest.summary,
            capabilities: manifest.capabilities,
            file: "packages/wenku8-fixture.hxp",
            sha256: String(repeating: "0", count: 64),
            sizeBytes: bytes.count
        )
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: listed,
                manifest: manifest,
                archiveBytes: bytes,
                hostApi: try SemanticVersion("1.1.0"),
                activeVersion: nil
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .packageDigestMismatch)
        }
    }

    func testIndexCapabilitiesThatDisagreeWithTheManifestAreRefused() throws {
        let manifest = try manifest()
        let bytes = try archive()
        let listed = RepositoryPackage(
            id: manifest.sourceId,
            version: manifest.version,
            hostApiMinInclusive: manifest.hostApiMinInclusive,
            hostApiMaxExclusive: manifest.hostApiMaxExclusive,
            displayName: manifest.displayName,
            summary: manifest.summary,
            capabilities: HxpCapabilities(
                network: manifest.capabilities.network,
                cookies: manifest.capabilities.cookies,
                webLogin: manifest.capabilities.webLogin,
                home: manifest.capabilities.home,
                remoteLibrary: manifest.capabilities.remoteLibrary,
                storageQuotaBytes: manifest.capabilities.storageQuotaBytes + 1
            ),
            file: "packages/wenku8-fixture.hxp",
            sha256: Sha256.hex(bytes),
            sizeBytes: bytes.count
        )
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: listed,
                manifest: manifest,
                archiveBytes: bytes,
                hostApi: try SemanticVersion("1.1.0"),
                activeVersion: nil
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .indexManifestMismatch)
        }
    }

    func testAVersionRollbackIsRefused() throws {
        let manifest = try manifest()
        let bytes = try archive()
        let listed = RepositoryPackage(
            id: manifest.sourceId,
            version: manifest.version,
            hostApiMinInclusive: manifest.hostApiMinInclusive,
            hostApiMaxExclusive: manifest.hostApiMaxExclusive,
            displayName: manifest.displayName,
            summary: manifest.summary,
            capabilities: manifest.capabilities,
            file: "packages/wenku8-fixture.hxp",
            sha256: Sha256.hex(bytes),
            sizeBytes: bytes.count
        )
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: listed,
                manifest: manifest,
                archiveBytes: bytes,
                hostApi: try SemanticVersion("1.1.0"),
                activeVersion: manifest.version
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .downgradeRejected)
        }
    }

    func testUnsafePackagePathsAreRefused() throws {
        for path in ["/absolute", "../escape", "https://elsewhere/x.hxp", "a//b", "with space"] {
            XCTAssertThrowsError(try RepositoryIndexCodec.requireSafeRelativePath(path), path)
        }
        XCTAssertNoThrow(try RepositoryIndexCodec.requireSafeRelativePath("packages/a-1.0.0.hxp"))
    }
}
