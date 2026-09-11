// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

enum TestFixtures {
    static func data(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return try Data(contentsOf: url.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }
}

/// The built-in root key is proven against the catalog the official repository actually published,
/// read at an instant inside that catalog's validity. A key that verifies nothing real would ship a
/// repository nobody can use; a key that verifies the wrong thing would be worse.
final class OfficialRepositoryTests: XCTestCase {
    private let inside = Date(timeIntervalSince1970: 1_789_128_000)

    func testTheBuiltInRootKeyVerifiesThePublishedCatalog() throws {
        let descriptor = try OfficialRepository.descriptor(addedAt: inside)
        let index = try RepositoryIndexCodec.decode(
            try TestFixtures.data("official-index-v1-sequence-1.json"),
            rootPublicKey: descriptor.rootPublicKey,
            now: inside
        )
        XCTAssertEqual(index.repositoryId, OfficialRepository.repositoryId)
        XCTAssertEqual(index.rootKeyId, descriptor.rootKeyId)
        XCTAssertEqual(index.sequence, 1)
        let publisher = try OfficialRepository.publisher(approvedAt: inside)
        XCTAssertEqual(index.publishers.map(\.keyId), [publisher.keyId])
        XCTAssertEqual(index.publishers.map(\.publicKey), [publisher.publicKey])
        XCTAssertEqual(publisher.trust, .builtInOfficial)
        XCTAssertEqual(publisher.repositoryId, OfficialRepository.repositoryId)
        let wenku8 = try XCTUnwrap(index.packages.first)
        XCTAssertEqual(wenku8.id.value, "org.tsuyomi.wenku8")
        XCTAssertEqual(wenku8.publisherKeyId, publisher.keyId)
        XCTAssertTrue(wenku8.acceptsHostApi(try SemanticVersion("1.2.0")))
        XCTAssertEqual(wenku8.downloadUrl.host, "github.com")
        XCTAssertNotNil(wenku8.legacyMigration)
    }

    func testAnotherKeyDoesNotVerifyThePublishedCatalog() throws {
        XCTAssertThrowsError(
            try RepositoryIndexCodec.decode(
                try TestFixtures.data("official-index-v1-sequence-1.json"),
                rootPublicKey: try ExtensionRepositoryClient.rootKey(OfficialRepository.publisherPublicKey),
                now: inside
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .invalidSignature)
        }
    }

    func testTheOfficialAddressIsAHttpsCatalogLocation() throws {
        let descriptor = try OfficialRepository.descriptor(addedAt: inside)
        XCTAssertEqual(descriptor.indexUrl.scheme, "https")
        XCTAssertEqual(descriptor.indexUrl.host, "raw.githubusercontent.com")
        XCTAssertTrue(descriptor.indexUrl.path.hasSuffix("/repository/index-v1.json"))
        XCTAssertEqual(descriptor.rootPublicKey.count, 32)
    }
}
