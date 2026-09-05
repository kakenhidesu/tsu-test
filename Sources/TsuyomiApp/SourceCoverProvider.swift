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
        if let existing = states[identity] { return existing }
        start(identity: identity, title: title, coverUrl: coverUrl, referrerUrl: referrerUrl, width: width, height: height)
        return states[identity] ?? .loading(fallback: fallback(title))
    }

    public func cancelAll() {
        for task in streams.values { task.cancel() }
        streams = [:]
    }

    private func start(
        identity: BookIdentity,
        title: String,
        coverUrl: String?,
        referrerUrl: String?,
        width: Int,
        height: Int
    ) {
        guard streams[identity] == nil else { return }
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
            states[identity] = .fallback(fallback(title))
            return
        }
        let stream = repository.observe(request)
        streams[identity] = Task { [weak self] in
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.states[identity] = state
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
