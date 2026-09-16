// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI

/// Covers for one source's website mirror when it is opened from the shelf tab. The shelf itself
/// never opens a source lane to paint covers, but a mirror page is one source's own page: its
/// covers are fetched through that source, exactly as the browse tab does.
@MainActor
final class MirrorCoverProvider: ObservableObject {
    @Published private var revision = 0

    private let sourceId: SourceId
    private let container: AppContainer
    private var provider: SourceCoverProvider?
    private var updates: AnyCancellable?
    private var resolving = false

    init(sourceId: SourceId, container: AppContainer) {
        self.sourceId = sourceId
        self.container = container
    }

    func cover(_ summary: SourceBookSummary) -> CoverUiState {
        guard let provider else {
            resolve()
            return .fallback(FallbackSpec(title: summary.title, sourceLabel: nil))
        }
        return provider.state(
            identity: summary.identity,
            title: summary.title,
            coverUrl: summary.coverUrl,
            referrerUrl: summary.canonicalUrl,
            width: CoverPixels.width,
            height: CoverPixels.height
        )
    }

    func cancelAll() {
        provider?.cancelAll()
    }

    private func resolve() {
        guard !resolving else { return }
        resolving = true
        Task { [weak self] in
            guard let self else { return }
            guard let sources = try? await container.registry.installedSources(),
                  let source = sources.first(where: { $0.sourceId == sourceId }),
                  let client = try? await container.registry.client(for: sourceId),
                  let provider = try? SourceCoverProvider(
                      source: source,
                      credentialRevision: await SourceCoverProvider.credentialRevision(
                          for: source, credentials: container.credentials
                      ),
                      roots: container.roots,
                      fetcher: client
                  )
            else {
                resolving = false
                return
            }
            self.provider = provider
            // A nested observable publishes on itself; forwarding is what redraws the page when a
            // cover finishes downloading.
            self.updates = provider.objectWillChange.sink { [weak self] _ in self?.revision += 1 }
            self.revision += 1
        }
    }
}
