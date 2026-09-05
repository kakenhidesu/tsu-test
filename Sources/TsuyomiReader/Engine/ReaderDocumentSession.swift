// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public struct ResolvedReaderPosition: Hashable, Sendable {
    public let blockIndex: Int
    public let characterOffset: Int
    public let precision: LocatorPrecision
    public let locator: ReaderLocator
}

/// One structured document and one semantic position shared by every compatible presentation.
/// Switching presentation never re-resolves: scroll, paged, and dual-page read the same locator.
public final class ReaderDocumentSession {
    public let document: ReaderDocument
    public private(set) var presentation: ReaderPresentation
    public private(set) var position: ResolvedReaderPosition

    private let clock: () -> Date

    public init(
        document: ReaderDocument,
        initialLocator: ReaderLocator?,
        initialPresentation: ReaderPresentation,
        clock: @escaping () -> Date = Date.init
    ) throws {
        self.document = document
        self.presentation = initialPresentation
        self.clock = clock
        self.position = try ReaderDocumentSession.resolve(initialLocator, in: document, at: clock())
    }

    @discardableResult
    public func switchPresentation(_ target: ReaderPresentation) -> ResolvedReaderPosition {
        presentation = target
        return position
    }

    /// Immediate semantic navigation; no animation, debounce, or renderer-specific offset.
    @discardableResult
    public func navigateToBlock(_ blockIndex: Int, characterOffset: Int = 0) throws -> ResolvedReaderPosition {
        let bounded = min(max(blockIndex, 0), document.blocks.count - 1)
        let block = document.blocks[bounded]
        let boundedOffset = min(max(characterOffset, 0), ReaderDocumentSession.anchorLength(block))
        position = try ReaderDocumentSession.position(
            at: bounded,
            offset: boundedOffset,
            precision: .exact,
            includeExactAnchor: true,
            in: document,
            at: clock()
        )
        return position
    }

    @discardableResult
    public func navigateByBlock(_ delta: Int) throws -> ResolvedReaderPosition {
        try navigateToBlock(position.blockIndex + delta)
    }

    public func capture(at capturedAt: Date) throws -> ReaderLocator {
        try ReaderLocator(
            document: position.locator.document,
            blockId: position.locator.blockId,
            textAnchorDigest: position.locator.textAnchorDigest,
            characterOffset: position.locator.characterOffset,
            chapterProgress: position.locator.chapterProgress,
            bookProgress: position.locator.bookProgress,
            capturedAt: capturedAt
        )
    }

    /// The resolver order is exact block/anchor/offset, then a nearby matching anchor, then block
    /// progress, then the start of the document (reader-document-v1 §Locator).
    static func resolve(
        _ candidate: ReaderLocator?,
        in document: ReaderDocument,
        at now: Date
    ) throws -> ResolvedReaderPosition {
        guard let candidate, candidate.document.namesSameDocument(as: document.identity) else {
            return try position(at: 0, offset: 0, precision: .degraded, includeExactAnchor: false,
                                in: document, at: now)
        }
        if let blockId = candidate.blockId,
           let blockIndex = document.blocks.firstIndex(where: { $0.blockId == blockId }) {
            let block = document.blocks[blockIndex]
            let digestMatches = candidate.textAnchorDigest == nil
                || candidate.textAnchorDigest == anchorDigest(block)
            let offset = min(max(candidate.characterOffset ?? 0, 0), anchorLength(block))
            if digestMatches, candidate.textAnchorDigest != nil, candidate.characterOffset != nil {
                return try position(at: blockIndex, offset: offset, precision: .exact,
                                    includeExactAnchor: true, in: document, at: now)
            }
            return try position(at: blockIndex, offset: offset, precision: .degraded,
                                includeExactAnchor: false, in: document, at: now)
        }
        if let digest = candidate.textAnchorDigest,
           let anchorIndex = document.blocks.firstIndex(where: { anchorDigest($0) == digest }) {
            return try position(at: anchorIndex, offset: max(candidate.characterOffset ?? 0, 0),
                                precision: .degraded, includeExactAnchor: false, in: document, at: now)
        }
        var fallbackIndex = 0
        if let progress = candidate.chapterProgress, document.blocks.count > 1 {
            fallbackIndex = min(max(Int(progress * Double(document.blocks.count - 1)), 0), document.blocks.count - 1)
        }
        return try position(at: fallbackIndex, offset: 0, precision: .degraded,
                            includeExactAnchor: false, in: document, at: now)
    }

    private static func position(
        at index: Int,
        offset: Int,
        precision: LocatorPrecision,
        includeExactAnchor: Bool,
        in document: ReaderDocument,
        at now: Date
    ) throws -> ResolvedReaderPosition {
        let bounded = min(max(index, 0), document.blocks.count - 1)
        let block = document.blocks[bounded]
        let boundedOffset = min(max(offset, 0), anchorLength(block))
        let progress = document.blocks.count == 1
            ? 0.0
            : Double(bounded) / Double(document.blocks.count - 1)
        let locator = try ReaderLocator(
            document: document.identity,
            blockId: block.blockId,
            textAnchorDigest: includeExactAnchor ? anchorDigest(block) : nil,
            characterOffset: includeExactAnchor ? boundedOffset : nil,
            chapterProgress: progress,
            capturedAt: now
        )
        return ResolvedReaderPosition(
            blockIndex: bounded,
            characterOffset: boundedOffset,
            precision: precision,
            locator: locator
        )
    }

    static func anchorDigest(_ block: ReaderBlock) -> String {
        Sha256.hex(anchorText(block))
    }

    static func anchorLength(_ block: ReaderBlock) -> Int {
        Grammar.codePointCount(anchorText(block))
    }

    static func anchorText(_ block: ReaderBlock) -> String {
        switch block {
        case .paragraph(let value): return value.text
        case .heading(let value): return value.text
        case .quote(let value): return value.text
        case .image(let value): return value.alternateText ?? ""
        case .divider: return ""
        case .post(let value): return value.authorName
        }
    }
}

/// On iOS the reader always starts paged: there is no ink-screen device class to switch on.
public let defaultReaderPresentation: ReaderPresentation = .paged

/// Bounded LRU of neighbouring structured documents; eviction never changes active progress.
public final class ReaderDocumentCache {
    private let capacity: Int
    private var documents: [String: ReaderDocument] = [:]
    private var recency: [String] = []

    public init(capacity: Int = 5) {
        precondition((1...16).contains(capacity), "document cache capacity must be 1...16")
        self.capacity = capacity
    }

    public func put(_ document: ReaderDocument) {
        let key = ReaderDocumentCache.key(document.identity)
        documents[key] = document
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > capacity {
            documents.removeValue(forKey: recency.removeFirst())
        }
    }

    public func get(_ identity: DocumentIdentity) -> ReaderDocument? {
        let key = ReaderDocumentCache.key(identity)
        guard let document = documents[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return document
    }

    public var count: Int { documents.count }

    private static func key(_ identity: DocumentIdentity) -> String {
        "\(identity.sourceId)\u{0}\(identity.remoteBookId)\u{0}\(identity.contentId)"
    }
}
