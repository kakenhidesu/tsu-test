// SPDX-License-Identifier: AGPL-3.0-only

import BrowseFeature
import ExtensionsFeature
import LibraryFeature
import SwiftUI
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiUI

public enum RootTab: String, Hashable, CaseIterable {
    case library
    case browse
    case more

    var title: LocalizedStringKey {
        switch self {
        case .library: return "书架"
        case .browse: return "浏览"
        case .more: return "更多"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .browse: return "safari"
        case .more: return "ellipsis.circle"
        }
    }
}

/// The root tabs and the browse tab's navigation stack. Every source screen is built here so a route
/// and the model that serves it are created together and die together.
public struct AppRootView: View {
    @ObservedObject private var container: AppContainer
    @ObservedObject private var flow: SourceFlowController
    @StateObject private var browse: BrowseModel
    @StateObject private var library: LibraryModel
    @StateObject private var libraryCovers: LibraryCoverProvider
    @StateObject private var market: MarketHolder
    @State private var tab: RootTab = .library
    @State private var libraryPath: [BookIdentity] = []

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
        _library = StateObject(
            wrappedValue: LibraryModel(
                library: container.library,
                collections: container.collections,
                preferences: container.preferences
            )
        )
        _libraryCovers = StateObject(
            wrappedValue: LibraryCoverProvider(
                roots: container.roots,
                registry: container.registry,
                credentials: container.credentials
            )
        )
        _market = StateObject(wrappedValue: MarketHolder(container: container))
    }

    public var body: some View {
        TabView(selection: $tab) {
            libraryTab
                .tabItem { Label(RootTab.library.title, systemImage: RootTab.library.symbol) }
                .tag(RootTab.library)
            browseTab
                .tabItem { Label(RootTab.browse.title, systemImage: RootTab.browse.symbol) }
                .tag(RootTab.browse)
            MoreScreen(container: container)
                .tabItem { Label(RootTab.more.title, systemImage: RootTab.more.symbol) }
                .tag(RootTab.more)
        }
        .preferredColorScheme(container.preferences.colorScheme.colorScheme)
        .onChange(of: tab) { selected in
            guard selected != .browse else { return }
            Task { await flow.popToRoot() }
        }
        .onContinueUserActivity(ReadingActivity.type) { activity in
            guard let route = ReadingActivity.route(from: activity.userInfo ?? [:]) else { return }
            tab = .browse
            Task { await flow.push(route) }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "hxp" else { return }
            tab = .browse
            Task {
                await container.loadTrust()
                if flow.path.last != .extensions {
                    await flow.push(.extensions)
                }
                await market.model.importPackage(at: url)
            }
        }
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryPath) {
            LibraryScreen(
                model: library,
                coverState: { libraryCovers.cover($0) },
                openBook: { libraryPath.append($0) }
            )
            .navigationDestination(for: BookIdentity.self) { identity in
                BookHost(
                    container: container,
                    flow: flow,
                    identity: identity,
                    coverState: { libraryCovers.cover($0) }
                )
            }
        }
    }

    private var browseTab: some View {
        NavigationStack(path: $flow.path) {
            browseScreen
                .navigationDestination(for: Route.self) { destination($0) }
                .task {
                    await container.loadTrust()
                    await browse.load()
                    await flow.restore()
                }
        }
    }

    private var browseScreen: some View {
        BrowseScreen(
            model: browse,
            actions: BrowseActions(
                openHome: { push(.sourceHome($0)) },
                openSearch: { push(.search($0)) },
                openRemoteLibrary: { push(.remoteLibrary($0)) },
                openSignIn: { push(.verification($0)) },
                openExtensions: { push(.extensions) }
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
            BookHost(container: container, flow: flow, identity: identity, coverState: { flow.cover($0) })
        case .reader(let identity, let chapterId):
            ReaderHost(container: container, flow: flow, identity: identity, chapterId: chapterId)
        case .verification:
            VerificationHost(container: container, flow: flow) {
                Task {
                    await flow.pop()
                    await browse.load()
                }
            }
        case .extensions:
            ExtensionsScreen(
                model: market.model,
                openRepository: { push(.extensionRepository($0)) },
                openPublisherKeys: { push(.publisherKeys) }
            )
        case .extensionRepository(let descriptor):
            RepositoryDetailHost(market: market, descriptor: descriptor) {
                Task { await flow.pop() }
            }
        case .publisherKeys:
            PublisherKeysScreen(model: market.model)
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
