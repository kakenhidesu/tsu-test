// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public struct LibraryBook: Hashable, Sendable {
    public let identity: BookIdentity
    public let title: String
    public let addedAt: Date
    public let metadataUpdatedAt: Date
    public let authors: Set<String>
    public let coverUrl: String?
    public let canonicalUrl: String?
    public let status: String?
    public let remoteTags: Set<String>
    public let sourceUpdateKey: String?
    public let hasUnreadUpdate: Bool

    public init(
        identity: BookIdentity,
        title: String,
        addedAt: Date,
        metadataUpdatedAt: Date,
        authors: Set<String> = [],
        coverUrl: String? = nil,
        canonicalUrl: String? = nil,
        status: String? = nil,
        remoteTags: Set<String> = [],
        sourceUpdateKey: String? = nil,
        hasUnreadUpdate: Bool = false
    ) {
        self.identity = identity
        self.title = title
        self.addedAt = addedAt
        self.metadataUpdatedAt = metadataUpdatedAt
        self.authors = authors
        self.coverUrl = coverUrl
        self.canonicalUrl = canonicalUrl
        self.status = status
        self.remoteTags = remoteTags
        self.sourceUpdateKey = sourceUpdateKey
        self.hasUnreadUpdate = hasUnreadUpdate
    }

    public var author: String? { CanonicalOrder.sorted(authors).first }
}

public enum CollectionKind: String, Sendable, CaseIterable {
    case manual = "MANUAL"
    case smart = "SMART"
    case subscription = "SUBSCRIPTION"
}

public struct LibraryCollection: Hashable, Sendable {
    public let collectionId: String
    public let kind: CollectionKind
    public let title: String
    public let parentCollectionId: String?
    public let displayOrder: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        collectionId: String,
        kind: CollectionKind,
        title: String,
        parentCollectionId: String?,
        displayOrder: Int64,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date? = nil
    ) throws {
        guard isNonBlank(collectionId), collectionId.utf16.count <= 128 else {
            throw DatabaseError.invariantViolated("Invalid collection ID")
        }
        guard isNonBlank(title), title.utf16.count <= 512 else {
            throw DatabaseError.invariantViolated("Invalid collection title")
        }
        guard parentCollectionId != collectionId else {
            throw DatabaseError.invariantViolated("A collection cannot parent itself")
        }
        self.collectionId = collectionId
        self.kind = kind
        self.title = title
        self.parentCollectionId = parentCollectionId
        self.displayOrder = displayOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum RemoteReconciliationState: String, Sendable, CaseIterable {
    case pendingUserAction = "PENDING_USER_ACTION"
    case inFlight = "IN_FLIGHT"
    case confirmed = "CONFIRMED"
    case unresolved = "UNRESOLVED"
    case cancelled = "CANCELLED"
}

public struct LibraryEntry: Hashable, Sendable {
    public let book: LibraryBook
    public let libraryAddedAt: Date
    public let rating: Int?
    public let localTags: [String]
    public let readLater: Bool
    public let sourceAvailable: Bool
    public let reconciliation: RemoteReconciliationState?
    public let progress: ReadingProgress?

    public init(
        book: LibraryBook,
        libraryAddedAt: Date,
        rating: Int?,
        localTags: [String],
        readLater: Bool = false,
        sourceAvailable: Bool,
        reconciliation: RemoteReconciliationState?,
        progress: ReadingProgress? = nil
    ) throws {
        if let rating, !(1...5).contains(rating) {
            throw DatabaseError.invariantViolated("Rating must be 1..5")
        }
        self.book = book
        self.libraryAddedAt = libraryAddedAt
        self.rating = rating
        self.localTags = localTags
        self.readLater = readLater
        self.sourceAvailable = sourceAvailable
        self.reconciliation = reconciliation
        self.progress = progress
    }
}

public struct SourceRemotePolicy: Hashable, Sendable {
    public let sourceId: String
    public let trustedPublisherFingerprint: String
    public let capabilitySetFingerprint: String
    public let approvedOrigin: String
    public let addWritebackEnabled: Bool
    public let firstImportPromptDismissed: Bool

    public init(
        sourceId: String,
        trustedPublisherFingerprint: String,
        capabilitySetFingerprint: String,
        approvedOrigin: String,
        addWritebackEnabled: Bool,
        firstImportPromptDismissed: Bool
    ) {
        self.sourceId = sourceId
        self.trustedPublisherFingerprint = trustedPublisherFingerprint
        self.capabilitySetFingerprint = capabilitySetFingerprint
        self.approvedOrigin = approvedOrigin
        self.addWritebackEnabled = addWritebackEnabled
        self.firstImportPromptDismissed = firstImportPromptDismissed
    }
}

public struct SourceAvailability: Hashable, Sendable {
    public let sourceId: String
    public let verifiedVersion: String?
    public let available: Bool
    public let generation: Int64

    public init(sourceId: String, verifiedVersion: String?, available: Bool, generation: Int64) {
        self.sourceId = sourceId
        self.verifiedVersion = verifiedVersion
        self.available = available
        self.generation = generation
    }
}

/// The durable semantic reader position. `updatedAt` and `locator.capturedAt` must be identical:
/// a capture is one logical update, not two independently mergeable clocks.
public struct ReadingProgress: Hashable, Sendable {
    public let identity: BookIdentity
    public let locator: ReaderLocator
    public let updatedAt: Date

    public init(identity: BookIdentity, locator: ReaderLocator, updatedAt: Date? = nil) throws {
        let timestamp = updatedAt ?? locator.capturedAt
        guard locator.document.sourceId == identity.sourceId else {
            throw DatabaseError.invariantViolated("Locator source does not match book")
        }
        guard locator.document.remoteBookId == identity.remoteBookId else {
            throw DatabaseError.invariantViolated("Locator book does not match book")
        }
        guard timestamp == locator.capturedAt else {
            throw DatabaseError.invariantViolated("Progress timestamp must equal locator capture time")
        }
        self.identity = identity
        self.locator = locator
        self.updatedAt = timestamp
    }
}

public enum ProgressWriteResult: Sendable, Equatable {
    case applied
    case keptExisting
}
