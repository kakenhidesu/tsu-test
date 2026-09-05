// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// Drives `package-policy-cases.json` through the single owner of the update rule.
final class PackagePolicyCaseTests: XCTestCase {
    func testEveryPublishedPolicyCase() throws {
        let data = try ExtensionFixtures.protocolFixture("hxp/package-policy-cases.json")
        guard let root = try JSONValue.decode(data).objectValue, let cases = root.array("cases") else {
            return XCTFail("expected a policy case list")
        }
        XCTAssertFalse(cases.isEmpty)
        for element in cases {
            guard let testCase = element.objectValue,
                  let name = testCase.string("name"),
                  let activeJson = testCase.object("active"),
                  let candidateJson = testCase.object("candidate"),
                  let rotationApproved = testCase.bool("rotationVerified"),
                  let expected = testCase.string("expected").flatMap(ExtensionPolicyOutcome.init(rawValue:)) else {
                return XCTFail("malformed policy case")
            }
            let revoked = (testCase.array("revokedKeyIds") ?? []).compactMap(\.stringValue)
            let active = try manifest(activeJson)
            let candidate = try manifest(candidateJson)
            let outcome = ExtensionInstaller.evaluatePolicy(
                candidate: candidate,
                active: active,
                publisherRevoked: revoked.contains(candidate.publisherKeyId),
                rotationApproved: rotationApproved
            )
            XCTAssertEqual(outcome, expected, name)
        }
    }

    func testAFirstInstallAlwaysNeedsAGrant() throws {
        let candidate = try manifest(version: "1.0.0", keyId: "key-a", origins: ["https://a.example"])
        XCTAssertEqual(
            ExtensionInstaller.evaluatePolicy(
                candidate: candidate,
                active: nil,
                publisherRevoked: false,
                rotationApproved: false
            ),
            .requiresGrant
        )
    }

    func testAnAddedOriginNeedsAGrantEvenWhenTheVersionMovesForward() throws {
        let active = try manifest(version: "1.0.0", keyId: "key-a", origins: ["https://a.example"])
        let candidate = try manifest(
            version: "1.1.0",
            keyId: "key-a",
            origins: ["https://a.example", "https://b.example"]
        )
        XCTAssertEqual(
            ExtensionInstaller.evaluatePolicy(
                candidate: candidate,
                active: active,
                publisherRevoked: false,
                rotationApproved: false
            ),
            .requiresGrant
        )
        XCTAssertTrue(
            ExtensionInstaller.addedCapabilities(candidate, active).contains("network:https://b.example")
        )
    }

    private func manifest(_ value: [String: JSONValue]) throws -> HxpManifest {
        guard let version = value.string("version"), let keyId = value.string("keyId"),
              let capabilities = value.object("capabilities") else {
            throw XCTSkip("malformed policy case manifest")
        }
        return try manifest(
            version: version,
            keyId: keyId,
            origins: (capabilities.array("origins") ?? []).compactMap(\.stringValue),
            webLogin: capabilities.bool("webLogin") ?? false,
            home: capabilities.bool("home") ?? false,
            writes: Set((capabilities.array("writes") ?? []).compactMap(\.stringValue)),
            storageQuota: capabilities.int("storageQuota") ?? 0
        )
    }

    private func manifest(
        version: String,
        keyId: String,
        origins: [String],
        webLogin: Bool = false,
        home: Bool = false,
        writes: Set<String> = [],
        storageQuota: Int = 1_024
    ) throws -> HxpManifest {
        let parsedOrigins = Set(try origins.map { try HttpsOrigin($0) })
        return HxpManifest(
            sourceId: try SourceId("org.example.source"),
            version: try SemanticVersion(version),
            displayName: "Example",
            summary: "Policy fixture",
            homepage: nil,
            hostApiMinInclusive: try SemanticVersion("1.0.0"),
            hostApiMaxExclusive: try SemanticVersion("2.0.0"),
            entry: "index.mjs",
            contentDigest: String(repeating: "0", count: 64),
            files: ["index.mjs": String(repeating: "0", count: 64)],
            publisherKeyId: keyId,
            capabilities: HxpCapabilities(
                network: HxpNetworkCapability(
                    origins: parsedOrigins,
                    maximumConcurrentRequests: 2,
                    requestTimeoutMs: 15_000,
                    maximumResponseBytes: 1_048_576
                ),
                cookies: HxpCookieCapability(sourceScoped: false, origins: []),
                webLogin: HxpWebLoginCapability(enabled: webLogin, origins: webLogin ? parsedOrigins : []),
                home: HxpHomeCapability(enabled: home),
                remoteLibrary: HxpRemoteLibraryCapability(read: false, writeOperations: writes, policies: [:]),
                storageQuotaBytes: storageQuota
            ),
            resourceLimits: HxpResourceLimits(
                maximumExecutionWallTimeMs: 15_000,
                maximumMemoryBytes: 16_777_216
            ),
            updateChannel: "stable"
        )
    }
}
