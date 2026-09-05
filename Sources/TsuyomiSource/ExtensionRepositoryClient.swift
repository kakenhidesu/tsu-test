// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public struct RepositoryDescriptor: Hashable, Sendable {
    public let repositoryId: String
    public let base: HttpsOrigin
    public let path: String
    public let publisherKeyId: String
    public let publisherPublicKey: Data
    public let addedAt: Date

    public init(
        repositoryId: String,
        base: HttpsOrigin,
        path: String,
        publisherKeyId: String,
        publisherPublicKey: Data,
        addedAt: Date
    ) {
        self.repositoryId = repositoryId
        self.base = base
        self.path = path
        self.publisherKeyId = publisherKeyId
        self.publisherPublicKey = publisherPublicKey
        self.addedAt = addedAt
    }
}

/// Fetches and verifies one repository. It performs no installation: a downloaded archive is handed
/// to the same `HxpArchiveVerifier → ExtensionInstaller` path a local `.hxp` takes, so the market
/// cannot become a second, weaker way in.
public struct ExtensionRepositoryClient: Sendable {
    private let transport: any HostHttpTransport
    private let clock: @Sendable () -> Date

    public init(transport: any HostHttpTransport, clock: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.clock = clock
    }

    /// Reads an index from a base the user typed. Nothing is trusted yet: the caller shows the
    /// publisher fingerprint and only then writes it to the trust store.
    public func probe(base: String) async throws -> (descriptor: RepositoryDescriptor, index: RepositoryIndex) {
        let normalized = try ExtensionRepositoryClient.normalize(base)
        let index = try await read(origin: normalized.origin, path: normalized.path, expecting: nil)
        return (
            RepositoryDescriptor(
                repositoryId: index.repositoryId,
                base: normalized.origin,
                path: normalized.path,
                publisherKeyId: index.publisher.keyId,
                publisherPublicKey: index.publisher.publicKey,
                addedAt: clock()
            ),
            index
        )
    }

    /// Refreshing an added repository pins the publisher key the user approved, so a changed key is a
    /// signature failure rather than a silent new publisher.
    public func refresh(_ descriptor: RepositoryDescriptor) async throws -> RepositoryIndex {
        try await read(
            origin: descriptor.base,
            path: descriptor.path,
            expecting: descriptor.publisherPublicKey
        )
    }

    public func download(
        _ package: RepositoryPackage,
        from descriptor: RepositoryDescriptor
    ) async throws -> Data {
        let url = try ExtensionRepositoryClient.join(descriptor.base, descriptor.path, package.file)
        let response = try await get(url, maximumBytes: package.sizeBytes)
        guard response.bytes.count == package.sizeBytes else { throw RepositoryError.packageTooLarge }
        guard Sha256.hex(response.bytes) == package.sha256 else {
            throw RepositoryError.packageDigestMismatch
        }
        return response.bytes
    }

    private func read(
        origin: HttpsOrigin,
        path: String,
        expecting publicKey: Data?
    ) async throws -> RepositoryIndex {
        let indexBytes = try await get(
            try ExtensionRepositoryClient.join(origin, path, "index.json"),
            maximumBytes: RepositoryIndexCodec.maximumIndexBytes
        ).bytes
        let signature = try await get(
            try ExtensionRepositoryClient.join(origin, path, "index.sig"),
            maximumBytes: 64
        ).bytes
        return try RepositoryIndexCodec.decode(
            indexBytes: indexBytes,
            signature: signature,
            now: clock(),
            expectedPublicKey: publicKey
        )
    }

    private func get(_ url: URL, maximumBytes: Int) async throws -> HostHttpResponse {
        let response = try await transport.execute(
            HostHttpRequest(
                url: url,
                method: .get,
                headers: ["Accept": "application/octet-stream"],
                decode: .auto,
                body: nil,
                referrer: nil,
                timeoutMs: 20_000,
                maximumResponseBytes: maximumBytes
            )
        )
        guard response.status == 200 else { throw RepositoryError.invalidIndex }
        return response
    }

    /// A repository base is an HTTPS origin plus a directory path. Query strings, fragments and
    /// credentials are refused so the stored base cannot carry anything but a location.
    static func normalize(_ base: String) throws -> (origin: HttpsOrigin, path: String) {
        guard let components = URLComponents(string: base),
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty,
              components.scheme?.lowercased() == "https" else {
            throw RepositoryError.insecureTransport
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        while path.hasPrefix("/") { path.removeFirst() }
        if !path.isEmpty { try RepositoryIndexCodec.requireSafeRelativePath(path) }
        var originText = "https://\(host)"
        if let port = components.port { originText += ":\(port)" }
        return (try HttpsOrigin(originText), path)
    }

    static func join(_ origin: HttpsOrigin, _ path: String, _ file: String) throws -> URL {
        try RepositoryIndexCodec.requireSafeRelativePath(file)
        let joined = path.isEmpty ? file : "\(path)/\(file)"
        guard let url = URL(string: "\(origin.canonical)/\(joined)") else {
            throw RepositoryError.unsafePackagePath
        }
        return url
    }
}
