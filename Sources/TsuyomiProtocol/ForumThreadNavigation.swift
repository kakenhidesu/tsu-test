// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Catalogue routing for a forum thread (forum-navigation-v1). It is deliberately outside
/// `ReaderDocument`: a document renders one resolved physical page, while navigation records which
/// original source routes alias that page and which derived owner entries passed host verification.
public struct ForumThreadNavigation: Hashable, Sendable, Codable {
    public let identity: ThreadIdentity
    public let revision: String
    public let catalogueEntries: [CatalogueEntry]
    public let ownerCatalogue: OwnerCatalogue?

    public init(
        identity: ThreadIdentity,
        revision: String,
        catalogueEntries: [CatalogueEntry],
        ownerCatalogue: OwnerCatalogue?
    ) throws {
        guard Grammar.hasCodePoints(revision, in: 1...256) else { throw ProtocolError.invalidDocumentRevision }
        guard (1...100_000).contains(catalogueEntries.count) else { throw ProtocolError.invalidCatalogueEntries }
        guard catalogueEntries.map(\.entryId).hasDistinctElements else {
            throw ProtocolError.duplicateCatalogueEntry
        }
        self.identity = identity
        self.revision = revision
        self.catalogueEntries = catalogueEntries
        self.ownerCatalogue = ownerCatalogue
    }

    public struct ThreadIdentity: Hashable, Sendable {
        public let sourceId: String
        public let remoteBookId: String
        public let threadId: String
        public let book: BookIdentity

