// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// Builds and signs a `tsuyomi-repository` v0 index over real archives, so the index and the packages
/// it lists agree by construction. Signed with the public fixture seed; nothing is committed.
enum MarketIndexBuilder {
    static func build(
        packages archives: [Data],
        revokingPackageDigest digest: String?,
        now: Date = Date()
    ) throws -> (bytes: Data, signature: Data) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: HxpTestArchive.seed)
        var listed: [JSONValue] = []
        for archive in archives {
            let manifest = try manifestObject(archive)
            listed.append(
                .object([
                    "id": .string(try XCTUnwrap(manifest.string("id"))),
                    "version": .string(try XCTUnwrap(manifest.string("version"))),
                    "hostApi": .object([
                        "minInclusive": .string(try XCTUnwrap(manifest.object("hostApi")?.string("minInclusive"))),
                        "maxExclusive": .string(try XCTUnwrap(manifest.object("hostApi")?.string("maxExclusive")))
                    ]),
                    "display": .object([
                        "name": .string(try XCTUnwrap(manifest.object("display")?.string("name"))),
                        "summary": .string(try XCTUnwrap(manifest.object("display")?.string("summary")))
                    ]),
                    "capabilities": try XCTUnwrap(manifest["capabilities"]),
                    "file": .string("packages/source.hxp"),
                    "sha256": .string(Sha256.hex(archive)),
                    "sizeBytes": .int(archive.count)
                ])
            )
        }

        var revocations: [JSONValue] = []
        if let digest {
            var entry: [String: JSONValue] = [
                "target": .object(["packageDigest": .string(digest)]),
                "reasonCode": .string("compromised"),
                "issuedAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(-60))),
                "expiresAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(86_400)))
            ]
            let signature = try key.signature(
                for: RepositoryIndexCodec.revocationPrefix + (try Rfc8785.canonicalize(.object(entry)))
            )
            entry["signature"] = .string(RepositoryIndexCodec.hex(signature))
            revocations.append(.object(entry))
        }

        let index: [String: JSONValue] = [
            "format": .string("tsuyomi-repository"),
            "version": .int(0),
            "repositoryId": .string("org.example.repo"),
            "display": .object(["name": .string("示例仓库"), "summary": .string("端到端测试仓库")]),
            "publisher": .object([
                "keyId": .string(Phase2TestPublisher.keyId),
                "publicKey": .string(Phase2TestPublisher.publicKeyHex)
            ]),
            "issuedAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(-3600))),
            "expiresAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(86_400))),
            "packages": .array(listed),
            "revocations": .array(revocations)
        ]
        let canonical = try Rfc8785.canonicalize(.object(index))
        return (canonical, try key.signature(for: RepositoryIndexCodec.signaturePrefix + canonical))
    }

    static func manifestObject(_ archive: Data) throws -> [String: JSONValue] {
        let limits = HxpArchiveLimits()
        let reader = try ZipReader(
            archive,
            maximumFileBytes: limits.maximumFileBytes,
            maximumFileCount: limits.maximumFileCount
        )
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "manifest.json" })
        let bytes = try reader.read(entry, maximumCompressionRatio: limits.maximumCompressionRatio)
        return try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
    }
}

extension MarketIndexBuilder {
    /// The digest a revocation names. It identifies the package's content, not one particular zip, so
    /// repackaging the same payload does not escape a revocation.
    static func contentDigest(of archive: Data) throws -> String {
        try XCTUnwrap(try manifestObject(archive).object("integrity")?.string("contentDigest"))
    }
}
