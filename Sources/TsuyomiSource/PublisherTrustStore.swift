// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public struct TrustedPublisher: Hashable, Sendable {
    public let keyId: String
    public let publicKey: Data
    public let trust: PublisherTrust
    public let repositoryId: String?
    public let approvedAt: Date

    public var fingerprint: String {
        RepositoryPublisher(keyId: keyId, publicKey: publicKey).fingerprint
    }
}

/// The durable answer to "whose code may run here". Approval is per exact public key: a key id whose
/// bytes changed is a different publisher and has to be confirmed again, so there is no path by which
/// a repository silently rotates itself into trust.
public actor PublisherTrustStore {
    private let files: QuotaFileStore
    private let path = "trust.json"
    private var publishers: [String: TrustedPublisher] = [:]
    private var revokedFingerprints = Set<String>()
    private var revokedPackages = Set<String>()
    private var loaded = false

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func load() async {
        guard !loaded else { return }
        loaded = true
        guard let bytes = try? await files.read(path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: bytes).objectValue else {
            return
        }
        for row in root.array("publishers") ?? [] {
            guard let object = row.objectValue,
                  let keyId = object.string("keyId"),
                  let hex = object.string("publicKey"), let publicKey = Data(hex: hex),
                  let trust = object.string("trust").flatMap(PublisherTrust.init(rawValue:)),
                  let approvedAt = object.instant("approvedAt") else { continue }
            publishers[keyId] = TrustedPublisher(
                keyId: keyId,
                publicKey: publicKey,
                trust: trust,
                repositoryId: object.string("repositoryId"),
                approvedAt: approvedAt
            )
        }
        revokedFingerprints = Set((root.array("revokedFingerprints") ?? []).compactMap(\.stringValue))
        revokedPackages = Set((root.array("revokedPackages") ?? []).compactMap(\.stringValue))
    }

    public func trusted() async -> [TrustedPublisher] {
        await load()
        return publishers.values.sorted { CanonicalOrder.precedes($0.keyId, $1.keyId) }
    }

    /// Approving a key that is already stored under different bytes is refused rather than merged:
    /// the caller must present it to the user as a new publisher.
    public func approve(_ publisher: TrustedPublisher) async throws {
        await load()
        if let existing = publishers[publisher.keyId], existing.publicKey != publisher.publicKey {
            throw HxpVerificationError.unknownPublisher
        }
        publishers[publisher.keyId] = publisher
        try await persist()
    }

    public func revoke(keyId: String) async throws {
        await load()
        guard let removed = publishers.removeValue(forKey: keyId) else { return }
        revokedFingerprints.insert(Sha256.hex(removed.publicKey))
        try await persist()
    }

    public func revoke(packageDigest: String) async throws {
        await load()
        revokedPackages.insert(packageDigest)
        try await persist()
    }

    public func forget(keyId: String) async throws {
        await load()
        guard publishers.removeValue(forKey: keyId) != nil else { return }
        try await persist()
    }

    /// A verification-time snapshot. The verifier needs a synchronous resolver, and a snapshot also
    /// means one archive is checked against one consistent view of trust.
    public func resolver() async -> InMemoryPublisherKeyStore {
        await load()
        let store = InMemoryPublisherKeyStore(
            keys: publishers.values.compactMap {
                try? PublisherKey(keyId: $0.keyId, publicKey: $0.publicKey, trust: $0.trust)
            }
        )
        for fingerprint in revokedFingerprints { store.revokeFingerprint(fingerprint) }
        for digest in revokedPackages { store.revokePackage(digest) }
        return store
    }

    private func persist() async throws {
        let payload = JSONValue.object([
            "publishers": .array(
                publishers.values
                    .sorted { CanonicalOrder.precedes($0.keyId, $1.keyId) }
                    .map { publisher in
                        var row: [String: JSONValue] = [
                            "keyId": .string(publisher.keyId),
                            "publicKey": .string(RepositoryIndexCodec.hex(publisher.publicKey)),
                            "trust": .string(publisher.trust.rawValue),
                            "approvedAt": .string(ProtocolTimestamp.format(publisher.approvedAt))
                        ]
                        if let repositoryId = publisher.repositoryId {
                            row["repositoryId"] = .string(repositoryId)
                        }
                        return .object(row)
                    }
            ),
            "revokedFingerprints": .array(CanonicalOrder.sorted(revokedFingerprints).map(JSONValue.string)),
            "revokedPackages": .array(CanonicalOrder.sorted(revokedPackages).map(JSONValue.string))
        ])
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(payload))
    }
}
