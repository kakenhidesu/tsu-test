// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// Builds and root-signs a `tsuyomi-repository` v1 catalog over real archives, so the catalog and the
/// packages it lists agree by construction. Signed with a public test seed; nothing is committed.
enum MarketIndexBuilder {
    struct Listing {
        let archive: Data
        let publisher: HxpTestArchive.Publisher
        let legacyMigration: LegacyMigration?

        init(_ archive: Data, publisher: HxpTestArchive.Publisher = .fixture, legacyMigration: LegacyMigration? = nil) {
            self.archive = archive
            self.publisher = publisher
            self.legacyMigration = legacyMigration
        }
    }

    static let rootSeed = Data((33...64).map(UInt8.init))
    static let rootKeyId = "tsuyomi-test-root"

    static func rootPublicKeyBase64() throws -> String {
        try Curve25519.Signing.PrivateKey(rawRepresentation: rootSeed).publicKey.rawRepresentation.base64EncodedString()
    }

    static func downloadUrl(for archive: Data) -> String {
        "https://repo.example.org/packages/\(Sha256.hex(archive)).hxp"
    }

    static func build(
        _ listings: [Listing],
        sequence: Int,
        revokedPackageDigests: [String] = [],
        now: Date = Date()
    ) throws -> Data {
        var publishers: [JSONValue] = []
        var seenPublishers = Set<String>()
        var packages: [JSONValue] = []
        for listing in listings {
            if seenPublishers.insert(listing.publisher.keyId).inserted {
                publishers.append(
                    .object([
                        "keyId": .string(listing.publisher.keyId),
                        "publicKey": .string(try listing.publisher.publicKey().base64EncodedString())
                    ])
                )
            }
            let manifest = try manifestObject(listing.archive)
            var package: [String: JSONValue] = [
                "id": .string(try XCTUnwrap(manifest.string("id"))),
                "name": .string(try XCTUnwrap(manifest.object("display")?.string("name"))),
                "version": .string(try XCTUnwrap(manifest.string("version"))),
                "summary": .string(try XCTUnwrap(manifest.object("display")?.string("summary"))),
                "language": .string("zh-CN"),
                "license": .string("AGPL-3.0-only"),
                "sourceUrl": .string("https://example.org/source/tsuyomi"),
                "sourceRevision": .string(String(repeating: "0", count: 40)),
                "downloadUrl": .string(downloadUrl(for: listing.archive)),
                "size": .int(listing.archive.count),
                "sha256": .string(Sha256.hex(listing.archive)),
                "hostApi": .object([
                    "minInclusive": .string(try XCTUnwrap(manifest.object("hostApi")?.string("minInclusive"))),
                    "maxExclusive": .string(try XCTUnwrap(manifest.object("hostApi")?.string("maxExclusive")))
                ]),
                "publisherKeyId": .string(listing.publisher.keyId)
            ]
            if let migration = listing.legacyMigration {
                package["legacyMigration"] = .object([
                    "fromPublisherFingerprint": .string(migration.fromPublisherFingerprint),
                    "fromPackageSha256": .string(migration.fromPackageSha256)
                ])
            }
            packages.append(.object(package))
        }
        let signed: [String: JSONValue] = [
            "repositoryId": .string("org.example.repo"),
            "sequence": .int(sequence),
            "issuedAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(-3600))),
            "expiresAt": .string(ProtocolTimestamp.format(now.addingTimeInterval(86_400))),
            "publishers": .array(publishers),
            "packages": .array(packages),
            "revocations": .object([
                "publisherFingerprints": .array([]),
                "packageDigests": .array(revokedPackageDigests.map(JSONValue.string))
            ])
        ]
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rootSeed)
        let signature = try key.signature(
            for: RepositoryIndexCodec.signaturePrefix + (try Rfc8785.canonicalize(.object(signed)))
        )
        return try Rfc8785.canonicalize(
            .object([
                "format": .string("tsuyomi-repository"),
                "version": .int(1),
                "keyId": .string(rootKeyId),
                "signed": .object(signed),
                "signature": .string(signature.base64EncodedString())
            ])
        )
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
