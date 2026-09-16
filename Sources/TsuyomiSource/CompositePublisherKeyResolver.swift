// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Resolves a key id across several trust sources with a fixed precedence: a built-in official
/// identity beats a built-in test identity, and either beats a user-added declaration. Two sources
/// in the winning tier that disagree on the bytes resolve to nothing, so no declaration can shadow
/// a pinned identity and no two catalogs can quietly split one key id. Revocation is the union.
public struct CompositePublisherKeyResolver: PublisherKeyResolver {
    private let resolvers: [any PublisherKeyResolver]

    public init(_ resolvers: [any PublisherKeyResolver]) {
        self.resolvers = resolvers
    }

    public func resolve(keyId: String) -> PublisherKey? {
        let candidates = resolvers.compactMap { $0.resolve(keyId: keyId) }
        guard let best = candidates.min(by: { CompositePublisherKeyResolver.rank($0.trust) < CompositePublisherKeyResolver.rank($1.trust) }) else {
            return nil
        }
        let winners = candidates.filter { $0.trust == best.trust }
        guard winners.allSatisfy({ $0.publicKey == best.publicKey }) else { return nil }
        return best
    }

    public func isRevokedFingerprint(_ fingerprint: String) -> Bool {
        resolvers.contains { $0.isRevokedFingerprint(fingerprint) }
    }

    public func isRevokedPackage(_ packageSha256: String) -> Bool {
        resolvers.contains { $0.isRevokedPackage(packageSha256) }
    }

    static func rank(_ trust: PublisherTrust) -> Int {
        switch trust {
        case .builtInOfficial: return 0
        case .builtInTest: return 1
        case .userAdded: return 2
        }
    }
}
