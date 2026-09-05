// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// Publishes cover states for one open source. It holds the partition binding so a screen only ever
/// asks for "the cover of this book"; if the source, package or credential changes the whole
/// provider is replaced, and the previous partition's images are never reused.
@MainActor
public final class SourceCoverProvider: ObservableObject {
    @Published public private(set) var states: [BookIdentity: CoverUiState] = [:]

    private let repository: CoverRepository
    private let sourceId: String
    private let packageRevision: String
    private let credentialRevision: String
    private let sourceLabel: String
    private var streams: [BookIdentity: Task<Void, Never>] = [:]

    public init(
        source: InstalledSource,
        packageRevision: String,
        credentialRevision: String,
        origins: Set<HttpsOrigin>,
        roots: StorageRoots,
        fetcher: any CoverMediaFetcher
    ) throws {
        sourceId = source.sourceId.value
        self.packageRevision = packageRevision
        self.credentialRevision = credentialRevision
        sourceLabel = source.displayName
        repository = try CoverRepository(
            sourceId: sourceId,
            packageRevision: packageRevision,
            credentialRevision: credentialRevision,
            origins: origins,
            roots: roots,
            fetcher: fetcher
        )
    }

    public func state(for summary: SourceBookSummary, width: Int, height: Int) -> CoverUiState {
        if let existing = states[summary.identity] { return existing }
        start(summary, width: width, height: height)
        return states[summary.identity] ?? .loading(fallback: fallback(summary))
    }

    public func cancelAll() {
        for task in streams.values { task.cancel() }
        streams = [:]
    }

    private func start(_ summary: SourceBookSummary, width: Int, height: Int) {
        guard streams[summary.identity] == nil else { return }
        guard let coverUrl = summary.coverUrl else {
            states[summary.identity] = .fallback(fallback(summary))
            return
        }
        let request = CoverRequest(
            sourceId: sourceId,
            packageRevision: packageRevision,
            credentialRevision: credentialRevision,
            transportUrl: coverUrl,
            referrerUrl: summary.canonicalUrl,
            targetWidthPx: width,
            targetHeightPx: height,
            fallback: fallback(summary)
        )
        let identity = summary.identity
        let stream = repository.observe(request)
        streams[identity] = Task { [weak self] in
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.states[identity] = state
            }
        }
    }

    private func fallback(_ summary: SourceBookSummary) -> FallbackSpec {
        FallbackSpec(title: summary.title, sourceLabel: sourceLabel)
    }
}
