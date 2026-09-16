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
    /// A disabled repository is neither fetched nor offered, but keeps its identity, cache and
    /// revocations exactly as a removed one does.
    public let enabled: Bool

    public init(repositoryId: String, indexUrl: URL, rootKeyId: String, rootPublicKey: Data, addedAt: Date, enabled: Bool = true) {
        self.repositoryId = repositoryId
        self.indexUrl = indexUrl
        self.rootKeyId = rootKeyId
        self.rootPublicKey = rootPublicKey
        self.addedAt = addedAt
        self.enabled = enabled
    }

    public var isOfficial: Bool { OfficialRepository.isRoot(rootPublicKey) }

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

    /// Reads the catalog a subscription link points at, verified against the root the link names.
    /// The catalog has to claim the very identity the link declared: a root that signs for another
    /// repository id or key id is a different repository, not this one.
    public func probe(link text: String) async throws -> (descriptor: RepositoryDescriptor, fetched: FetchedRepositoryIndex) {
        let link = try RepositorySubscriptionLink.parse(text)
        let fetched = try await read(link.indexUrl, rootPublicKey: link.rootPublicKey)
        guard fetched.index.repositoryId == link.repositoryId, fetched.index.rootKeyId == link.keyId else {
            throw RepositoryError.repositoryIdentityMismatch
        }
        return (
            RepositoryDescriptor(
                repositoryId: link.repositoryId,
                indexUrl: link.indexUrl,
                rootKeyId: link.keyId,
                rootPublicKey: link.rootPublicKey,
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

    /// Only the built-in official root may authorize a publisher change: a user-added root that
    /// carries `legacyMigration` is refused whole, so the exception can never be reached through it.
    private func read(_ url: URL, rootPublicKey: Data) async throws -> FetchedRepositoryIndex {
        let bytes = try await gateway.fetchStaticResource(
            url: url,
            maximumBytes: RepositoryIndexCodec.maximumIndexBytes
        )
        let index = try RepositoryIndexCodec.decode(bytes, rootPublicKey: rootPublicKey, now: clock())
        if !OfficialRepository.isRoot(rootPublicKey), index.packages.contains(where: { $0.legacyMigration != nil }) {
            throw RepositoryError.unauthorizedMigration
        }
        return FetchedRepositoryIndex(index: index, bytes: bytes)
    }

    /// A catalog address is fetched exactly as written, minus nothing: HTTPS, a host, no credentials
    /// and no fragment, which the subscription link has already taken for itself.
    public static func normalize(indexUrl: String) throws -> URL {
        guard let url = try? RepositoryIndexCodec.requireHttpsUrl(indexUrl) else {
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
