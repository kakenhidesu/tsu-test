// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct DirectActionBinding: Hashable, Sendable {
    public let sourceId: String
    public let remoteBookId: String
    public let reconciliationId: String
    public let packageDigest: String
    public let packageVersion: String
    public let capabilitySetFingerprint: String
    public let registryGeneration: Int64
    public let ownerGeneration: Int64

    public init(
        sourceId: String,
        remoteBookId: String,
        reconciliationId: String,
        packageDigest: String,
        packageVersion: String,
        capabilitySetFingerprint: String,
        registryGeneration: Int64,
        ownerGeneration: Int64
    ) {
        self.sourceId = sourceId
        self.remoteBookId = remoteBookId
        self.reconciliationId = reconciliationId
        self.packageDigest = packageDigest
        self.packageVersion = packageVersion
        self.capabilitySetFingerprint = capabilitySetFingerprint
        self.registryGeneration = registryGeneration
        self.ownerGeneration = ownerGeneration
    }
}

/// One remote write needs one token minted from one direct user action. A token is single-use: the
/// first `accept` marks it terminal, so a replayed or extension-initiated request finds nothing.
public actor DirectActionTokenRegistry {
    private struct Record {
        let binding: DirectActionBinding
        let onAccept: @Sendable () async -> Bool
        var terminal: Bool
    }

    private var records: [String: Record] = [:]

    public init() {}

    public func mint(
        _ binding: DirectActionBinding,
        onAccept: @escaping @Sendable () async -> Bool
    ) -> String {
        let token = UUID().uuidString
        records[token] = Record(binding: binding, onAccept: onAccept, terminal: false)
        return token
    }

    @discardableResult
    public func accept(sourceId: String, remoteBookId: String, token: String) async throws -> DirectActionBinding {
        guard var record = records[token], !record.terminal,
              record.binding.sourceId == sourceId,
              record.binding.remoteBookId == remoteBookId else {
            throw HostNetworkException(.cancelled)
        }
        record.terminal = true
        records[token] = record
        let accepted = await record.onAccept()
        records.removeValue(forKey: token)
        guard accepted else { throw HostNetworkException(.cancelled) }
        return record.binding
    }

    @discardableResult
    public func revoke(_ token: String) -> DirectActionBinding? {
        records.removeValue(forKey: token)?.binding
    }
}
