// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import BrowseFeature
import ReaderFeature
import SearchFeature
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol

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

struct BookHost: View {
    @ObservedObject var flow: SourceFlowController
    @StateObject private var model: BookModel

    init(container: AppContainer, flow: SourceFlowController, identity: BookIdentity) {
        self.flow = flow
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
        BookScreen(
            model: model,
            coverState: { flow.cover($0) },
            openChapter: { chapter in
                flow.remember(chapter: chapter)
                Task { await flow.push(.reader(model.identity, chapter.chapterId)) }
            }
        )
    }
}

struct ReaderHost: View {
    @ObservedObject var flow: SourceFlowController
    @StateObject private var model: ReaderModel

    init(container: AppContainer, flow: SourceFlowController, identity: BookIdentity, chapterId: String) {
        self.flow = flow
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
        ReaderScreen(model: model) { Task { await flow.pop() } }
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
                sessions: VerifiedBrowserSessionStore(credentials: container.credentials)
            )
        )
    }

    var body: some View {
        VerificationScreen(model: model, onClose: onClose)
    }
}
