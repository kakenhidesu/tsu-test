// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// The inputs §6.8 requires a host to refuse, restated for the v1 catalog, plus the accepted baseline
/// they are each one step away from. Catalogs are built and root-signed here; nothing is committed.
final class RepositoryIndexTests: XCTestCase {
    private static let rootSeed = Data((33...64).map(UInt8.init))
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private var rootKey: Curve25519.Signing.PrivateKey {
        get throws { try Curve25519.Signing.PrivateKey(rawRepresentation: RepositoryIndexTests.rootSeed) }
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
        let verifier = HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try SemanticVersion("1.2.0"))
        return try verifier.verify(archiveBytes: try archive()).manifest
    }

    private func packageObject(overrides: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        let manifest = try manifest()
        let bytes = try archive()
        var package: [String: JSONValue] = [
            "id": .string(manifest.sourceId.value),
            "name": .string(manifest.displayName),
            "version": .string(manifest.version.original),
            "summary": .string(manifest.summary),
            "language": .string("zh-CN"),
            "license": .string("AGPL-3.0-only"),
            "sourceUrl": .string("https://example.org/source"),
            "sourceRevision": .string(String(repeating: "a", count: 40)),
            "downloadUrl": .string("https://cdn.example.org/packages/wenku8.hxp"),
            "size": .int(bytes.count),
            "sha256": .string(Sha256.hex(bytes)),
            "hostApi": .object([
                "minInclusive": .string(manifest.hostApiMinInclusive.original),
                "maxExclusive": .string(manifest.hostApiMaxExclusive.original)
            ]),
            "publisherKeyId": .string(Phase2TestPublisher.keyId)
        ]
        for (key, value) in overrides { package[key] = value }
        return package
    }

    private func signedObject(
        expiresAt: Date? = nil,
        sequence: Int = 1,
        package: [String: JSONValue]? = nil
    ) throws -> [String: JSONValue] {
        let publicKey = try XCTUnwrap(Data(hex: Phase2TestPublisher.publicKeyHex))
        return [
            "repositoryId": .string("org.example.repo"),
            "sequence": .int(sequence),
            "issuedAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(-3600))),
            "expiresAt": .string(ProtocolTimestamp.format(expiresAt ?? now.addingTimeInterval(86_400))),
            "publishers": .array([
                .object([
                    "keyId": .string(Phase2TestPublisher.keyId),
                    "publicKey": .string(publicKey.base64EncodedString()),
                    "fingerprint": .string(Sha256.hex(publicKey))
                ])
            ]),
            "packages": .array([.object(try package ?? packageObject())]),
            "revocations": .object(["publisherFingerprints": .array([]), "packageDigests": .array([])])
        ]
    }

    private func envelope(_ signed: [String: JSONValue], signature: Data? = nil) throws -> Data {
        let canonical = try Rfc8785.canonicalize(.object(signed))
        let bytes = try signature ?? rootKey.signature(for: RepositoryIndexCodec.signaturePrefix + canonical)
        return try Rfc8785.canonicalize(
            .object([
                "format": .string("tsuyomi-repository"),
                "version": .int(1),
                "keyId": .string("tsuyomi-test-root"),
                "signed": .object(signed),
                "signature": .string(bytes.base64EncodedString())
            ])
        )
    }

    private func decode(_ bytes: Data, key: Data? = nil) throws -> RepositoryIndex {
        try RepositoryIndexCodec.decode(bytes, rootPublicKey: try key ?? rootKey.publicKey.rawRepresentation, now: now)
    }

    private func listed(sha256: String? = nil, publisherKeyId: String = Phase2TestPublisher.keyId) throws -> RepositoryPackage {
        let manifest = try manifest()
        let bytes = try archive()
        return RepositoryPackage(
            id: manifest.sourceId,
            version: manifest.version,
            hostApiMinInclusive: manifest.hostApiMinInclusive,
            hostApiMaxExclusive: manifest.hostApiMaxExclusive,
            displayName: manifest.displayName,
            summary: manifest.summary,
            language: "zh-CN",
            license: "AGPL-3.0-only",
            sourceUrl: try XCTUnwrap(URL(string: "https://example.org/source")),
            sourceRevision: String(repeating: "a", count: 40),
            downloadUrl: try XCTUnwrap(URL(string: "https://cdn.example.org/packages/wenku8.hxp")),
            sha256: sha256 ?? Sha256.hex(bytes),
            sizeBytes: bytes.count,
            publisherKeyId: publisherKeyId,
            legacyMigration: nil
        )
    }

    func testAWellFormedCatalogIsAccepted() throws {
        let index = try decode(try envelope(try signedObject()))
        XCTAssertEqual(index.repositoryId, "org.example.repo")
        XCTAssertEqual(index.sequence, 1)
        XCTAssertEqual(index.rootKeyId, "tsuyomi-test-root")
        XCTAssertEqual(index.publishers.map(\.keyId), [Phase2TestPublisher.keyId])
        XCTAssertEqual(index.packages.count, 1)
        XCTAssertEqual(index.packages[0].id.value, "org.tsuyomi.wenku8")
        XCTAssertEqual(index.packages[0].publisherKeyId, Phase2TestPublisher.keyId)
        XCTAssertNil(index.packages[0].legacyMigration)
        XCTAssertEqual(RepositoryIndexCodec.sequence(of: try envelope(try signedObject(sequence: 7))), 7)
        XCTAssertEqual(
            RepositoryIndexCodec.signedDigest(of: try envelope(try signedObject())),
            RepositoryIndexCodec.signedDigest(of: try envelope(try signedObject()))
        )
        XCTAssertNotEqual(
            RepositoryIndexCodec.signedDigest(of: try envelope(try signedObject())),
            RepositoryIndexCodec.signedDigest(of: try envelope(try signedObject(sequence: 2)))
        )
    }

    /// The protocol's own deterministic vectors: the fixture catalog verifies under the fixture root,
    /// and the two invalid vectors — a repeated key and an unknown field — are refused.
    func testTheProtocolFixtureCatalogVerifiesUnderItsFixtureRoot() throws {
        let rootKey = try XCTUnwrap(
            try JSONValue.decode(try ExtensionFixtures.protocolFixture("repository/fixture-root-key.json")).objectValue
        )
        let key = try ExtensionRepositoryClient.rootKey(try XCTUnwrap(rootKey.string("publicKey")))
        let inside = Date(timeIntervalSince1970: 1_893_542_400)
        let index = try RepositoryIndexCodec.decode(
            try ExtensionFixtures.protocolFixture("repository/valid-catalog.json"),
            rootPublicKey: key,
            now: inside
        )
        XCTAssertEqual(index.repositoryId, "org.tsuyomi.extensions")
        XCTAssertEqual(index.rootKeyId, rootKey.string("keyId"))
        XCTAssertEqual(index.publishers.map(\.keyId), ["fixture-publisher-key"])
        XCTAssertEqual(index.packages.map(\.id.value), ["org.tsuyomi.fixture"])
        for name in ["invalid-catalog-duplicate-key", "invalid-catalog-unknown-field"] {
            XCTAssertThrowsError(
                try RepositoryIndexCodec.decode(
                    try ExtensionFixtures.protocolFixture("repository/\(name).json"),
                    rootPublicKey: key,
                    now: inside
                ),
                name
            ) { error in
                XCTAssertEqual(error as? RepositoryError, .invalidIndex, name)
            }
        }
    }

    func testTheProtocolSubscriptionLinkVectorsAreParsedAsPublished() throws {
        let cases = try XCTUnwrap(
            try JSONValue.decode(try ExtensionFixtures.protocolFixture("repository/subscription-link-cases.json")).objectValue
        )
        let valid = try RepositorySubscriptionLink.parse(try XCTUnwrap(cases.string("valid")))
        XCTAssertEqual(valid.repositoryId, "org.example.extensions")
        XCTAssertEqual(valid.keyId, "example-root-key")
        XCTAssertEqual(valid.indexUrl.absoluteString, "https://publisher.example/extensions/index-v1.json")
        XCTAssertEqual(valid.rootPublicKey.count, 32)
        let published = try XCTUnwrap(
            try JSONValue.decode(try ExtensionFixtures.protocolFixture("repository/valid-subscription-link.json")).stringValue
        )
        XCTAssertEqual(try RepositorySubscriptionLink.parse(published), valid)
        for invalid in (cases.array("invalid") ?? []).compactMap(\.stringValue) {
            XCTAssertThrowsError(try RepositorySubscriptionLink.parse(invalid), invalid) { error in
                XCTAssertEqual(error as? RepositoryError, .invalidSubscriptionLink, invalid)
            }
        }
    }

    func testACatalogIssuedInTheFutureIsRefused() throws {
        var signed = try signedObject()
        signed["issuedAt"] = .string(ProtocolTimestamp.format(now.addingTimeInterval(600)))
        XCTAssertThrowsError(try decode(try envelope(signed))) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidIndex)
        }
    }

    func testARepeatedKeyInsideTheSignedBodyIsRefused() throws {
        let canonical = try envelope(try signedObject())
        let text = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let doubled = text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1,\"sequence\":1")
        XCTAssertNotEqual(doubled, text)
        XCTAssertThrowsError(try decode(Data(doubled.utf8))) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidIndex)
        }
    }

    func testAnInsecureAddressOrKeyIsRefusedBeforeAnyRequest() throws {
        XCTAssertThrowsError(try ExtensionRepositoryClient.normalize(indexUrl: "http://example.org/index-v1.json")) { error in
            XCTAssertEqual(error as? RepositoryError, .insecureTransport)
        }
        XCTAssertThrowsError(try ExtensionRepositoryClient.normalize(indexUrl: "https://example.org/index-v1.json#x"))
        XCTAssertNoThrow(try ExtensionRepositoryClient.normalize(indexUrl: "https://example.org/r/index-v1.json"))
        XCTAssertThrowsError(try ExtensionRepositoryClient.rootKey("not base64")) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidRootKey)
        }
        XCTAssertThrowsError(try ExtensionRepositoryClient.rootKey(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertNoThrow(try ExtensionRepositoryClient.rootKey(Data(repeating: 1, count: 32).base64EncodedString()))
    }

    func testAnExpiredCatalogIsRefused() throws {
        XCTAssertThrowsError(try decode(try envelope(try signedObject(expiresAt: now.addingTimeInterval(-1))))) { error in
            XCTAssertEqual(error as? RepositoryError, .indexExpired)
        }
    }

    func testALifetimeOverThirtyDaysIsRefused() throws {
        let long = try signedObject(expiresAt: now.addingTimeInterval(31 * 24 * 3600))
        XCTAssertThrowsError(try decode(try envelope(long))) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidIndex)
        }
    }

    func testAWrongSignatureOrRootKeyIsRefused() throws {
        let signed = try signedObject()
        XCTAssertThrowsError(try decode(try envelope(signed, signature: Data(repeating: 7, count: 64)))) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidSignature)
        }
        let otherKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
        XCTAssertThrowsError(try decode(try envelope(signed), key: otherKey.publicKey.rawRepresentation)) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidSignature)
        }
    }

    func testAnInsecureDownloadUrlIsRefused() throws {
        let package = try packageObject(overrides: ["downloadUrl": .string("http://cdn.example.org/wenku8.hxp")])
        XCTAssertThrowsError(try decode(try envelope(try signedObject(package: package)))) { error in
            XCTAssertEqual(error as? RepositoryError, .unsafePackageUrl)
        }
        for text in ["https://user:pw@cdn.example.org/a.hxp", "https://cdn.example.org/a.hxp#x", "https://cdn.example.org/a b", "https:///a"] {
            XCTAssertThrowsError(try RepositoryIndexCodec.requireHttpsUrl(text), text)
        }
        XCTAssertNoThrow(try RepositoryIndexCodec.requireHttpsUrl("https://github.com/o/r/releases/download/t/a-1.0.0.hxp"))
    }

    func testAPackageSignedByAnUnlistedPublisherIsRefused() throws {
        let package = try packageObject(overrides: ["publisherKeyId": .string("somebody-else-v1")])
        XCTAssertThrowsError(try decode(try envelope(try signedObject(package: package)))) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidIndex)
        }
    }

    func testADigestMismatchIsRefusedBeforeVerification() throws {
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: try listed(sha256: String(repeating: "0", count: 64)),
                manifest: try manifest(),
                archiveBytes: try archive(),
                hostApi: try SemanticVersion("1.2.0"),
                activeVersion: nil
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .packageDigestMismatch)
        }
    }

    func testAListingThatDisagreesWithTheManifestPublisherIsRefused() throws {
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: try listed(publisherKeyId: "somebody-else-v1"),
                manifest: try manifest(),
                archiveBytes: try archive(),
                hostApi: try SemanticVersion("1.2.0"),
                activeVersion: nil
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .indexManifestMismatch)
        }
    }

    func testAVersionRollbackIsRefused() throws {
        let manifest = try manifest()
        XCTAssertThrowsError(
            try RepositoryInstallPolicy.requireInstallable(
                listed: try listed(),
                manifest: manifest,
                archiveBytes: try archive(),
                hostApi: try SemanticVersion("1.2.0"),
                activeVersion: manifest.version
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .downgradeRejected)
        }
    }
}
