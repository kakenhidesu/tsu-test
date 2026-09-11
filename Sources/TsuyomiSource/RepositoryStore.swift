// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// The repositories the user added, and the cached catalog for each. Removing a repository drops its
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
        try await persist()
    }

    /// Only bytes that already passed `RepositoryIndexCodec.decode` may be cached; the cached
    /// sequence is later trusted without a second verification.
    public func cache(_ repositoryId: String, indexBytes: Data) async throws {
        _ = try await files.write(cachePath(repositoryId), bytes: indexBytes)
    }

    public func cached(_ repositoryId: String) async -> Data? {
        try? await files.read(cachePath(repositoryId))
    }

    private func cachePath(_ repositoryId: String) -> String {
        "repositories/\(Sha256.hex(repositoryId)).json"
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        guard let bytes = try? await files.read(path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: bytes).objectValue,
              let rows = root.array("repositories") else { return }
        for row in rows {
            guard let object = row.objectValue,
                  let repositoryId = object.string("repositoryId"),
                  let indexUrl = object.string("indexUrl").flatMap({ try? ExtensionRepositoryClient.normalize(indexUrl: $0) }),
                  let rootKeyId = object.string("rootKeyId"),
                  let rootPublicKey = object.string("rootPublicKey").flatMap(Data.init(hex:)),
                  let addedAt = object.instant("addedAt") else { continue }
            descriptors[repositoryId] = RepositoryDescriptor(
                repositoryId: repositoryId,
                indexUrl: indexUrl,
                rootKeyId: rootKeyId,
                rootPublicKey: rootPublicKey,
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
                            "indexUrl": .string(descriptor.indexUrl.absoluteString),
                            "rootKeyId": .string(descriptor.rootKeyId),
                            "rootPublicKey": .string(RepositoryIndexCodec.hex(descriptor.rootPublicKey)),
                            "addedAt": .string(ProtocolTimestamp.format(descriptor.addedAt))
                        ])
                    }
            )
        ])
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(payload))
    }
}
