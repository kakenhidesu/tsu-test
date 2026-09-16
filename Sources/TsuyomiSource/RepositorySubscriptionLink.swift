// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The one bounded link a user-added repository is discovered through
/// (`tsuyomi-repository-v1` §User-added subscription bootstrap). The fragment carries the root
/// identity and is stripped before any fetch; parsing performs no network I/O, and every deviation
/// from the exact ordered grammar is refused rather than repaired.
public struct RepositorySubscriptionLink: Hashable, Sendable {
    public static let maximumLength = 4_512

    public let indexUrl: URL
    public let repositoryId: String
    public let keyId: String
    public let rootPublicKey: Data

    public var rootKey: RepositoryPublisher {
        RepositoryPublisher(keyId: keyId, publicKey: rootPublicKey)
    }

    public static func parse(_ text: String) throws -> RepositorySubscriptionLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength, trimmed.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw RepositoryError.invalidSubscriptionLink
        }
        let halves = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2, let indexUrl = try? ExtensionRepositoryClient.normalize(indexUrl: String(halves[0])) else {
            throw RepositoryError.invalidSubscriptionLink
        }
        let fields = halves[1].split(separator: "&", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 3, !halves[1].contains("%"),
              let repositoryId = value(fields[0], named: "repositoryId"), Grammar.isStrictSourceId(repositoryId),
              let keyId = value(fields[1], named: "keyId"), RepositoryIndexCodec.isKeyId(keyId),
              let encoded = value(fields[2], named: "publicKey"), encoded.count == 44, encoded.hasSuffix("="),
              let rootPublicKey = try? ExtensionRepositoryClient.rootKey(encoded) else {
            throw RepositoryError.invalidSubscriptionLink
        }
        return RepositorySubscriptionLink(
            indexUrl: indexUrl,
            repositoryId: repositoryId,
            keyId: keyId,
            rootPublicKey: rootPublicKey
        )
    }

    private static func value(_ field: Substring, named name: String) -> String? {
        guard field.hasPrefix("\(name)=") else { return nil }
        let value = field.dropFirst(name.count + 1)
        return value.isEmpty ? nil : String(value)
    }
}
