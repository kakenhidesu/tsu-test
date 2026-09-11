// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public struct RepositoryDescriptor: Hashable, Sendable {
    public let repositoryId: String
    public let indexUrl: URL
    public let rootKeyId: String
    public let rootPublicKey: Data
    public let addedAt: Date

    public init(repositoryId: String, indexUrl: URL, rootKeyId: String, rootPublicKey: Data, addedAt: Date) {
        self.repositoryId = repositoryId
        self.indexUrl = indexUrl
        self.rootKeyId = rootKeyId
        self.rootPublicKey = rootPublicKey
        self.addedAt = addedAt
    }

    public var rootKey: RepositoryPublisher {
        RepositoryPublisher(keyId: rootKeyId, publicKey: rootPublicKey)
    }
}

public struct FetchedRepositoryIndex: Sendable {
    public let index: RepositoryIndex
    public let bytes: Data
}

/// Fetches and verifies one repository. It performs no installation: a downloaded archive is handed
/// to the same `HxpArchiveVerifier → ExtensionInstaller` path a local `.hxp` takes, so the market
/// cannot become a second, weaker way in.
public struct ExtensionRepositoryClient: Sendable {
    private let gateway: HostNetworkGateway
    private let clock: @Sendable () -> Date

    public init(gateway: HostNetworkGateway, clock: @escaping @Sendable () -> Date = Date.init) {
        self.gateway = gateway
        self.clock = clock
    }

    /// Reads a catalog from a URL and root key the user typed. A v1 catalog does not carry its root
    /// key, so the key is the trust decision: nothing is stored until the next screen is confirmed.
    public func probe(
        indexUrl: String,
        rootPublicKey: String
    ) async throws -> (descriptor: RepositoryDescriptor, fetched: FetchedRepositoryIndex) {
        let url = try ExtensionRepositoryClient.normalize(indexUrl: indexUrl)
        let key = try ExtensionRepositoryClient.rootKey(rootPublicKey)
        let fetched = try await read(url, rootPublicKey: key)
        return (
            RepositoryDescriptor(
                repositoryId: fetched.index.repositoryId,
                indexUrl: url,
                rootKeyId: fetched.index.rootKeyId,
                rootPublicKey: key,
                addedAt: clock()
            ),
            fetched
        )
    }

    /// Refreshing pins the root key and identity the user approved: a catalog signed by any other key,
    /// or claiming another key id or repository, is a signature failure rather than a silent change.
    public func refresh(_ descriptor: RepositoryDescriptor) async throws -> FetchedRepositoryIndex {
        let fetched = try await read(descriptor.indexUrl, rootPublicKey: descriptor.rootPublicKey)
        guard fetched.index.rootKeyId == descriptor.rootKeyId,
              fetched.index.repositoryId == descriptor.repositoryId else {
            throw RepositoryError.invalidSignature
        }
        return fetched
    }

    public func download(_ package: RepositoryPackage) async throws -> Data {
        let bytes = try await gateway.fetchStaticResource(url: package.downloadUrl, maximumBytes: package.sizeBytes)
        guard bytes.count == package.sizeBytes else { throw RepositoryError.packageTooLarge }
        guard Sha256.hex(bytes) == package.sha256 else { throw RepositoryError.packageDigestMismatch }
        return bytes
    }

    private func read(_ url: URL, rootPublicKey: Data) async throws -> FetchedRepositoryIndex {
        let bytes = try await gateway.fetchStaticResource(
            url: url,
            maximumBytes: RepositoryIndexCodec.maximumIndexBytes
        )
        return FetchedRepositoryIndex(
            index: try RepositoryIndexCodec.decode(bytes, rootPublicKey: rootPublicKey, now: clock()),
            bytes: bytes
        )
    }

    /// A catalog address is a location and nothing else: a query string could carry a token, so it is
    /// refused along with everything the package URL rule already refuses.
    public static func normalize(indexUrl: String) throws -> URL {
        guard let url = try? RepositoryIndexCodec.requireHttpsUrl(indexUrl),
              url.query == nil, url.path.count > 1 else {
            throw RepositoryError.insecureTransport
        }
        return url
    }

    public static func rootKey(_ base64: String) throws -> Data {
        guard let key = RepositoryIndexCodec.base64(base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == 32 else {
            throw RepositoryError.invalidRootKey
        }
        return key
    }
}
