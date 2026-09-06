// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import BrowseFeature
import ExtensionsFeature
import ReaderFeature
import SearchFeature
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource

/// Each host owns the model for exactly one route. The model is created when the route is pushed and
/// released when it is popped, so no screen keeps a source request alive after the user leaves it.
struct SourceHomeHost: View {
    @ObservedObject var flow: SourceFlowController
    @StateObject private var model: SourceHomeModel

    init(container: AppContainer, flow: SourceFlowController, sourceId: SourceId) {
        self.flow = flow
        _model = StateObject(
            wrappedValue: SourceHomeModel(
                sourceId: sourceId,
                registry: container.registry
            )
        )
    }

    var body: some View {
        SourceHomeScreen(
            model: model,
            coverState: { flow.cover($0) },
            openBook: { identity in Task { await flow.push(.detail(identity)) } }
        )
    }
}

struct SearchHost: View {
    @ObservedObject var flow: SourceFlowController
    @StateObject private var model: SearchModel

    init(container: AppContainer, flow: SourceFlowController, sourceId: SourceId) {
        self.flow = flow
        _model = StateObject(
            wrappedValue: SearchModel(
                sourceId: sourceId,
                registry: container.registry,
                library: container.library
            )
        )
    }

    var body: some View {
        SearchScreen(
            model: model,
            coverState: { flow.cover($0) },
            openBook: { identity in Task { await flow.push(.detail(identity)) } }
        )
    }
}

struct RemoteLibraryHost: View {
    @ObservedObject var flow: SourceFlowController
    @StateObject private var model: RemoteLibraryModel

    init(container: AppContainer, flow: SourceFlowController, sourceId: SourceId) {
        self.flow = flow
        _model = StateObject(
            wrappedValue: RemoteLibraryModel(
                sourceId: sourceId,
                registry: container.registry,
                library: container.library
            )
        )
    }

    var body: some View {
        RemoteLibraryScreen(
            model: model,
            coverState: { flow.cover($0) },
            openBook: { identity in Task { await flow.push(.detail(identity)) } }
        )
    }
}

/// Opened from two different stacks — the browse flow and the shelf — so where a chapter goes is the
/// host stack's business, not this view's. Pushing onto the browse flow from here put the reader into
/// a stack the shelf never shows, which read as tapping a chapter doing nothing at all.
struct BookHost: View {
    private let coverState: (SourceBookSummary) -> CoverUiState
    private let openChapter: (SourceChapter) -> Void
    @StateObject private var model: BookModel

    init(
        container: AppContainer,
        identity: BookIdentity,
        coverState: @escaping (SourceBookSummary) -> CoverUiState,
        openChapter: @escaping (BookIdentity, SourceChapter) -> Void
    ) {
        self.coverState = coverState
        self.openChapter = { chapter in openChapter(identity, chapter) }
        _model = StateObject(
            wrappedValue: BookModel(
                identity: identity,
                registry: container.registry,
                library: container.library,
                progressStore: container.progress
            )
        )
    }

    var body: some View {
        BookScreen(model: model, coverState: coverState, openChapter: openChapter)
    }
}

struct ReaderHost: View {
    private let onLeave: () -> Void
    @StateObject private var model: ReaderModel

    init(
        container: AppContainer,
        identity: BookIdentity,
        chapterId: String,
        onLeave: @escaping () -> Void
    ) {
        self.onLeave = onLeave
        _model = StateObject(
            wrappedValue: ReaderModel(
                identity: identity,
                bookTitle: container.snapshots.read(sourceId: identity.sourceId)?.book.title ?? "",
                startChapterId: chapterId,
                settings: container.preferences.reader,
                registry: container.registry,
                progressStore: container.progress
            )
        )
    }

    var body: some View {
        ReaderScreen(model: model, onLeave: onLeave)
            .userActivity(ReadingActivity.type, isActive: model.chapter != nil) { activity in
                guard let chapter = model.chapter else { return }
                activity.title = model.bookTitle
                activity.isEligibleForHandoff = false
                activity.addUserInfoEntries(
                    from: ReadingActivity.payload(
                        identity: model.identity,
                        chapterId: chapter.chapterId,
                        bookTitle: model.bookTitle
                    )
                )
            }
    }
}

struct VerificationHost: View {
    @StateObject private var model: VerificationModel
    private let onClose: () -> Void

    /// The source is already open when this route is pushed, so the declared web-login origins are
    /// known here; an empty set makes the session refuse to open rather than browsing anywhere.
    init(container: AppContainer, flow: SourceFlowController, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let source = flow.activeSource
        let origins = source?.webLoginOrigins ?? []
        _model = StateObject(
            wrappedValue: VerificationModel(
                sourceId: source?.sourceId.value ?? "",
                origins: origins,
                initialUrl: origins.map({ $0.canonical }).sorted(by: CanonicalOrder.precedes).first ?? "",
                userAgent: AppContainer.userAgent,
                sessions: container.sessions,
                registry: container.registry
            )
        )
    }

    var body: some View {
        VerificationScreen(model: model, onClose: onClose)
    }
}

/// The market shares one model across its screens so a repository added on one is visible on the
/// next without a second read.
@MainActor
final class MarketHolder: ObservableObject {
    let model: ExtensionsModel
    let client: ExtensionRepositoryClient
    let lifecycle: ExtensionLifecycle
    private let container: AppContainer

    init(container: AppContainer) {
        self.container = container
        client = ExtensionRepositoryClient(gateway: container.gateway)
        lifecycle = ExtensionLifecycle(
            installed: container.installedExtensions,
            registry: container.registry,
            remoteLibrary: container.remoteLibrary,
            trust: container.trust,
            hostApiVersion: container.hostApi
        )
        model = ExtensionsModel(
            registry: container.registry,
            repositories: container.repositories,
            trust: container.trust,
            client: client,
            lifecycle: lifecycle
        )
    }

    func detail(_ descriptor: RepositoryDescriptor) -> RepositoryDetailModel {
        RepositoryDetailModel(
            descriptor: descriptor,
            registry: container.registry,
            repositories: container.repositories,
            trust: container.trust,
            client: client,
            lifecycle: lifecycle,
            hostApi: container.hostApi
        )
    }
}

struct RepositoryDetailHost: View {
    @ObservedObject var market: MarketHolder
    @StateObject private var model: RepositoryDetailModel
    private let onRemoved: () -> Void

    init(market: MarketHolder, descriptor: RepositoryDescriptor, onRemoved: @escaping () -> Void) {
        self.market = market
        self.onRemoved = onRemoved
        _model = StateObject(wrappedValue: market.detail(descriptor))
    }

    var body: some View {
        RepositoryDetailScreen(model: model) {
            Task {
                await market.model.removeRepository(model.descriptor.repositoryId)
                onRemoved()
            }
        }
    }
}
