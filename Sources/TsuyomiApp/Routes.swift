// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol
import TsuyomiSource

/// Where the source flow returns after a verification round trip.
public enum SourceRestorationTarget: String, Hashable, Sendable {
    case search
    case detail
    case reader
}

public enum Route: Hashable, Sendable {
    case browse
    case sourceHome(SourceId)
    case search(SourceId)
    case remoteLibrary(SourceId)
    case detail(BookIdentity)
    case reader(BookIdentity, String)
    case verification(SourceId)
    case extensions
    case extensionRepository(RepositoryDescriptor)
    case publisherKeys

    /// The tab a route belongs to. Every source route lives under browse, so leaving the tab is the
    /// one place the source flow can be torn down.
    public var root: Route {
        switch self {
        case .browse: return .browse
        case .sourceHome, .search, .remoteLibrary, .detail, .reader, .verification,
             .extensions, .extensionRepository, .publisherKeys:
            return .browse
        }
    }

    public var ownsSourceFlow: Bool { root == .browse }

    public var restorationTarget: SourceRestorationTarget? {
        switch self {
        case .search, .remoteLibrary: return .search
        case .detail: return .detail
        case .reader: return .reader
        case .browse, .sourceHome, .verification, .extensions, .extensionRepository, .publisherKeys:
            return nil
        }
    }

    /// The source a route is scoped to, if any. A route without one cannot keep a source open.
    public var sourceId: String? {
        switch self {
        case .browse, .extensions, .extensionRepository, .publisherKeys: return nil
        case .sourceHome(let id), .search(let id), .remoteLibrary(let id), .verification(let id):
            return id.value
        case .detail(let identity): return identity.sourceId
        case .reader(let identity, _): return identity.sourceId
        }
    }
}
