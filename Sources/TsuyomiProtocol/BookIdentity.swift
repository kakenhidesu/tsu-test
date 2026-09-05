// SPDX-License-Identifier: AGPL-3.0-only

/// Stable, host-owned identity for a remotely sourced book.
///
/// Database row IDs, display names, and source implementation details are deliberately excluded.
public struct BookIdentity: Hashable, Sendable, Comparable, Codable {
    public let sourceId: String
    public let remoteBookId: String

    public init(sourceId: String, remoteBookId: String) throws {
        guard Grammar.isLegacySourceId(sourceId) else { throw ProtocolError.sourceIdGrammar }
        try BookIdentity.requireRemoteId(remoteBookId, field: "remoteBookId")
        self.sourceId = sourceId
        self.remoteBookId = remoteBookId
    }

    /// Validates a protocol remote identifier without normalizing it.
    public static func requireRemoteId(_ value: String, field: String) throws {
        guard Grammar.hasCodePoints(value, in: 1...1024) else {
            throw ProtocolError.remoteIdCodePoints(field: field)
        }
    }

    public static func < (lhs: BookIdentity, rhs: BookIdentity) -> Bool {
        let bySource = CanonicalOrder.compare(lhs.sourceId, rhs.sourceId)
        return bySource != 0 ? bySource < 0 : CanonicalOrder.precedes(lhs.remoteBookId, rhs.remoteBookId)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceId, remoteBookId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceId: container.decode(String.self, forKey: .sourceId),
            remoteBookId: container.decode(String.self, forKey: .remoteBookId)
        )
    }
}
