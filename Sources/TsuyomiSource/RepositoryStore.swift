// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// The repositories the user added, the identities of those they removed, and the cached catalog for
/// each. Removal never uninstalls an extension, never forgets a publisher, and never forgets the
/// repository's identity or catalog either: a repository id, address or root key may not be rebound
/// to another identity later, and re-adding the same root reuses its cached high-water mark
/// (`tsuyomi-repository-v1` §User-added subscription bootstrap).
public actor RepositoryStore {
    private let files: QuotaFileStore
    private let path = "repositories.json"
    private var active: [String: RepositoryDescriptor] = [:]
    private var retired: [String: RepositoryDescriptor] = [:]
    private var loaded = false

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func all() async -> [RepositoryDescriptor] {
        await load()
        return active.values.sorted { CanonicalOrder.precedes($0.repositoryId, $1.repositoryId) }
    }

    public func descriptor(_ repositoryId: String) async -> RepositoryDescriptor? {
        await load()
        return active[repositoryId]
    }

    public func add(_ descriptor: RepositoryDescriptor) async throws {
        await load()
        for known in Array(active.values) + Array(retired.values) {
            if known.repositoryId == descriptor.repositoryId {
                guard known.indexUrl == descriptor.indexUrl, known.rootKeyId == descriptor.rootKeyId,
                      known.rootPublicKey == descriptor.rootPublicKey else {
                    throw RepositoryError.repositoryIdentityMismatch
                }
            } else if known.indexUrl == descriptor.indexUrl || known.rootPublicKey == descriptor.rootPublicKey {
                throw RepositoryError.repositoryIdentityMismatch
            }
        }
        active[descriptor.repositoryId] = descriptor
        retired.removeValue(forKey: descriptor.repositoryId)
        try await persist()
    }

    public func remove(_ repositoryId: String) async throws {
        await load()
        guard let removed = active.removeValue(forKey: repositoryId) else { return }
        retired[repositoryId] = removed
        try await persist()
    }

    public func setEnabled(_ repositoryId: String, enabled: Bool) async throws {
        await load()
        guard let current = active[repositoryId] else { return }
        active[repositoryId] = RepositoryDescriptor(
            repositoryId: current.repositoryId,
            indexUrl: current.indexUrl,
            rootKeyId: current.rootKeyId,
            rootPublicKey: current.rootPublicKey,
            addedAt: current.addedAt,
            enabled: enabled
        )
        try await persist()
    }

    /// Only bytes that already passed `RepositoryIndexCodec.decode` may be cached; the cached
    /// sequence and digest are later trusted without a second verification.
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
              let root = try? JSONDecoder().decode(JSONValue.self, from: bytes).objectValue else { return }
        active = descriptors(root.array("repositories") ?? [])
        retired = descriptors(root.array("retired") ?? [])
    }

    private func descriptors(_ rows: [JSONValue]) -> [String: RepositoryDescriptor] {
        var result: [String: RepositoryDescriptor] = [:]
        for row in rows {
            guard let object = row.objectValue,
                  let repositoryId = object.string("repositoryId"),
                  let indexUrl = object.string("indexUrl").flatMap({ try? ExtensionRepositoryClient.normalize(indexUrl: $0) }),
                  let rootKeyId = object.string("rootKeyId"),
                  let rootPublicKey = object.string("rootPublicKey").flatMap(Data.init(hex:)),
                  let addedAt = object.instant("addedAt") else { continue }
            result[repositoryId] = RepositoryDescriptor(
                repositoryId: repositoryId,
                indexUrl: indexUrl,
                rootKeyId: rootKeyId,
                rootPublicKey: rootPublicKey,
                addedAt: addedAt,
                enabled: object.bool("enabled") ?? true
            )
        }
        return result
    }

    private func persist() async throws {
        let payload = JSONValue.object([
            "repositories": rows(active),
            "retired": rows(retired)
        ])
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(payload))
    }

    private func rows(_ descriptors: [String: RepositoryDescriptor]) -> JSONValue {
        .array(
            descriptors.values
                .sorted { CanonicalOrder.precedes($0.repositoryId, $1.repositoryId) }
                .map { descriptor in
                    .object([
                        "repositoryId": .string(descriptor.repositoryId),
                        "indexUrl": .string(descriptor.indexUrl.absoluteString),
                        "rootKeyId": .string(descriptor.rootKeyId),
                        "rootPublicKey": .string(RepositoryIndexCodec.hex(descriptor.rootPublicKey)),
                        "addedAt": .string(ProtocolTimestamp.format(descriptor.addedAt)),
                        "enabled": .bool(descriptor.enabled)
                    ])
                }
        )
    }
}
