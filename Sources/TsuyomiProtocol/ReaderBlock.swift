// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One ordered, presentation-neutral unit of a reader document (reader-document-v1 §Blocks).
/// Block IDs are source-owned stable identifiers and are the primary reader anchor.
public enum ReaderBlock: Hashable, Sendable, Codable {
    case heading(Heading)
    case paragraph(Paragraph)
    case image(Image)
    case divider(Divider)
    case quote(Quote)
    case post(Post)

    public var blockId: String {
        switch self {
        case .heading(let block): return block.blockId
        case .paragraph(let block): return block.blockId
        case .image(let block): return block.blockId
        case .divider(let block): return block.blockId
        case .quote(let block): return block.blockId
        case .post(let block): return block.blockId
        }
    }

    public struct Heading: Hashable, Sendable {
        public let blockId: String
        public let text: String
        public let level: Int

        public init(blockId: String, text: String, level: Int) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            guard text.contains(where: { !$0.isWhitespace }), Grammar.hasCodePoints(text, in: 1...16_384),
                  (1...6).contains(level) else { throw ProtocolError.invalidHeading }
            self.blockId = blockId
            self.text = text
            self.level = level
        }
    }

    public struct Paragraph: Hashable, Sendable {
        public let blockId: String
        public let text: String

        public init(blockId: String, text: String) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            guard text.contains(where: { !$0.isWhitespace }), Grammar.hasCodePoints(text, in: 1...65_536) else {
                throw ProtocolError.invalidParagraph
            }
            self.blockId = blockId
            self.text = text
        }
    }

    public struct Image: Hashable, Sendable {
        public let blockId: String
        public let url: String
        public let alternateText: String?
        public let aspectRatio: Double?

        public init(blockId: String, url: String, alternateText: String?, aspectRatio: Double?) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            guard Grammar.isHttpsUrl(url) else { throw ProtocolError.invalidImageUrl }
            if let alternateText, Grammar.codePointCount(alternateText) > 4_096 {
                throw ProtocolError.invalidImageAlternateText
            }
            if let aspectRatio, !(aspectRatio.isFinite && aspectRatio > 0 && aspectRatio <= 100) {
                throw ProtocolError.invalidImageDimension
            }
            self.blockId = blockId
            self.url = url
            self.alternateText = alternateText
            self.aspectRatio = aspectRatio
        }
    }

    public struct Divider: Hashable, Sendable {
        public let blockId: String

        public init(blockId: String) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            self.blockId = blockId
        }
    }

    public struct Quote: Hashable, Sendable {
        public let blockId: String
        public let text: String
        public let attribution: String?

        public init(blockId: String, text: String, attribution: String?) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            guard Grammar.hasCodePoints(text, in: 1...65_536) else { throw ProtocolError.invalidQuoteText }
            if let attribution, Grammar.codePointCount(attribution) > 4_096 {
                throw ProtocolError.invalidQuoteAttribution
            }
            self.blockId = blockId
            self.text = text
            self.attribution = attribution
        }
    }

    /// A forum block. `postId` stays the primary reader anchor even when the source renumbers
    /// floors or repaginates the thread (reader-document-v1 §Blocks).
    public struct Post: Hashable, Sendable {
        public let blockId: String
        public let postId: String
        public let authorId: String
        public let authorName: String
        public let floor: Int?
        public let createdAt: Date?
        public let replyToPostId: String?
        public let blocks: [ReaderBlock]

        public init(
            blockId: String,
            postId: String,
            authorId: String,
            authorName: String,
            floor: Int?,
            createdAt: Date?,
            replyToPostId: String?,
            blocks: [ReaderBlock]
        ) throws {
            try ReaderBlock.requireValidBlockId(blockId)
            try BookIdentity.requireRemoteId(postId, field: "postId")
            try BookIdentity.requireRemoteId(authorId, field: "authorId")
            guard Grammar.hasCodePoints(authorName, in: 1...1_024) else {
                throw ProtocolError.boundedText(field: "authorName")
            }
            if let floor, floor < 1 { throw ProtocolError.invalidPostFloor }
            if let replyToPostId { try BookIdentity.requireRemoteId(replyToPostId, field: "replyToPostId") }
            guard (1...5_000).contains(blocks.count) else { throw ProtocolError.invalidPostBlocks }
            guard blocks.allSatisfy({ block -> Bool in
                if case .post = block { return false }
                return true
            }) else {
                throw ProtocolError.invalidPostBlocks
            }
            guard blocks.map(\.blockId).hasDistinctElements else { throw ProtocolError.duplicatePostBlockIdentity }
            self.blockId = blockId
            self.postId = postId
            self.authorId = authorId
            self.authorName = authorName
            self.floor = floor
            self.createdAt = createdAt
            self.replyToPostId = replyToPostId
            self.blocks = blocks
        }
    }

    static func requireValidBlockId(_ blockId: String) throws {
        guard Grammar.hasCodePoints(blockId, in: 1...1_024) else { throw ProtocolError.invalidBlockId }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(json: decoder.singleValueContainer().decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }

    init(json value: JSONValue) throws {
        guard let object = value.objectValue else { throw ProtocolError.unexpectedJsonType(field: "block") }
        guard let kind = object.string("kind") else { throw ProtocolError.missingField("kind") }
        guard let id = object.string("id") else { throw ProtocolError.missingField("id") }
        switch kind {
        case "heading":
            guard object.hasOnly(["id", "kind", "level", "text"]) else { throw ProtocolError.invalidHeading }
            guard let text = object.string("text"), let level = object.int("level") else {
                throw ProtocolError.invalidHeading
            }
            self = .heading(try Heading(blockId: id, text: text, level: level))
        case "paragraph":
            guard object.hasOnly(["id", "kind", "text"]), let text = object.string("text") else {
                throw ProtocolError.invalidParagraph
            }
            self = .paragraph(try Paragraph(blockId: id, text: text))
        case "image":
            guard object.hasOnly(["id", "kind", "url", "alt", "aspectRatio"]), let url = object.string("url") else {
                throw ProtocolError.invalidImageUrl
            }
            self = .image(try Image(
                blockId: id,
                url: url,
                alternateText: object.string("alt"),
                aspectRatio: object.double("aspectRatio")
            ))
        case "divider":
            guard object.hasOnly(["id", "kind"]) else { throw ProtocolError.invalidBlockId }
            self = .divider(try Divider(blockId: id))
        case "quote":
            guard object.hasOnly(["id", "kind", "text", "attribution"]), let text = object.string("text") else {
                throw ProtocolError.invalidQuoteText
            }
            self = .quote(try Quote(blockId: id, text: text, attribution: object.string("attribution")))
        case "post":
            guard object.hasOnly(["id", "kind", "postId", "authorId", "authorName", "floor", "createdAt",
                                  "replyToPostId", "blocks"]) else { throw ProtocolError.invalidPostBlocks }
            guard let postId = object.string("postId"), let authorId = object.string("authorId"),
                  let authorName = object.string("authorName"), let blocks = object.array("blocks") else {
                throw ProtocolError.invalidPostBlocks
            }
            var createdAt: Date?
            if let raw = object.string("createdAt") {
                guard let parsed = ProtocolTimestamp.parse(raw) else {
                    throw ProtocolError.invalidTimestamp(field: "createdAt")
                }
                createdAt = parsed
            }
            self = .post(try Post(
                blockId: id,
                postId: postId,
                authorId: authorId,
                authorName: authorName,
                floor: object.int("floor"),
                createdAt: createdAt,
                replyToPostId: object.string("replyToPostId"),
                blocks: try blocks.map { try ReaderBlock(json: $0) }
            ))
        default:
            throw ProtocolError.unknownBlockKind(kind)
        }
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(blockId)]
        switch self {
        case .heading(let block):
            fields["kind"] = .string("heading")
            fields["text"] = .string(block.text)
            fields["level"] = .int(block.level)
        case .paragraph(let block):
            fields["kind"] = .string("paragraph")
            fields["text"] = .string(block.text)
        case .image(let block):
            fields["kind"] = .string("image")
            fields["url"] = .string(block.url)
            block.alternateText.map { fields["alt"] = .string($0) }
            block.aspectRatio.map { fields["aspectRatio"] = .double($0) }
        case .divider:
            fields["kind"] = .string("divider")
        case .quote(let block):
            fields["kind"] = .string("quote")
            fields["text"] = .string(block.text)
            block.attribution.map { fields["attribution"] = .string($0) }
        case .post(let block):
            fields["kind"] = .string("post")
            fields["postId"] = .string(block.postId)
            fields["authorId"] = .string(block.authorId)
            fields["authorName"] = .string(block.authorName)
            block.floor.map { fields["floor"] = .int($0) }
            block.createdAt.map { fields["createdAt"] = .string(ProtocolTimestamp.format($0)) }
            block.replyToPostId.map { fields["replyToPostId"] = .string($0) }
            fields["blocks"] = .array(block.blocks.map(\.json))
        }
        return .object(fields)
    }
}