        public init(sourceId: String, remoteBookId: String, threadId: String) throws {
            self.book = try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId)
            try BookIdentity.requireRemoteId(threadId, field: "threadId")
            self.sourceId = sourceId
            self.remoteBookId = remoteBookId
            self.threadId = threadId
        }
    }

    public enum SelectionRole: String, Sendable, Codable, CaseIterable {
        case canonical
        case alias
    }

    public struct CatalogueEntry: Hashable, Sendable {
        public let entryId: String
        public let label: String
        public let contentId: String
        public let physicalPage: Int
        public let order: Int
        public let selectionRole: SelectionRole
        public let postId: String?

        public init(
            entryId: String,
            label: String,
            contentId: String,
            physicalPage: Int,
            order: Int,
            selectionRole: SelectionRole,
            postId: String?
        ) throws {
            try BookIdentity.requireRemoteId(entryId, field: "entryId")
            guard Grammar.hasCodePoints(label, in: 1...4_096) else { throw ProtocolError.invalidCatalogueLabel }
            try BookIdentity.requireRemoteId(contentId, field: "contentId")
            guard (1...1_000_000_000).contains(physicalPage) else { throw ProtocolError.invalidPhysicalPage }
            guard (0...1_000_000_000).contains(order) else { throw ProtocolError.invalidCatalogueOrder }
            if let postId { try BookIdentity.requireRemoteId(postId, field: "postId") }
            self.entryId = entryId
            self.label = label
            self.contentId = contentId
            self.physicalPage = physicalPage
            self.order = order
            self.selectionRole = selectionRole
            self.postId = postId
        }
    }

    public struct OwnerCatalogue: Hashable, Sendable {
        public let sourceFingerprint: String
        public let verifiedAt: Date
        public let entries: [OwnerEntry]

        public init(sourceFingerprint: String, verifiedAt: Date, entries: [OwnerEntry]) throws {
            guard Grammar.isSha256(sourceFingerprint) else { throw ProtocolError.invalidSourceFingerprint }
            guard (2...10_000).contains(entries.count) else { throw ProtocolError.invalidOwnerCatalogueEntries }
            guard entries.map(\.entryId).hasDistinctElements else { throw ProtocolError.duplicateCatalogueEntry }
            self.sourceFingerprint = sourceFingerprint
            self.verifiedAt = verifiedAt
            self.entries = entries
        }
    }

    public struct OwnerEntry: Hashable, Sendable {
        public let entryId: String
        public let label: String
        public let postId: String
        public let contentId: String
        public let physicalPage: Int

        public init(entryId: String, label: String, postId: String, contentId: String, physicalPage: Int) throws {
            try BookIdentity.requireRemoteId(entryId, field: "entryId")
            guard Grammar.hasCodePoints(label, in: 1...4_096) else { throw ProtocolError.invalidCatalogueLabel }
            try BookIdentity.requireRemoteId(postId, field: "postId")
            try BookIdentity.requireRemoteId(contentId, field: "contentId")
            guard (1...1_000_000_000).contains(physicalPage) else { throw ProtocolError.invalidPhysicalPage }
            self.entryId = entryId
            self.label = label
            self.postId = postId
            self.contentId = contentId
            self.physicalPage = physicalPage
        }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(JSONValue.self)
        guard let object = value.objectValue else { throw ProtocolError.unexpectedJsonType(field: "navigation") }
        guard object.hasOnly(["kind", "identity", "revision", "catalogueEntries", "ownerCatalogue"]) else {
            throw ProtocolError.unknownField("navigation")
        }
        guard let kind = object.string("kind") else { throw ProtocolError.missingField("kind") }
        guard kind == "forumThreadNavigation" else { throw ProtocolError.unknownNavigationKind(kind) }
        guard let identityObject = object.object("identity"),
              identityObject.hasOnly(["sourceId", "remoteBookId", "threadId"]),
              let sourceId = identityObject.string("sourceId"),
              let remoteBookId = identityObject.string("remoteBookId"),
              let threadId = identityObject.string("threadId") else {
            throw ProtocolError.missingField("identity")
        }
        guard let revision = object.string("revision") else { throw ProtocolError.missingField("revision") }
        guard let entries = object.array("catalogueEntries") else {
            throw ProtocolError.missingField("catalogueEntries")
        }
        try self.init(
            identity: ThreadIdentity(sourceId: sourceId, remoteBookId: remoteBookId, threadId: threadId),
            revision: revision,
            catalogueEntries: entries.map { try ForumThreadNavigation.decodeEntry($0) },
            ownerCatalogue: try object.object("ownerCatalogue").map(ForumThreadNavigation.decodeOwnerCatalogue)
        )
    }

    private static func decodeEntry(_ value: JSONValue) throws -> CatalogueEntry {
        guard let object = value.objectValue,
              object.hasOnly(["entryId", "label", "contentId", "physicalPage", "order", "selectionRole", "postId"]),
              let entryId = object.string("entryId"), let label = object.string("label"),
              let contentId = object.string("contentId"), let physicalPage = object.int("physicalPage"),
              let order = object.int("order"), let rawRole = object.string("selectionRole") else {
            throw ProtocolError.invalidCatalogueEntryId
        }
        guard let role = SelectionRole(rawValue: rawRole) else { throw ProtocolError.unknownSelectionRole(rawRole) }
        return try CatalogueEntry(
            entryId: entryId,
            label: label,
            contentId: contentId,
            physicalPage: physicalPage,
            order: order,
            selectionRole: role,
            postId: object.string("postId")
        )
    }

    private static func decodeOwnerCatalogue(_ object: [String: JSONValue]) throws -> OwnerCatalogue {
        guard object.hasOnly(["sourceFingerprint", "verifiedAt", "entries"]),
              let fingerprint = object.string("sourceFingerprint"),
              let verifiedAtText = object.string("verifiedAt"),
              let entries = object.array("entries") else {
            throw ProtocolError.invalidOwnerCatalogueEntries
        }
        guard let verifiedAt = ProtocolTimestamp.parse(verifiedAtText) else {
            throw ProtocolError.invalidTimestamp(field: "verifiedAt")
        }
        return try OwnerCatalogue(
            sourceFingerprint: fingerprint,
            verifiedAt: verifiedAt,
            entries: entries.map { entry in
                guard let row = entry.objectValue,
                      row.hasOnly(["entryId", "label", "postId", "contentId", "physicalPage"]),
                      let entryId = row.string("entryId"), let label = row.string("label"),
                      let postId = row.string("postId"), let contentId = row.string("contentId"),
                      let physicalPage = row.int("physicalPage") else {
                    throw ProtocolError.invalidOwnerCatalogueEntries
                }
                return try OwnerEntry(
                    entryId: entryId,
                    label: label,
                    postId: postId,
                    contentId: contentId,
                    physicalPage: physicalPage
                )
            }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var fields: [String: JSONValue] = [
            "kind": .string("forumThreadNavigation"),
            "identity": .object([
                "sourceId": .string(identity.sourceId),
                "remoteBookId": .string(identity.remoteBookId),
                "threadId": .string(identity.threadId)
            ]),
            "revision": .string(revision),
            "catalogueEntries": .array(catalogueEntries.map { entry in
                var row: [String: JSONValue] = [
                    "entryId": .string(entry.entryId),
                    "label": .string(entry.label),
                    "contentId": .string(entry.contentId),
                    "physicalPage": .int(entry.physicalPage),
                    "order": .int(entry.order),
                    "selectionRole": .string(entry.selectionRole.rawValue)
                ]
                entry.postId.map { row["postId"] = .string($0) }
                return .object(row)
            })
        ]
        if let ownerCatalogue {
            fields["ownerCatalogue"] = .object([
                "sourceFingerprint": .string(ownerCatalogue.sourceFingerprint),
                "verifiedAt": .string(ProtocolTimestamp.format(ownerCatalogue.verifiedAt)),
                "entries": .array(ownerCatalogue.entries.map { entry in
                    .object([
                        "entryId": .string(entry.entryId),
                        "label": .string(entry.label),
                        "postId": .string(entry.postId),
                        "contentId": .string(entry.contentId),
                        "physicalPage": .int(entry.physicalPage)
                    ])
                })
            ])
        }
        var container = encoder.singleValueContainer()
        try container.encode(JSONValue.object(fields))
    }
}
