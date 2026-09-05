// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ReaderDocumentKind: String, Sendable, Codable, CaseIterable {
    case chapter
    case threadPage
}

/// The source-to-reader data boundary defined by reader-document-v1. It never carries raw HTML, a
/// network response, cookies, parser callbacks, or a rendered page number.
public struct ReaderDocument: Hashable, Sendable, Codable {
    public let kind: ReaderDocumentKind
    public let identity: DocumentIdentity
    public let title: String
    public let revision: String
    public let contentDigest: String
    public let blocks: [ReaderBlock]

    public init(
        kind: ReaderDocumentKind,
        identity: DocumentIdentity,
        title: String,
        revision: String,
        contentDigest: String,
        blocks: [ReaderBlock]
    ) throws {
        guard Grammar.hasCodePoints(title, in: 1...4_096) else { throw ProtocolError.invalidDocumentTitle }
        guard Grammar.hasCodePoints(revision, in: 1...256) else { throw ProtocolError.invalidDocumentRevision }
        guard Grammar.isSha256(contentDigest) else { throw ProtocolError.invalidContentDigest }
        guard (1...50_000).contains(blocks.count) else { throw ProtocolError.invalidDocumentBlocks }
        guard blocks.map(\.blockId).hasDistinctElements else { throw ProtocolError.duplicateBlockIdentity }
        self.kind = kind
        self.identity = identity
        self.title = title
        self.revision = revision
        self.contentDigest = contentDigest
        self.blocks = blocks
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(JSONValue.self)
        guard let object = value.objectValue else { throw ProtocolError.unexpectedJsonType(field: "document") }
        guard object.hasOnly(["kind", "identity", "title", "revision", "contentDigest", "blocks"]) else {
            throw ProtocolError.unknownField("document")
        }
        guard let rawKind = object.string("kind") else { throw ProtocolError.missingField("kind") }
        guard let kind = ReaderDocumentKind(rawValue: rawKind) else {
            throw ProtocolError.unknownDocumentKind(rawKind)
        }
        guard let identityObject = object.object("identity") else { throw ProtocolError.missingField("identity") }
        guard identityObject.hasOnly(["sourceId", "remoteBookId", "contentId"]) else {
            throw ProtocolError.unknownField("identity")
        }
        guard let sourceId = identityObject.string("sourceId"),
              let remoteBookId = identityObject.string("remoteBookId"),
              let contentId = identityObject.string("contentId") else {
            throw ProtocolError.missingField("identity")
        }
        guard let title = object.string("title") else { throw ProtocolError.missingField("title") }
        guard let revision = object.string("revision") else { throw ProtocolError.missingField("revision") }
        guard let contentDigest = object.string("contentDigest") else {
            throw ProtocolError.missingField("contentDigest")
        }
        guard let blocks = object.array("blocks") else { throw ProtocolError.missingField("blocks") }
        try self.init(
            kind: kind,
            identity: DocumentIdentity(sourceId: sourceId, remoteBookId: remoteBookId, contentId: contentId),
            title: title,
            revision: revision,
            contentDigest: contentDigest,
            blocks: blocks.map { try ReaderBlock(json: $0) }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(JSONValue.object([
            "kind": .string(kind.rawValue),
            "identity": .object([
                "sourceId": .string(identity.sourceId),
                "remoteBookId": .string(identity.remoteBookId),
                "contentId": .string(identity.contentId)
            ]),
            "title": .string(title),
            "revision": .string(revision),
            "contentDigest": .string(contentDigest),
            "blocks": .array(blocks.map(\.json))
        ]))
    }
}
