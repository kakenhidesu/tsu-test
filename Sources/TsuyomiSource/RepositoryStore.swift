// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// The repositories the user added, and the cached index for each. Removing a repository drops its
/// cache but never uninstalls an extension and never forgets a publisher: trust is managed on its
/// own screen, and an installed source keeps working after its repository is gone.
public actor RepositoryStore {
    private let files: QuotaFileStore
    private let path = "repositories.json"
    private var descriptors: [String: RepositoryDescriptor] = [:]
    private var loaded = false

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func all() async -> [RepositoryDescriptor] {
        await load()
        return descriptors.values.sorted { CanonicalOrder.precedes($0.repositoryId, $1.repositoryId) }
    }

    public func descriptor(_ repositoryId: String) async -> RepositoryDescriptor? {
        await load()
        return descriptors[repositoryId]
    }

    public func add(_ descriptor: RepositoryDescriptor) async throws {
        await load()
        descriptors[descriptor.repositoryId] = descriptor
        try await persist()
    }

    public func remove(_ repositoryId: String) async throws {
        await load()
        guard descriptors.removeValue(forKey: repositoryId) != nil else { return }
        _ = try? await files.delete(cachePath(repositoryId))
        _ = try? await files.delete(signaturePath(repositoryId))
        try await persist()
    }

    public func cache(_ repositoryId: String, indexBytes: Data, signature: Data) async throws {
        _ = try await files.write(cachePath(repositoryId), bytes: indexBytes)
        _ = try await files.write(signaturePath(repositoryId), bytes: signature)
    }

    public func cached(_ repositoryId: String) async -> (index: Data, signature: Data)? {
        guard let index = try? await files.read(cachePath(repositoryId)),
              let signature = try? await files.read(signaturePath(repositoryId)) else { return nil }
        return (index, signature)
    }

    private func cachePath(_ repositoryId: String) -> String {
        "repositories/\(Sha256.hex(repositoryId)).json"
    }

    private func signaturePath(_ repositoryId: String) -> String {
        "repositories/\(Sha256.hex(repositoryId)).sig"
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        guard let bytes = try? await files.read(path),
              let rows = try? JSONDecoder().decode(JSONValue.self, from: bytes).objectValue?.array("repositories")
        else { return }
        for row in rows ?? [] {
            guard let object = row.objectValue,
                  let repositoryId = object.string("repositoryId"),
                  let base = object.string("base").flatMap({ try? HttpsOrigin($0) }),
                  let path = object.string("path"),
                  let keyId = object.string("publisherKeyId"),
                  let publicKey = object.string("publisherPublicKey").flatMap(Data.init(hex:)),
                  let addedAt = object.instant("addedAt") else { continue }
            descriptors[repositoryId] = RepositoryDescriptor(
                repositoryId: repositoryId,
                base: base,
                path: path,
                publisherKeyId: keyId,
                publisherPublicKey: publicKey,
                addedAt: addedAt
            )
        }
    }

    private func persist() async throws {
        let payload = JSONValue.object([
            "repositories": .array(
                descriptors.values
                    .sorted { CanonicalOrder.precedes($0.repositoryId, $1.repositoryId) }
                    .map { descriptor in
                        .object([
                            "repositoryId": .string(descriptor.repositoryId),
                            "base": .string(descriptor.base.canonical),
                            "path": .string(descriptor.path),
                            "publisherKeyId": .string(descriptor.publisherKeyId),
                            "publisherPublicKey": .string(RepositoryIndexCodec.hex(descriptor.publisherPublicKey)),
                            "addedAt": .string(ProtocolTimestamp.format(descriptor.addedAt))
                        ])
                    }
            )
        ])
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(payload))
    }
}
