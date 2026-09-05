// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import os
import TsuyomiCore
import TsuyomiProtocol

public struct TrustedPublisher: Hashable, Sendable {
    public let keyId: String
    public let publicKey: Data
    public let trust: PublisherTrust
    public let repositoryId: String?
    public let approvedAt: Date

    public init(
        keyId: String,
        publicKey: Data,
        trust: PublisherTrust,
        repositoryId: String?,
        approvedAt: Date
    ) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.trust = trust
        self.repositoryId = repositoryId
        self.approvedAt = approvedAt
    }

    public var fingerprint: String {
        RepositoryPublisher(keyId: keyId, publicKey: publicKey).fingerprint
    }
}

/// The durable answer to "whose code may run here". Approval is per exact public key: a key id whose
/// bytes changed is a different publisher and has to be confirmed again, so a repository cannot
/// rotate itself into trust. Reads are synchronous because archive verification is; only the file is
/// touched asynchronously.
public final class PublisherTrustStore: PublisherKeyResolver {
    private struct State: Sendable {
        var publishers: [String: TrustedPublisher] = [:]
        var revokedFingerprints = Set<String>()
        var revokedPackages = Set<String>()
    }

    private let files: QuotaFileStore
    private let path = "trust.json"
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(files: QuotaFileStore) {
        self.files = files
    }

    public func load() async {
        guard let bytes = try? await files.read(path),
              let root = try? JSONDecoder().decode(JSONValue.self, from: bytes).objectValue else {
            return
        }
        var publishers: [String: TrustedPublisher] = [:]
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
        let loaded = State(
            publishers: publishers,
            revokedFingerprints: Set((root.array("revokedFingerprints") ?? []).compactMap(\.stringValue)),
            revokedPackages: Set((root.array("revokedPackages") ?? []).compactMap(\.stringValue))
        )
        state.withLock { $0 = loaded }
    }

    public var trusted: [TrustedPublisher] {
        state.withLock { current in
            current.publishers.values.sorted { CanonicalOrder.precedes($0.keyId, $1.keyId) }
        }
    }

    /// Approving a key already stored under different bytes is refused rather than merged: the caller
    /// must present it to the user as a new publisher.
    public func approve(_ publisher: TrustedPublisher) async throws {
        try state.withLock { current in
            if let existing = current.publishers[publisher.keyId],
               existing.publicKey != publisher.publicKey {
                throw HxpVerificationError.unknownPublisher
            }
            current.publishers[publisher.keyId] = publisher
        }
        try await persist()
    }

    public func revoke(keyId: String) async throws {
        state.withLock { current in
            guard let removed = current.publishers.removeValue(forKey: keyId) else { return }
            current.revokedFingerprints.insert(Sha256.hex(removed.publicKey))
        }
        try await persist()
    }

    public func revoke(packageDigest: String) async throws {
        state.withLock { _ = $0.revokedPackages.insert(packageDigest) }
        try await persist()
    }

    public func forget(keyId: String) async throws {
        state.withLock { _ = $0.publishers.removeValue(forKey: keyId) }
        try await persist()
    }

    public func resolve(keyId: String) -> PublisherKey? {
        state.withLock { current in
            current.publishers[keyId].flatMap {
                try? PublisherKey(keyId: $0.keyId, publicKey: $0.publicKey, trust: $0.trust)
            }
        }
    }

    public func isRevokedFingerprint(_ fingerprint: String) -> Bool {
        state.withLock { $0.revokedFingerprints.contains(fingerprint) }
    }

    public func isRevokedPackage(_ contentDigest: String) -> Bool {
        state.withLock { $0.revokedPackages.contains(contentDigest) }
    }

    private func persist() async throws {
        let payload = state.withLock { current in
            JSONValue.object([
                "publishers": .array(
                    current.publishers.values
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
                "revokedFingerprints": .array(
                    CanonicalOrder.sorted(current.revokedFingerprints).map(JSONValue.string)
                ),
                "revokedPackages": .array(
                    CanonicalOrder.sorted(current.revokedPackages).map(JSONValue.string)
                )
            ])
        }
        _ = try await files.write(path, bytes: try Rfc8785.canonicalize(payload))
    }
}
