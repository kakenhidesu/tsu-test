// SPDX-License-Identifier: AGPL-3.0-only

import BrowseFeature
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

/// The browse tab's navigation stack. Every screen under it is built here so a route and the model
/// that serves it are created together and die together.
public struct AppRootView: View {
    @ObservedObject private var container: AppContainer
    @ObservedObject private var flow: SourceFlowController
    @StateObject private var browse: BrowseModel

    public init(container: AppContainer, flow: SourceFlowController) {
        self.container = container
        self.flow = flow
        _browse = StateObject(
            wrappedValue: BrowseModel(
                registry: container.registry,
                credentials: container.credentials,
                remoteLibrary: container.remoteLibrary
            )
        )
    }

    public var body: some View {
        NavigationStack(path: $flow.path) {
            browseScreen
                .navigationDestination(for: Route.self) { destination($0) }
                .task {
                    await browse.load()
                    await flow.restore()
                }
        }
        .preferredColorScheme(container.preferences.colorScheme.colorScheme)
    }

    private var browseScreen: some View {
        BrowseScreen(
            model: browse,
            actions: BrowseActions(
                openHome: { push(.sourceHome($0)) },
                openSearch: { push(.search($0)) },
                openRemoteLibrary: { push(.remoteLibrary($0)) },
                openSignIn: { push(.verification($0)) }
            )
        )
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .browse:
            browseScreen
        case .sourceHome(let sourceId):
            SourceHomeHost(container: container, flow: flow, sourceId: sourceId)
        case .search(let sourceId):
            SearchHost(container: container, flow: flow, sourceId: sourceId)
        case .remoteLibrary(let sourceId):
            RemoteLibraryHost(container: container, flow: flow, sourceId: sourceId)
        case .detail(let identity):
            BookHost(container: container, flow: flow, identity: identity)
        case .reader(let identity, let chapterId):
            ReaderHost(container: container, flow: flow, identity: identity, chapterId: chapterId)
        case .verification:
            VerificationHost(container: container, flow: flow) {
                Task {
                    await flow.pop()
                    await browse.load()
                }
            }
        }
    }

    private func push(_ route: Route) {
        Task { await flow.push(route) }
    }
}

extension ColorSchemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
