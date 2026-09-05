// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public let maximumTransferBytes = 32 * 1024 * 1024

public enum ImportKind: String, Sendable, Codable, CaseIterable {
    case tsuyomiTransfer = "TSUYOMI_TRANSFER"
    case hikariBackup = "HIKARI_BACKUP"
}

public enum ImportSeverity: String, Sendable, Codable, CaseIterable {
    case warning = "WARNING"
    case conflict = "CONFLICT"
}

public struct PortableReaderPreferences: Hashable, Sendable {
    public let flow: String?
    public let fontScale: Double?
    public let lineHeight: Double?
    public let theme: String?

    public static let flows: Set<String> = ["scroll", "paged"]
    public static let themes: Set<String> = ["paper", "warmGray", "nightInk", "black", "inkGreen"]

    public init(flow: String? = nil, fontScale: Double? = nil, lineHeight: Double? = nil, theme: String? = nil) {
        self.flow = flow
        self.fontScale = fontScale
        self.lineHeight = lineHeight
        self.theme = theme
    }
}

public struct TransferProgress: Hashable, Sendable {
    public let chapterId: String?
    public let textAnchor: String?
    public let characterOffset: Int?
    public let chapterProgress: Double?
    public let bookProgress: Double?
    public let updatedAt: Date

    public init(
        chapterId: String? = nil,
        textAnchor: String? = nil,
        characterOffset: Int? = nil,
        chapterProgress: Double? = nil,
        bookProgress: Double? = nil,
        updatedAt: Date
    ) {
        self.chapterId = chapterId
        self.textAnchor = textAnchor
        self.characterOffset = characterOffset
        self.chapterProgress = chapterProgress
        self.bookProgress = bookProgress
        self.updatedAt = updatedAt
    }

    public func withUpdatedAt(_ value: Date) -> TransferProgress {
        TransferProgress(
            chapterId: chapterId,
            textAnchor: textAnchor,
            characterOffset: characterOffset,
            chapterProgress: chapterProgress,
            bookProgress: bookProgress,
            updatedAt: value
        )
    }
}

public struct TransferBook: Hashable, Sendable {
    public static let statuses: Set<String> = ["unknown", "ongoing", "completed", "hiatus", "cancelled"]

    public let identity: BookIdentity
    public let title: String
    public let authors: Set<String>
    public let canonicalUrl: String?
    public let coverUrl: String?
    public let status: String
    public let remoteTags: Set<String>
    public let localTags: Set<String>
    public let shelfIds: Set<String>
    public let rating: Double?
    public let readLater: Bool
    public let addedAt: Date?
    public let updatedAt: Date
    public let progress: TransferProgress?

    public init(
        identity: BookIdentity,
        title: String,
        authors: Set<String> = [],
        canonicalUrl: String? = nil,
        coverUrl: String? = nil,
        status: String = "unknown",
        remoteTags: Set<String> = [],
        localTags: Set<String> = [],
        shelfIds: Set<String> = [],
        rating: Double? = nil,
        readLater: Bool = false,
        addedAt: Date? = nil,
        updatedAt: Date,
        progress: TransferProgress? = nil
    ) {
        self.identity = identity
        self.title = title
        self.authors = authors
        self.canonicalUrl = canonicalUrl
        self.coverUrl = coverUrl
        self.status = status
        self.remoteTags = remoteTags
        self.localTags = localTags
        self.shelfIds = shelfIds
        self.rating = rating
        self.readLater = readLater
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.progress = progress
    }
}

public struct TransferShelf: Hashable, Sendable {
    public let id: String
    public let name: String
    public let parentId: String?
    public let position: Int

    public init(id: String, name: String, parentId: String? = nil, position: Int = 0) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.position = position
    }

    public func withParentId(_ value: String?) -> TransferShelf {
        TransferShelf(id: id, name: name, parentId: value, position: position)
    }
}

public struct TransferSnapshot: Hashable, Sendable {
    public let createdAt: Date
    public let library: [TransferBook]
    public let shelves: [TransferShelf]
    public let readerPreferences: PortableReaderPreferences?

