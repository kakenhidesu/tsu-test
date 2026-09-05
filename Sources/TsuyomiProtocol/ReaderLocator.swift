// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Identity of one resolved reading unit. `revision` is optional in the wire protocol, because an
/// old durable locator may predate revision support.
public struct DocumentIdentity: Hashable, Sendable, Codable {
    public let sourceId: String
    public let remoteBookId: String
    public let contentId: String
    public let revision: String?
    public let book: BookIdentity

    public init(sourceId: String, remoteBookId: String, contentId: String, revision: String? = nil) throws {
        self.book = try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId)
        try BookIdentity.requireRemoteId(contentId, field: "contentId")
        if let revision, !Grammar.hasCodePoints(revision, in: 1...256) {
            throw ProtocolError.boundedText(field: "revision")
        }
        self.sourceId = sourceId
        self.remoteBookId = remoteBookId
        self.contentId = contentId
        self.revision = revision
    }

    /// True only when both values name the same resolved content, irrespective of revision.
    public func namesSameDocument(as other: DocumentIdentity) -> Bool {
        sourceId == other.sourceId && remoteBookId == other.remoteBookId && contentId == other.contentId
    }

    /// True only when content identity and known revision are identical.
    public func namesSameRevision(as other: DocumentIdentity) -> Bool {
        namesSameDocument(as: other) && revision == other.revision
    }

    private enum CodingKeys: String, CodingKey {
        case sourceId, remoteBookId, contentId, revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceId: container.decode(String.self, forKey: .sourceId),
            remoteBookId: container.decode(String.self, forKey: .remoteBookId),
            contentId: container.decode(String.self, forKey: .contentId),
            revision: container.decodeIfPresent(String.self, forKey: .revision)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceId, forKey: .sourceId)
        try container.encode(remoteBookId, forKey: .remoteBookId)
        try container.encode(contentId, forKey: .contentId)
        try container.encodeIfPresent(revision, forKey: .revision)
    }
}

/// The restoration quality represented by a semantic locator.
public enum LocatorPrecision: String, Sendable, Codable {
    /// Stable block, anchor digest, and Unicode code-point offset are all known.
    case exact
    /// A semantic locator exists, but at least one exact-anchor component is absent.
    case degraded
    /// No semantic locator could be recovered.
    case unavailable
}

/// Durable semantic reader position defined by reader-locator-v1.
///
/// It intentionally has no renderer-specific page, spread, pixel, or scroll fields.
public struct ReaderLocator: Hashable, Sendable, Codable {
    public let document: DocumentIdentity
    public let blockId: String?
    public let textAnchorDigest: String?
    public let characterOffset: Int?
    public let chapterProgress: Double?
    public let bookProgress: Double?
    public let capturedAt: Date

    public init(
        document: DocumentIdentity,
        blockId: String? = nil,
        textAnchorDigest: String? = nil,
        characterOffset: Int? = nil,
        chapterProgress: Double? = nil,
        bookProgress: Double? = nil,
        capturedAt: Date
    ) throws {
        if let blockId, !Grammar.hasCodePoints(blockId, in: 1...1024) {
            throw ProtocolError.boundedText(field: "blockId")
        }
        if let textAnchorDigest, !Grammar.isSha256(textAnchorDigest) {
            throw ProtocolError.textAnchorDigest
        }
        if let characterOffset {
            guard characterOffset >= 0 else { throw ProtocolError.negativeCharacterOffset }
            guard blockId != nil else { throw ProtocolError.characterOffsetRequiresBlockId }
        }
        if textAnchorDigest != nil, blockId == nil {
            throw ProtocolError.textAnchorDigestRequiresBlockId
        }
        if let chapterProgress, !Grammar.isBoundedProgress(chapterProgress) {
            throw ProtocolError.progressRange(field: "chapterProgress")
        }
        if let bookProgress, !Grammar.isBoundedProgress(bookProgress) {
            throw ProtocolError.progressRange(field: "bookProgress")
        }
        let anchored = (blockId != nil && characterOffset != nil) || (blockId != nil && textAnchorDigest != nil)
        guard anchored || chapterProgress != nil || bookProgress != nil else {
            throw ProtocolError.locatorAnchorMissing
        }
        self.document = document
        self.blockId = blockId
        self.textAnchorDigest = textAnchorDigest
        self.characterOffset = characterOffset
        self.chapterProgress = chapterProgress
        self.bookProgress = bookProgress
        self.capturedAt = capturedAt
    }

    /// Protocol-compatible precision based only on the available semantic evidence.
    public var precision: LocatorPrecision {
        blockId != nil && textAnchorDigest != nil && characterOffset != nil ? .exact : .degraded
    }

    private enum CodingKeys: String, CodingKey {
        case document, blockId, textAnchorDigest, characterOffset, chapterProgress, bookProgress, capturedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capturedAtText = try container.decode(String.self, forKey: .capturedAt)
        guard let capturedAt = ProtocolTimestamp.parse(capturedAtText) else {
            throw ProtocolError.invalidTimestamp(field: "capturedAt")
        }
        try self.init(
            document: container.decode(DocumentIdentity.self, forKey: .document),
            blockId: container.decodeIfPresent(String.self, forKey: .blockId),
            textAnchorDigest: container.decodeIfPresent(String.self, forKey: .textAnchorDigest),
            characterOffset: container.decodeIfPresent(Int.self, forKey: .characterOffset),
            chapterProgress: container.decodeIfPresent(Double.self, forKey: .chapterProgress),
            bookProgress: container.decodeIfPresent(Double.self, forKey: .bookProgress),
            capturedAt: capturedAt
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(document, forKey: .document)
        try container.encodeIfPresent(blockId, forKey: .blockId)
        try container.encodeIfPresent(textAnchorDigest, forKey: .textAnchorDigest)
        try container.encodeIfPresent(characterOffset, forKey: .characterOffset)
        try container.encodeIfPresent(chapterProgress, forKey: .chapterProgress)
        try container.encodeIfPresent(bookProgress, forKey: .bookProgress)
        try container.encode(ProtocolTimestamp.format(capturedAt), forKey: .capturedAt)
    }
}
