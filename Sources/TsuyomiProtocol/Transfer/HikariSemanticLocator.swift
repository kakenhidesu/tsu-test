// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Legacy Hikari reading positions. Only the semantic parts survive: a physical page, floor, or
/// paragraph index is translated into a digest anchor, never persisted as a rendered coordinate.
enum HikariSemanticLocator {
    private static let maximumJsonLength = 2_048
    private static let maximumIndex = 1_000_000_000
    private static let chapterFields: Set<String> = [
        "v", "kind", "chapterId", "paragraphIndex", "characterOffset", "chunkProgress", "fallbackProgress"
    ]
    private static let yamiboFields: Set<String> = [
        "v", "kind", "threadId", "physicalPage", "postId", "floorNumber", "blockProgress", "fallbackProgress"
    ]

    static func parse(_ encoded: String) -> TransferProgress? {
        guard encoded.utf16.count <= maximumJsonLength else { return nil }
        guard let parsed = try? JSONValue.decode(Data(encoded.utf8)),
              let locator = parsed.objectValue else { return nil }
        guard strictInt(locator, "v") == 1 else { return nil }
        switch locator.string("kind") {
        case "chapter": return parseChapter(locator)
        case "yamiboReply": return parseYamiboReply(locator)
        default: return nil
        }
    }

    private static func parseChapter(_ locator: [String: JSONValue]) -> TransferProgress? {
        guard locator.hasOnly(chapterFields) else { return nil }
        guard let chapterId = locator.string("chapterId"), isIdentifier(chapterId) else { return nil }
        guard let paragraph = strictInt(locator, "paragraphIndex"), (0...maximumIndex).contains(paragraph) else {
            return nil
        }
        var offset: Int?
        if locator["characterOffset"] != nil {
            guard let value = strictInt(locator, "characterOffset"), (0...maximumIndex).contains(value) else {
                return nil
            }
            offset = value
        }
        var chunkProgress: Double?
        if locator["chunkProgress"] != nil {
            guard let value = strictDouble(locator, "chunkProgress"), (0...1).contains(value) else { return nil }
            chunkProgress = value
        }
        var fallbackProgress: Double?
        if locator["fallbackProgress"] != nil {
            guard let value = strictDouble(locator, "fallbackProgress"), (0...100).contains(value) else { return nil }
            fallbackProgress = value
        }
        return TransferProgress(
            chapterId: chapterId,
            textAnchor: anchor("chapter", chapterId, String(paragraph)),
            characterOffset: offset,
            chapterProgress: chunkProgress,
            bookProgress: fallbackProgress.map { $0 / 100.0 },
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func parseYamiboReply(_ locator: [String: JSONValue]) -> TransferProgress? {
        guard locator.hasOnly(yamiboFields) else { return nil }
        guard let threadId = locator.string("threadId"), isIdentifier(threadId) else { return nil }
        guard let physicalPage = strictInt(locator, "physicalPage"), (1...maximumIndex).contains(physicalPage) else {
            return nil
        }
        var postId: String?
        if locator["postId"] != nil {
            guard let value = locator.string("postId"), isIdentifier(value) else { return nil }
            postId = value
        }
        var floor: Int?
        if locator["floorNumber"] != nil {
            guard let value = strictInt(locator, "floorNumber"), (1...maximumIndex).contains(value) else {
                return nil
            }
            floor = value
        }
        let discriminator: String
        if let postId {
            discriminator = postId
        } else if let floor {
            discriminator = String(floor)
        } else {
            return nil
        }
        var blockProgress: Double?
        if locator["blockProgress"] != nil {
            guard let value = strictDouble(locator, "blockProgress"), (0...1).contains(value) else { return nil }
            blockProgress = value
        }
        var fallbackProgress: Double?
        if locator["fallbackProgress"] != nil {
            guard let value = strictDouble(locator, "fallbackProgress"), (0...100).contains(value) else { return nil }
            fallbackProgress = value
        }
        return TransferProgress(
            chapterId: "yamibo:\(threadId):\(physicalPage)",
            textAnchor: anchor("yamiboReply", threadId, String(physicalPage), discriminator),
            chapterProgress: blockProgress,
            bookProgress: fallbackProgress.map { $0 / 100.0 },
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func anchor(_ segments: String...) -> String {
        TransferCodec.digest(Data(segments.joined(separator: "\u{0}").utf8))
    }

    private static func strictInt(_ object: [String: JSONValue], _ name: String) -> Int? {
        guard let value = object[name], value.stringValue == nil else { return nil }
        return value.intValue
    }

    private static func strictDouble(_ object: [String: JSONValue], _ name: String) -> Double? {
        guard let value = object[name], value.stringValue == nil else { return nil }
        return value.doubleValue
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.utf16.count <= 256
            && value.contains { !$0.isWhitespace }
            && !value.contains("://")
            && !value.utf16.contains { $0 < 0x20 || $0 == 0x7F }
    }
}
