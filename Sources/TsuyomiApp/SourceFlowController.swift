// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// Owns the browse tab's navigation path and the one source that may be open under it. Leaving the
/// browse root closes the source: an extension can never keep a runtime lane alive behind a screen
/// the user has left.
@MainActor
public final class SourceFlowController: ObservableObject {
    @Published public var path: [Route] = []
    @Published public private(set) var covers: SourceCoverProvider?

    private let container: AppContainer
    private var openSource: InstalledSource?
    private var ownerGeneration: Int64 = 0

    public init(container: AppContainer) {
        self.container = container
    }

    public var activeSource: InstalledSource? { openSource }

    public var activeSourceId: String? { openSource?.sourceId.value }

    public func push(_ route: Route) async {
        if let sourceId = route.sourceId {
            await open(sourceId)
        }
        container.snapshots.save(target: route.restorationTarget)
        path.append(route)
    }

    /// Rebuilds the path a relaunch should land on. Only the remembered book and target are used, so
    /// restoration cannot resurrect a screen the user never reached.
    public func restore() async {
        guard path.isEmpty,
              let target = container.snapshots.readTarget(),
              let sources = try? await container.registry.installedSources()
        else { return }
        for source in sources {
            guard let snapshot = container.snapshots.read(sourceId: source.sourceId.value) else { continue }
            switch target {
            case .search:
                await push(.search(source.sourceId))
            case .detail:
                await push(.detail(snapshot.book.identity))
            case .reader:
                guard let chapter = snapshot.chapter else { return }
                await push(.detail(snapshot.book.identity))
                await push(.reader(snapshot.book.identity, chapter.chapterId))
            }
            return
        }
    }

    /// The one cover accessor every screen uses, so the partition binding lives in exactly one place.
    public func cover(_ summary: SourceBookSummary) -> CoverUiState {
        covers?.state(
            identity: summary.identity,
            title: summary.title,
            coverUrl: summary.coverUrl,
            referrerUrl: summary.canonicalUrl,
            width: CoverPixels.width,
            height: CoverPixels.height
        ) ?? .fallback(FallbackSpec(title: summary.title, sourceLabel: openSource?.displayName))
    }

    public func pop() async {
        guard !path.isEmpty else { return }
        path.removeLast()
        container.snapshots.save(target: path.last?.restorationTarget)
        if path.isEmpty || path.allSatisfy({ $0.sourceId == nil }) {
            await closeSource()
        }
    }

    public func popToRoot() async {
        path.removeAll()
        container.snapshots.save(target: nil)
        await closeSource()
    }

    /// Remembers the book, and the chapter when there is one, so a relaunch can rebuild the route.
    public func remember(book: SourceBookSummary) {
        container.snapshots.save(book: book)
    }

    public func remember(chapter: SourceChapter) {
        container.snapshots.save(chapter: chapter)
    }

    public func snapshot() -> SourceFlowSnapshot? {
        guard let sourceId = activeSourceId else { return nil }
        return container.snapshots.read(sourceId: sourceId)
    }

    /// The lease a multi-page remote run must still match when it finishes.
    public func lease(for source: InstalledSource) async -> RemoteExecutionLease? {
        guard let availability = try? await container.remoteLibrary
            .sourceAvailability(source.sourceId.value),
            let policy = try? await container.remoteLibrary.sourceRemotePolicy(source.sourceId.value),
            let client = try? await container.registry.client(for: source.sourceId)
        else { return nil }
        return RemoteExecutionLease(
            packageSha256: client.packageInfo.packageSha256,
            packageVersion: client.packageInfo.manifest.version.original,
            capabilitySetFingerprint: policy.capabilitySetFingerprint,
            sourceGeneration: availability.generation,
            ownerGeneration: ownerGeneration
        )
    }

    private func open(_ sourceId: String) async {
        guard openSource?.sourceId.value != sourceId else { return }
        await closeSource()
        guard let id = try? SourceId(sourceId),
              let sources = try? await container.registry.installedSources(),
              let source = sources.first(where: { $0.sourceId == id }),
              let client = try? await container.registry.client(for: id)
        else { return }
        ownerGeneration += 1
        openSource = source
        covers = try? SourceCoverProvider(
            source: source,
            credentialRevision: await SourceCoverProvider.credentialRevision(
                for: source,
                credentials: container.credentials
            ),
            roots: container.roots,
            fetcher: client
        )
    }

    private func closeSource() async {
        covers?.cancelAll()
        covers = nil
        guard let source = openSource else { return }
        openSource = nil
        await container.registry.close(source.sourceId)
    }
}
