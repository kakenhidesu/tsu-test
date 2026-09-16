// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A destination the website exposes, as the source reports it. Identities are opaque; a host never
/// synthesises a default, a favourites or a finished target, and a target becomes a valid move
/// input only once the matching signed policy and an explicit action agree.
public struct RemoteLibraryTarget: Hashable, Sendable {
    public static let folderKind = "folder"

    public let targetId: String
    public let displayName: String
    public let parentId: String?
    public let kind: String

    public init(targetId: String, displayName: String, parentId: String?, kind: String) throws {
        guard Grammar.hasCodePoints(targetId, in: 1...128), targetId.contains(where: { !$0.isWhitespace }),
              Grammar.hasCodePoints(displayName, in: 1...128), displayName.contains(where: { !$0.isWhitespace }),
              kind == RemoteLibraryTarget.folderKind, parentId != targetId else {
            throw ProtocolError.invalidRemoteTarget
        }
        self.targetId = targetId
        self.displayName = displayName
        self.parentId = parentId
        self.kind = kind
    }
}

/// The complete, bounded, duplicate-free target list of one source. A parent must be one of the
/// listed targets: a dangling or self-referencing parent is a malformed response, not a root.
public struct RemoteLibraryTargetList: Hashable, Sendable {
    public static let maximumTargets = 128

    public let sourceId: String
    public let targets: [RemoteLibraryTarget]

    public init(sourceId: String, targets: [RemoteLibraryTarget]) throws {
        guard (1...RemoteLibraryTargetList.maximumTargets).contains(targets.count) else {
            throw ProtocolError.invalidRemoteTarget
        }
        let ids = Set(targets.map(\.targetId))
        guard ids.count == targets.count,
              targets.allSatisfy({ $0.parentId.map(ids.contains) ?? true }) else {
            throw ProtocolError.invalidRemoteTarget
        }
        self.sourceId = sourceId
        self.targets = targets
    }
}

public enum RemoteLibraryRemoveOutcome: String, Sendable, Codable, CaseIterable {
    case applied = "APPLIED"
    case alreadyAbsent = "ALREADY_ABSENT"
}

public struct RemoteLibraryRemoveResult: Hashable, Sendable {
    public let identity: BookIdentity
    public let outcome: RemoteLibraryRemoveOutcome

    public init(identity: BookIdentity, outcome: RemoteLibraryRemoveOutcome) {
        self.identity = identity
        self.outcome = outcome
    }
}

public enum RemoteLibraryMoveOutcome: String, Sendable, Codable, CaseIterable {
    case applied = "APPLIED"
    case alreadyAtTarget = "ALREADY_AT_TARGET"
}

public struct RemoteLibraryMoveResult: Hashable, Sendable {
    public let identity: BookIdentity
    public let targetId: String
    public let outcome: RemoteLibraryMoveOutcome

    public init(identity: BookIdentity, targetId: String, outcome: RemoteLibraryMoveOutcome) {
        self.identity = identity
        self.targetId = targetId
        self.outcome = outcome
    }
}