    public init(
        createdAt: Date,
        library: [TransferBook],
        shelves: [TransferShelf],
        readerPreferences: PortableReaderPreferences? = nil
    ) {
        self.createdAt = createdAt
        self.library = library
        self.shelves = shelves
        self.readerPreferences = readerPreferences
    }
}

public struct ImportedSmartCollection: Hashable, Sendable {
    public let collectionId: String
    public let title: String
    public let astJson: String

    public init(collectionId: String, title: String, astJson: String) {
        self.collectionId = collectionId
        self.title = title
        self.astJson = astJson
    }
}

public struct ImportedSubscriptionDraft: Hashable, Sendable {
    public let collectionId: String
    public let title: String
    public let mode: String
    public let sourceScopeJson: String
    public let queryJson: String

    public init(collectionId: String, title: String, mode: String, sourceScopeJson: String, queryJson: String) {
        self.collectionId = collectionId
        self.title = title
        self.mode = mode
        self.sourceScopeJson = sourceScopeJson
        self.queryJson = queryJson
    }
}

public struct ImportWarning: Hashable, Sendable {
    public let ordinal: Int
    public let safeCode: String
    public let safeRecordRef: String?
    public let fieldName: String?
    public let severity: ImportSeverity

    public init(
        ordinal: Int,
        safeCode: String,
        safeRecordRef: String? = nil,
        fieldName: String? = nil,
        severity: ImportSeverity = .warning
    ) {
        self.ordinal = ordinal
        self.safeCode = safeCode
        self.safeRecordRef = safeRecordRef
        self.fieldName = fieldName
        self.severity = severity
    }
}

public struct SourceSearchHistory: Hashable, Sendable {
    public let sourceId: String
    public let query: String
    public let lastUsedAt: Date

    public init(sourceId: String, query: String, lastUsedAt: Date) {
        self.sourceId = sourceId
        self.query = query
        self.lastUsedAt = lastUsedAt
    }
}

public struct SourceBrowsingHistory: Hashable, Sendable {
    public let identity: BookIdentity
    public let lastViewedAt: Date

    public init(identity: BookIdentity, lastViewedAt: Date) {
        self.identity = identity
        self.lastViewedAt = lastViewedAt
    }
}

public struct ImportPlan: Hashable, Sendable {
    public let kind: ImportKind
    public let sourceCreatedAt: Date
    public let books: [TransferBook]
    public let shelves: [TransferShelf]
    public let readerPreferences: PortableReaderPreferences?
    public let searchHistory: [SourceSearchHistory]
    public let browsingHistory: [SourceBrowsingHistory]
    public let warnings: [ImportWarning]
    public let smartCollections: [ImportedSmartCollection]
    public let subscriptionDrafts: [ImportedSubscriptionDraft]

    public init(
        kind: ImportKind,
        sourceCreatedAt: Date,
        books: [TransferBook],
        shelves: [TransferShelf],
        readerPreferences: PortableReaderPreferences?,
        searchHistory: [SourceSearchHistory] = [],
        browsingHistory: [SourceBrowsingHistory] = [],
        warnings: [ImportWarning] = [],
        smartCollections: [ImportedSmartCollection] = [],
        subscriptionDrafts: [ImportedSubscriptionDraft] = []
    ) {
        self.kind = kind
        self.sourceCreatedAt = sourceCreatedAt
        self.books = books
        self.shelves = shelves
        self.readerPreferences = readerPreferences
        self.searchHistory = searchHistory
        self.browsingHistory = browsingHistory
        self.warnings = warnings
        self.smartCollections = smartCollections
        self.subscriptionDrafts = subscriptionDrafts
    }
}

public struct ImportSummary: Hashable, Sendable {
    public let sessionId: String
    public let kind: ImportKind
    public let importedBooks: Int
    public let importedShelves: Int
    public let warningCount: Int
    public let completedAt: Date

    public init(
        sessionId: String,
        kind: ImportKind,
        importedBooks: Int,
        importedShelves: Int,
        warningCount: Int,
        completedAt: Date
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.importedBooks = importedBooks
        self.importedShelves = importedShelves
        self.warningCount = warningCount
        self.completedAt = completedAt
    }
}

public enum ImportParseResult: Hashable, Sendable {
    case ready(plan: ImportPlan, canonicalDigest: String)
    case fatal(safeCode: String)
}
