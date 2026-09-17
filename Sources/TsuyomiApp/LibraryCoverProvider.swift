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

/// Shelf covers are served from the on-disk cache first; only a cover that was never downloaded —
/// a book copied from a website mirror, or imported — opens its source's lane, once, to fetch it.
/// The lane is the same one browsing uses and closes with the app, so the shelf never keeps a
/// source alive on its own.
struct LazySourceCoverFetcher: CoverMediaFetcher {
    let registry: SourceRegistry
    let sourceId: SourceId

    func fetch(url: String, referrerUrl: String?) async throws -> CoverMediaPayload {
        let client: SourceExtensionClient
        do {
            client = try await registry.client(for: sourceId)
        } catch {
            throw MediaLoadError.httpFailure(detail: "source-unavailable")
        }
        return try await client.fetch(url: url, referrerUrl: referrerUrl)
    }
}

@MainActor
public final class LibraryCoverProvider: ObservableObject {
    @Published private var revision = 0

    private let roots: StorageRoots
    private let registry: SourceRegistry
    private let credentials: SourceCredentialStore
    /// What a provider was built against. Covers are cached per package and per credential state, so
    /// a provider outlives neither.
    private struct Binding: Equatable {
        let packageRevision: String
        let credentialRevision: String
    }

    private var providers: [String: SourceCoverProvider] = [:]
    private var providerUpdates: [String: AnyCancellable] = [:]
    private var bindings: [String: Binding] = [:]
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

    /// Called when the shelf comes into view. A provider built before its source was updated, or
    /// before the reader signed in or out, is dropped so the next draw builds one for the package
    /// and session now in force; the ones still valid are asked to try their failed covers again.
    public func revalidate() async {
        guard !bindings.isEmpty, let sources = try? await registry.installedSources() else { return }
        var replaced = false
        for (sourceId, bound) in bindings {
            var current: Binding?
            if let source = sources.first(where: { $0.sourceId.value == sourceId }) {
                current = Binding(
                    packageRevision: source.packageSha256,
                    credentialRevision: await SourceCoverProvider.credentialRevision(
                        for: source,
                        credentials: credentials
                    )
                )
            }
            if current == bound {
                providers[sourceId]?.retryFailed()
                continue
            }
            providers[sourceId]?.cancelAll()
            providers[sourceId] = nil
            providerUpdates[sourceId] = nil
            bindings[sourceId] = nil
            resolved.remove(sourceId)
            replaced = true
        }
        if replaced { revision += 1 }
    }

    private func resolve(_ sourceId: String) {
        guard resolved.insert(sourceId).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let id = try? SourceId(sourceId),
                  let sources = try? await registry.installedSources(),
                  let source = sources.first(where: { $0.sourceId == id })
            else {
                // Nothing was built, so nothing is remembered: a source that is installed later, or a
                // read that fails once, must not leave the shelf without covers until the next launch.
                self.resolved.remove(sourceId)
                return
            }
            let credentialRevision = await SourceCoverProvider.credentialRevision(
                for: source,
                credentials: credentials
            )
            guard let provider = try? SourceCoverProvider(
                source: source,
                credentialRevision: credentialRevision,
                roots: roots,
                fetcher: LazySourceCoverFetcher(registry: registry, sourceId: id)
            ) else {
                self.resolved.remove(sourceId)
                return
            }
            self.bindings[sourceId] = Binding(
                packageRevision: source.packageSha256,
                credentialRevision: credentialRevision
            )
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
