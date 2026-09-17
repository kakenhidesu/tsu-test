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
    /// One entry per book *and* address: a listing and a detail page may name different covers for
    /// the same book, and a second address must get its own attempt rather than the first's result.
    private struct Key: Hashable {
        let identity: BookIdentity
        let coverUrl: String?
    }

    @Published private var states: [Key: CoverUiState] = [:]

    private let repository: CoverRepository
    private let sourceId: String
    private let packageRevision: String
    private let credentialRevision: String
    private let sourceLabel: String
    private var streams: [Key: Task<Void, Never>] = [:]

    public init(
        source: InstalledSource,
        credentialRevision: String,
        roots: StorageRoots,
        fetcher: any CoverMediaFetcher
    ) throws {
        sourceId = source.sourceId.value
        packageRevision = source.packageSha256
        self.credentialRevision = credentialRevision
        sourceLabel = source.displayName
        repository = try CoverRepository(
            sourceId: sourceId,
            packageRevision: packageRevision,
            credentialRevision: credentialRevision,
            origins: source.networkOrigins,
            roots: roots,
            fetcher: fetcher
        )
    }

    /// Callers pass the four fields a cover needs, so a shelf book and a source summary share one
    /// cover path instead of a second, drifting DTO.
    public func state(
        identity: BookIdentity,
        title: String,
        coverUrl: String?,
        referrerUrl: String?,
        width: Int,
        height: Int
    ) -> CoverUiState {
        let key = Key(identity: identity, coverUrl: coverUrl)
        if let existing = states[key] { return existing }
        start(identity: identity, title: title, coverUrl: coverUrl, referrerUrl: referrerUrl, width: width, height: height)
        return states[key] ?? .loading(fallback: fallback(title))
    }

    public func cancelAll() {
        for task in streams.values { task.cancel() }
        streams = [:]
    }

    /// Forgets every failed attempt, so the next draw asks again. A failure is a fact about one
    /// moment — the lane was closing, the network was away, the site was challenging — and a screen
    /// that comes back into view is the reader asking whether it is still true.
    public func retryFailed() {
        let failed = states.compactMap { key, state -> Key? in
            if case .failed = state { return key }
            return nil
        }
        guard !failed.isEmpty else { return }
        for key in failed {
            streams[key]?.cancel()
            streams[key] = nil
            states[key] = nil
        }
    }

    private func start(
        identity: BookIdentity,
        title: String,
        coverUrl: String?,
        referrerUrl: String?,
        width: Int,
        height: Int
    ) {
        let key = Key(identity: identity, coverUrl: coverUrl)
        guard streams[key] == nil else { return }
        guard let coverUrl, let request = try? CoverRequest(
            sourceId: sourceId,
            packageRevision: packageRevision,
            credentialRevision: credentialRevision,
            transportUrl: coverUrl,
            referrerUrl: referrerUrl,
            targetWidthPx: width,
            targetHeightPx: height,
            fallback: fallback(title)
        ) else {
            states[key] = .fallback(fallback(title))
            return
        }
        let stream = repository.observe(request)
        streams[key] = Task { [weak self] in
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.states[key] = state
            }
        }
    }

    private func fallback(_ title: String) -> FallbackSpec {
        FallbackSpec(title: title, sourceLabel: sourceLabel)
    }
}

extension SourceCoverProvider {
    /// Covers are cached per credential state, so signing in or out must not reveal the previous
    /// session's images. Every screen derives it here; two derivations would read two partitions.
    public static func credentialRevision(
        for source: InstalledSource,
        credentials: SourceCredentialStore
    ) async -> String {
        var parts: [String] = []
        for origin in source.webLoginOrigins.sorted(by: { CanonicalOrder.precedes($0.canonical, $1.canonical) }) {
            guard let partition = try? SourceCredentialPartition(
                sourceId: source.sourceId.value,
                origin: origin
            ) else { continue }
            parts.append((try? await credentials.get(partition)) == nil ? "0" : "1")
        }
        return parts.isEmpty ? "anonymous" : parts.joined()
    }
}
