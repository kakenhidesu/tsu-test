// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

enum ExtensionFixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Tsuyomi-main").appendingPathComponent("tsuyomi-extensions")
    }()

    static func data(_ relativePath: String) throws -> Data {
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(relativePath); check out Tsuyomi-main next to this repository")
        }
        return try Data(contentsOf: url)
    }

    static func protocolFixture(_ relativePath: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        let target = url
            .appendingPathComponent("Tsuyomi-main")
            .appendingPathComponent("tsuyomi-protocol")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw XCTSkip("Missing fixture \(relativePath)")
        }
        return try Data(contentsOf: target)
    }
}

final class HxpVerificationTests: XCTestCase {
    private let hostApi = try? SemanticVersion("1.1.0")

    private func verifier(_ keys: InMemoryPublisherKeyStore) throws -> HxpArchiveVerifier {
        HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try XCTUnwrap(hostApi))
    }

    private func fixturePackage() throws -> Data {
        try ExtensionFixtures.data("fixtures/wenku8/wenku8-fixture.hxp")
    }

    private func fixtureKeys() throws -> InMemoryPublisherKeyStore {
        #if DEBUG
        return InMemoryPublisherKeyStore(keys: [try Phase2TestPublisher.key()])
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
    }

    func testFixturePackageMatchesItsPublishedDigest() throws {
        let archive = try fixturePackage()
        let expected = try ExtensionFixtures.data("fixtures/wenku8/wenku8-fixture.sha256")
        let published = try XCTUnwrap(String(data: expected, encoding: .utf8))
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
        XCTAssertEqual(Sha256.hex(archive), published)
    }

    func testFixturePackageVerifies() throws {
        let verifier = try verifier(try fixtureKeys())
        let verified = try verifier.verify(archiveBytes: try fixturePackage())
        XCTAssertEqual(verified.manifest.sourceId.value, "org.tsuyomi.wenku8")
        XCTAssertEqual(verified.manifest.entry, "index.mjs")
        XCTAssertEqual(verified.publisherFingerprint.count, 64)
        XCTAssertFalse(verified.entryModuleBytes.isEmpty)
        XCTAssertTrue(verified.manifest.capabilities.network.origins.contains(
            try HttpsOrigin("https://www.wenku8.net")
        ))
    }

    func testOneFlippedByteFailsVerification() throws {
        let verifier = try verifier(try fixtureKeys())
        var archive = try fixturePackage()
        let index = archive.startIndex + archive.count / 2
        archive[index] = archive[index] ^ 0x01
        XCTAssertThrowsError(try verifier.verify(archiveBytes: archive)) { error in
            XCTAssertNotNil(error as? HxpVerificationError)
        }
    }

    func testUnknownAndRevokedPublishersAreRejected() throws {
        let archive = try fixturePackage()
        let empty = try verifier(InMemoryPublisherKeyStore())
        XCTAssertThrowsError(try empty.verify(archiveBytes: archive)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .unknownPublisher)
        }

        let keys = try fixtureKeys()
        let verified = try verifier(keys).verify(archiveBytes: archive)
        keys.revokeFingerprint(verified.publisherFingerprint)
        XCTAssertThrowsError(try verifier(keys).verify(archiveBytes: archive)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .revokedPublisher)
        }

        let packageKeys = try fixtureKeys()
        packageKeys.revokePackage(verified.manifest.contentDigest)
        XCTAssertThrowsError(try verifier(packageKeys).verify(archiveBytes: archive)) { error in
            XCTAssertEqual(error as? HxpVerificationError, .revokedPackage)
        }
    }

    func testIncompatibleHostApiIsRejected() throws {
        let verifier = HxpArchiveVerifier(
            publisherKeys: try fixtureKeys(),
            hostApiVersion: try SemanticVersion("2.0.0")
        )
        XCTAssertThrowsError(try verifier.verify(archiveBytes: try fixturePackage())) { error in
            XCTAssertEqual(error as? HxpVerificationError, .hostApiIncompatible)
        }
    }

    func testMinimalManifestFixtureParses() throws {
        let bytes = try ExtensionFixtures.protocolFixture("hxp/valid-minimal-manifest.json")
        let parsed = try HxpManifestParser.parse(bytes, hostApiVersion: try XCTUnwrap(hostApi))
        XCTAssertEqual(parsed.manifest.sourceId.value, "org.tsuyomi.wenku8")
        XCTAssertEqual(parsed.manifest.version.original, "0.1.0")
        XCTAssertEqual(parsed.manifest.capabilities.storageQuotaBytes, 1_048_576)
        XCTAssertTrue(parsed.manifest.capabilities.home.enabled)
        XCTAssertEqual(parsed.manifest.capabilities.remoteLibrary.writeOperations, ["add", "remove", "move"])
        let addPolicy = try XCTUnwrap(parsed.manifest.capabilities.remoteLibrary.policies[.add])
        XCTAssertEqual(addPolicy.method, .post)
        XCTAssertEqual(addPolicy.redirects.count, 1)
        XCTAssertTrue(addPolicy.parameters.contains(.remoteBookId(name: "aid")))
        let readPolicy = try XCTUnwrap(parsed.manifest.capabilities.remoteLibrary.policies[.read])
        XCTAssertTrue(readPolicy.parameters.contains(.cursor(name: "cursor")))
    }

    func testSemanticVersionOrdering() throws {
        XCTAssertTrue(try SemanticVersion("1.0.0") < (try SemanticVersion("1.0.1")))
        XCTAssertTrue(try SemanticVersion("1.0.0-alpha") < (try SemanticVersion("1.0.0")))
        XCTAssertTrue(try SemanticVersion("1.0.0-alpha.1") < (try SemanticVersion("1.0.0-alpha.2")))
        XCTAssertTrue(try SemanticVersion("1.0.0-alpha") < (try SemanticVersion("1.0.0-beta")))
        XCTAssertEqual(try SemanticVersion("1.2.3+build").original, "1.2.3+build")
        XCTAssertThrowsError(try SemanticVersion("1.2"))
        XCTAssertThrowsError(try SemanticVersion("01.2.3"))
        XCTAssertThrowsError(try SemanticVersion("1.2.3-"))
    }

    func testCanonicalJsonMatchesTheProducerRules() throws {
        let value = JSONValue.object([
            "b": .int(2),
            "a": .string("x\"y\\z\u{1}"),
            "c": .array([.bool(true), .null, .int(-3)])
        ])
        let canonical = try Rfc8785.canonicalize(value)
        XCTAssertEqual(
            String(data: canonical, encoding: .utf8),
            "{\"a\":\"x\\\"y\\\\z\\u0001\",\"b\":2,\"c\":[true,null,-3]}"
        )
    }
}
