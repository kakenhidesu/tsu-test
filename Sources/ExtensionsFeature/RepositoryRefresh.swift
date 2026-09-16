// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiSource

/// One repository refresh, the same wherever it is asked for: a fetched catalog replaces the cached
/// one only if it is at least as new. The sequence is root-signed, so a mirror cannot serve an older
/// catalog to hide a revocation or an update, and two different catalogs under one sequence are
/// equivocation rather than a refresh.
enum RepositoryRefresh {
    static func perform(
        _ descriptor: RepositoryDescriptor,
        client: ExtensionRepositoryClient,
        repositories: RepositoryStore,
        lifecycle: ExtensionLifecycle
    ) async throws -> RepositoryIndex {
        let fetched = try await client.refresh(descriptor)
        if let cached = await repositories.cached(descriptor.repositoryId),
           let previous = RepositoryIndexCodec.sequence(of: cached) {
            if fetched.index.sequence < previous { throw RepositoryError.indexRollback }
            if fetched.index.sequence == previous,
               RepositoryIndexCodec.signedDigest(of: cached) != RepositoryIndexCodec.signedDigest(of: fetched.bytes) {
                throw RepositoryError.indexEquivocation
            }
        }
        try await repositories.cache(descriptor.repositoryId, indexBytes: fetched.bytes)
        try await lifecycle.applyRevocations(fetched.index.revocations)
        return fetched.index
    }
}
