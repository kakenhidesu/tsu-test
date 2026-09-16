// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The website writes a source may perform. Each has its own signed policy, its own consent receipt
/// and its own reconciliation rows; nothing about one authorizes another.
public enum RemoteWriteOperation: String, Sendable, CaseIterable {
    case add = "ADD"
    case remove = "REMOVE"
    case move = "MOVE"
}

/// One attempt at a website write, kept as an append-only history per book: the newest row is the
/// state a screen shows, and an unresolved row blocks a fresh attempt until it is retried or, for a
/// move or removal, explicitly released.
public struct RemoteReconciliationRecord: Hashable, Sendable {
    public let id: String
    public let identity: BookIdentity
    public let operation: RemoteWriteOperation
    public let state: RemoteReconciliationState
    public let targetId: String?
    public let targetName: String?
    public let diagnosticId: String?
    public let createdAt: Date
    public let updatedAt: Date
}

/// One source's website library as last observed. `frozen` means the source can no longer vouch for
/// it (uninstalled, changed, or unreachable): the rows stay, but nothing treats them as current.
public struct RemoteMirrorBinding: Hashable, Sendable {
    public let sourceId: String
    public let displayName: String
    public let frozen: Bool
    public let updatedAt: Date
}

/// A destination the website exposes. A target absent from a later snapshot survives frozen, with
/// its pins and order, and is restored when it reappears.
public struct RemoteMirrorTarget: Hashable, Sendable {
    public static let folderKind = "folder"

    public let sourceId: String
    public let targetId: String
    public let displayName: String
    public let parentId: String?
    public let kind: String
    public let frozen: Bool

    public init(sourceId: String, targetId: String, displayName: String, parentId: String?, kind: String, frozen: Bool = false) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.displayName = displayName
        self.parentId = parentId
        self.kind = kind
        self.frozen = frozen
    }
}

public struct RemoteMirrorItem: Hashable, Sendable {
    public let identity: BookIdentity
    public let targetId: String?
    public let updatedAt: Date
}

/// A complete observation of one source's website library, accepted only under an unchanged lease.
public struct RemoteMirrorSnapshot: Sendable {
    public let sourceId: String
    public let displayName: String
    public let targets: [RemoteMirrorTarget]
    public let books: [LibraryBook]
    public let memberships: [BookIdentity: String?]
    public let expectedVersion: String
    public let expectedCapabilityFingerprint: String
    public let expectedGeneration: Int64
    public let observedAt: Date

    public init(
        sourceId: String,
        displayName: String,
        targets: [RemoteMirrorTarget],
        books: [LibraryBook],
        memberships: [BookIdentity: String?],
        expectedVersion: String,
        expectedCapabilityFingerprint: String,
        expectedGeneration: Int64,
        observedAt: Date
    ) {
        self.sourceId = sourceId
        self.displayName = displayName
        self.targets = targets
        self.books = books
        self.memberships = memberships
        self.expectedVersion = expectedVersion
        self.expectedCapabilityFingerprint = expectedCapabilityFingerprint
        self.expectedGeneration = expectedGeneration
        self.observedAt = observedAt
    }
}

public struct RemoteMirror: Sendable {
    public let binding: RemoteMirrorBinding
    public let targets: [RemoteMirrorTarget]
    public let items: [RemoteMirrorItem]
}
