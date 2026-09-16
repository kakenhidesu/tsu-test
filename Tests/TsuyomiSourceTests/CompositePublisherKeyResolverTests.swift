// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import TsuyomiSource

private struct FixedResolver: PublisherKeyResolver {
    let keys: [String: PublisherKey]
    var revokedFingerprints: Set<String> = []
    var revokedPackages: Set<String> = []

    func resolve(keyId: String) -> PublisherKey? { keys[keyId] }
    func isRevokedFingerprint(_ fingerprint: String) -> Bool { revokedFingerprints.contains(fingerprint) }
    func isRevokedPackage(_ packageSha256: String) -> Bool { revokedPackages.contains(packageSha256) }
}

/// One key id may be known to several trust sources. The built-in identity always wins, two
/// declarations that disagree cancel each other, and a revocation anywhere is a revocation.
final class CompositePublisherKeyResolverTests: XCTestCase {
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    private func key(_ bytes: Data, _ trust: PublisherTrust) throws -> PublisherKey {
        try PublisherKey(keyId: "shared", publicKey: bytes, trust: trust)
    }

    func testABuiltInIdentityShadowsAUserAddedDeclaration() throws {
        let resolver = CompositePublisherKeyResolver([
            FixedResolver(keys: ["shared": try key(keyB, .userAdded)]),
            FixedResolver(keys: ["shared": try key(keyA, .builtInOfficial)])
        ])
        let resolved = try XCTUnwrap(resolver.resolve(keyId: "shared"))
        XCTAssertEqual(resolved.publicKey, keyA)
        XCTAssertEqual(resolved.trust, .builtInOfficial)
    }

    func testTestTrustBeatsUserAddedButNotOfficial() throws {
        let resolver = CompositePublisherKeyResolver([
            FixedResolver(keys: ["shared": try key(keyB, .userAdded)]),
            FixedResolver(keys: ["shared": try key(keyA, .builtInTest)])
        ])
        XCTAssertEqual(resolver.resolve(keyId: "shared")?.trust, .builtInTest)
    }

    func testTwoDeclarationsInOneTierThatDisagreeResolveToNothing() throws {
        let resolver = CompositePublisherKeyResolver([
            FixedResolver(keys: ["shared": try key(keyA, .userAdded)]),
            FixedResolver(keys: ["shared": try key(keyB, .userAdded)])
        ])
        XCTAssertNil(resolver.resolve(keyId: "shared"))
        let agreeing = CompositePublisherKeyResolver([
            FixedResolver(keys: ["shared": try key(keyA, .userAdded)]),
            FixedResolver(keys: ["shared": try key(keyA, .userAdded)])
        ])
        XCTAssertEqual(agreeing.resolve(keyId: "shared")?.publicKey, keyA)
    }

    func testRevocationIsTheUnion() {
        let resolver = CompositePublisherKeyResolver([
            FixedResolver(keys: [:], revokedFingerprints: ["f1"]),
            FixedResolver(keys: [:], revokedPackages: ["p1"])
        ])
        XCTAssertTrue(resolver.isRevokedFingerprint("f1"))
        XCTAssertTrue(resolver.isRevokedPackage("p1"))
        XCTAssertFalse(resolver.isRevokedFingerprint("p1"))
        XCTAssertNil(resolver.resolve(keyId: "absent"))
    }
}
