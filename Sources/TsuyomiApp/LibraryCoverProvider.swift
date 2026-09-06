// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// The pixel budget every cover request in the app uses, so one partition's cache entries are shared
/// rather than duplicated per screen.
public enum CoverPixels {
    public static let width = 216
    public static let height = 324
}

/// Shelf covers come from what the host already downloaded. Painting the shelf must never open every
/// source's runtime lane, so this fetcher refuses and the loader serves its on-disk cache or nothing.
struct CachedOnlyCoverFetcher: CoverMediaFetcher {
    func fetch(url: String, referrerUrl: String?) async throws -> CoverMediaPayload {
        throw MediaLoadError.httpFailure
    }
}

@MainActor
public final class LibraryCoverProvider: ObservableObject {
    @Published private var revision = 0

    private let roots: StorageRoots
    private let registry: SourceRegistry
    private let credentials: SourceCredentialStore
    private var providers: [String: SourceCoverProvider] = [:]
    private var providerUpdates: [String: AnyCancellable] = [:]
    private var resolved = Set<String>()

    public init(roots: StorageRoots, registry: SourceRegistry, credentials: SourceCredentialStore) {
        self.roots = roots
        self.registry = registry
        self.credentials = credentials
    }

    public func cover(_ book: LibraryBook) -> CoverUiState {
        cover(
            identity: book.identity,
            title: book.title,
            coverUrl: book.coverUrl,
            referrerUrl: book.canonicalUrl
        )
    }

    public func cover(_ summary: SourceBookSummary) -> CoverUiState {
        cover(
            identity: summary.identity,
            title: summary.title,
            coverUrl: summary.coverUrl,
            referrerUrl: summary.canonicalUrl
        )
    }

    private func cover(
        identity: BookIdentity,
        title: String,
        coverUrl: String?,
        referrerUrl: String?
    ) -> CoverUiState {
        guard let provider = providers[identity.sourceId] else {
            resolve(identity.sourceId)
            return .fallback(FallbackSpec(title: title, sourceLabel: nil))
        }
        return provider.state(
            identity: identity,
            title: title,
            coverUrl: coverUrl,
            referrerUrl: referrerUrl,
            width: CoverPixels.width,
            height: CoverPixels.height
        )
    }

    private func resolve(_ sourceId: String) {
        guard resolved.insert(sourceId).inserted else { return }
        Task { [weak self] in
            guard let self,
                  let id = try? SourceId(sourceId),
                  let sources = try? await registry.installedSources(),
                  let source = sources.first(where: { $0.sourceId == id }),
                  let provider = try? SourceCoverProvider(
                      source: source,
                      credentialRevision: await SourceCoverProvider.credentialRevision(
                          for: source,
                          credentials: credentials
                      ),
                      roots: roots,
                      fetcher: CachedOnlyCoverFetcher()
                  )
            else { return }
            self.providers[sourceId] = provider
            // Bumping the revision here only announces that the provider exists. A cover finishing its
            // read from disk changes that provider, which publishes on itself — a nested observable
            // its owner has to forward, or the shelf stays blank until something else redraws it.
            self.providerUpdates[sourceId] = provider.objectWillChange.sink { [weak self] _ in
                self?.revision += 1
            }
            self.revision += 1
        }
    }
}
