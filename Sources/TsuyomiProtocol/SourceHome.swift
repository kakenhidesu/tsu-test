// SPDX-License-Identifier: AGPL-3.0-only

public struct SourceBookSummary: Hashable, Sendable {
    public let identity: BookIdentity
    public let title: String
    public let author: String?
    public let coverUrl: String?
    public let canonicalUrl: String

    public init(
        identity: BookIdentity,
        title: String,
        author: String?,
        coverUrl: String?,
        canonicalUrl: String
    ) throws {
        guard Grammar.hasCodePoints(title, in: 1...512) else { throw ProtocolError.invalidBookTitle }
        if let author, !Grammar.hasCodePoints(author, in: 1...256) { throw ProtocolError.invalidAuthor }
        self.identity = identity
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.canonicalUrl = canonicalUrl
    }
}

public struct SourceHomeFilterOption: Hashable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String) throws {
        guard Grammar.isToken(value, limit: 64) else { throw ProtocolError.invalidHomeFilterOption }
        guard Grammar.hasCodePoints(label, in: 1...128) else { throw ProtocolError.invalidHomeFilterLabel }
        self.value = value
        self.label = label
    }
}

public struct SourceHomeFilter: Hashable, Sendable {
    public let id: String
    public let label: String
    public let options: [SourceHomeFilterOption]

    public init(id: String, label: String, options: [SourceHomeFilterOption]) throws {
        guard Grammar.isToken(id, limit: 64) else { throw ProtocolError.invalidHomeFilterId }
        guard Grammar.hasCodePoints(label, in: 1...128) else { throw ProtocolError.invalidHomeFilterLabel }
        guard (1...32).contains(options.count) else { throw ProtocolError.invalidHomeFilterOptions }
        guard options.map(\.value).hasDistinctElements else { throw ProtocolError.duplicateHomeFilterOption }
        self.id = id
        self.label = label
        self.options = options
    }
}

public struct SourceHomeFeature: Hashable, Sendable {
    public let id: String
    public let title: String
    public let supportingText: String?
    public let selectedFilters: [String: String]

    public init(id: String, title: String, supportingText: String?, selectedFilters: [String: String]) throws {
        guard Grammar.isToken(id, limit: 64) else { throw ProtocolError.invalidHomeFeatureId }
        guard Grammar.hasCodePoints(title, in: 1...256) else { throw ProtocolError.invalidHomeFeatureTitle }
        if let supportingText, !Grammar.hasCodePoints(supportingText, in: 1...256) {
            throw ProtocolError.invalidHomeFeatureSupportingText
        }
        guard (1...16).contains(selectedFilters.count) else { throw ProtocolError.invalidHomeFeatureSelection }
        guard selectedFilters.allSatisfy({ Grammar.isToken($0.key, limit: 64) && Grammar.isToken($0.value, limit: 64) })
        else { throw ProtocolError.invalidHomeFeatureSelection }
        self.id = id
        self.title = title
        self.supportingText = supportingText
        self.selectedFilters = selectedFilters
    }
}

public struct SourceHomeSection: Hashable, Sendable {
    public let id: String
    public let title: String
    public let items: [SourceBookSummary]

    public init(id: String, title: String, items: [SourceBookSummary]) throws {
        guard Grammar.isToken(id, limit: 64) else { throw ProtocolError.invalidHomeSectionId }
        guard Grammar.hasCodePoints(title, in: 1...256) else { throw ProtocolError.invalidHomeSectionTitle }
        guard (1...100).contains(items.count) else { throw ProtocolError.invalidHomeSectionItems }
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct SourceHomePage: Hashable, Sendable {
    public let title: String
    public let schemaVersion: Int
    public let filters: [SourceHomeFilter]
    public let selectedFilters: [String: String]
    public let sections: [SourceHomeSection]
    public let features: [SourceHomeFeature]
    public let nextCursor: String?
    public let complete: Bool

    public init(
        title: String,
        schemaVersion: Int,
        filters: [SourceHomeFilter],
        selectedFilters: [String: String],
        sections: [SourceHomeSection],
        features: [SourceHomeFeature] = [],
        nextCursor: String?,
        complete: Bool
    ) throws {
        guard Grammar.hasCodePoints(title, in: 1...256) else { throw ProtocolError.invalidSourceHomeTitle }
        guard schemaVersion == 1 else { throw ProtocolError.unsupportedSourceHomeSchemaVersion }
        guard filters.count <= 16, filters.map(\.id).hasDistinctElements else {
            throw ProtocolError.invalidSourceHomeFilters
        }
        guard selectedFilters.count <= filters.count else { throw ProtocolError.invalidSelectedHomeFilters }
        for (id, value) in selectedFilters {
            let matches = filters.filter { $0.id == id }
            guard matches.count == 1, let filter = matches.first else {
                throw ProtocolError.unknownSelectedHomeFilter
            }
            guard filter.options.contains(where: { $0.value == value }) else {
                throw ProtocolError.invalidSelectedHomeFilterOption
            }
        }
        guard (1...16).contains(sections.count) else { throw ProtocolError.invalidSourceHomeSections }
        guard sections.map(\.id).hasDistinctElements else { throw ProtocolError.duplicateSourceHomeSection }
        guard features.count <= 4, features.map(\.id).hasDistinctElements else {
            throw ProtocolError.invalidSourceHomeFeatures
        }
        guard sections.reduce(0, { $0 + $1.items.count }) <= 100 else { throw ProtocolError.sourceHomePageTooLarge }
        if let nextCursor, !Grammar.isToken(nextCursor, limit: 128) { throw ProtocolError.invalidSourceHomeCursor }
        guard complete || nextCursor != nil else { throw ProtocolError.incompleteSourceHomePageRequiresCursor }
        self.title = title
        self.schemaVersion = schemaVersion
        self.filters = filters
        self.selectedFilters = selectedFilters
        self.sections = sections
        self.features = features
        self.nextCursor = nextCursor
        self.complete = complete
    }
}

public struct RemoteLibraryPage: Hashable, Sendable {
    public let items: [SourceBookSummary]
    public let nextCursor: String?
    public let complete: Bool

    public init(items: [SourceBookSummary], nextCursor: String?, complete: Bool) throws {
        guard items.count <= 100 else { throw ProtocolError.remotePageTooLarge }
        if let nextCursor, nextCursor.allSatisfy(\.isWhitespace) { throw ProtocolError.invalidRemoteCursor }
        guard complete || nextCursor != nil else { throw ProtocolError.incompletePageRequiresCursor }
        self.items = items
        self.nextCursor = nextCursor
        self.complete = complete
    }
}

public enum RemoteLibraryAddOutcome: String, Sendable, Codable, CaseIterable {
    case applied = "APPLIED"
    case alreadyPresent = "ALREADY_PRESENT"
}

public struct RemoteLibraryAddResult: Hashable, Sendable {
    public let identity: BookIdentity
    public let outcome: RemoteLibraryAddOutcome

    public init(identity: BookIdentity, outcome: RemoteLibraryAddOutcome) {
        self.identity = identity
        self.outcome = outcome
    }
}
