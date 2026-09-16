// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// `tsuyomi-transfer` v1, v2 and v3 (transfer-v1.md, transfer-v2.md). Each version is read with its
/// own closed field set: a later field never widens an earlier document, and exports always emit the
/// current version.
public enum TransferCodec {
    public static let currentVersion = 3
    static let maximumCompletedChapters = 20_000

    public static func parse(_ bytes: Data) -> ImportParseResult {
        if bytes.count > maximumTransferBytes { return .fatal(safeCode: "transfer-too-large") }
        guard String(data: bytes, encoding: .utf8) != nil else { return .fatal(safeCode: "invalid-utf8") }
        guard let parsed = try? JSONValue.decode(bytes), let root = parsed.objectValue else {
            return .fatal(safeCode: "invalid-json")
        }
        switch root.string("format") {
        case "tsuyomi-transfer": return parseTransfer(root)
        case "hikari_novel_backup": return HikariBackupCodec.parse(root)
        default: return .fatal(safeCode: "unsupported-format")
        }
    }

    public static func encode(_ snapshot: TransferSnapshot) throws -> Data {
        let orderedBooks = snapshot.library.sorted { $0.identity < $1.identity }
        guard orderedBooks.map(\.identity).hasDistinctElements else { throw ProtocolError.duplicateBookIdentity }
        let orderedShelves = try canonicalShelves(snapshot.shelves)
        var root: [String: JSONValue] = [
            "format": .string("tsuyomi-transfer"),
            "version": .int(currentVersion),
            "createdAt": .string(ProtocolTimestamp.format(snapshot.createdAt)),
            "library": .array(orderedBooks.map(bookJson)),
            "shelves": .array(orderedShelves.map(shelfJson))
        ]
        if let preferences = snapshot.readerPreferences {
            root["preferences"] = .object(["reader": readerPreferencesJson(preferences)])
        }
        return try JSONValue.object(root).encoded()
    }

    public static func encodeBounded(
        _ snapshot: TransferSnapshot,
        maximumBytes: Int = maximumTransferBytes
    ) throws -> Data? {
        let encoded = try encode(snapshot)
        return encoded.count <= maximumBytes ? encoded : nil
    }

    public static func digest(_ bytes: Data) -> String { Sha256.hex(bytes) }

    /// transfer-v1 §Progress conflicts: the newer capture wins, an equal capture keeps the host
    /// record, and an invalid incoming record (`nil`) never replaces valid stored progress.
    public static func resolveProgressConflict(
        stored: TransferProgress?,
        incoming: TransferProgress?
    ) -> TransferProgress? {
        guard let incoming else { return stored }
        guard let stored else { return incoming }
        return incoming.updatedAt > stored.updatedAt ? incoming : stored
    }

    private static func parseTransfer(_ root: [String: JSONValue]) -> ImportParseResult {
        guard let version = root.int("version"), (1...currentVersion).contains(version) else {
            return .fatal(safeCode: "unsupported-version")
        }
        guard root.hasOnly(["format", "version", "createdAt", "library", "shelves", "preferences"]) else {
            return .fatal(safeCode: "unknown-root-field")
        }
        guard let createdAt = root.instant("createdAt") else { return .fatal(safeCode: "invalid-created-at") }
        guard let library = root.array("library") else { return .fatal(safeCode: "invalid-library") }
        guard let shelvesJson = root.array("shelves") else { return .fatal(safeCode: "invalid-shelves") }
        if library.count > 100_000 || shelvesJson.count > 5_000 { return .fatal(safeCode: "record-limit") }

        var books: [TransferBook] = []
        var seenBooks = Set<BookIdentity>()
        for item in library {
            guard let object = item.objectValue, let book = try? parseBook(object, version: version) else {
                return .fatal(safeCode: "invalid-book")
            }
            guard seenBooks.insert(book.identity).inserted else {
                return .fatal(safeCode: "duplicate-book-identity")
            }
            guard book.localPin || book.shelfIds.isEmpty else {
                return .fatal(safeCode: "unpinned-shelf-membership")
            }
            books.append(book)
        }

        var shelves: [TransferShelf] = []
        var seenShelves = Set<String>()
        for item in shelvesJson {
            guard let object = item.objectValue, let shelf = try? parseShelf(object) else {
                return .fatal(safeCode: "invalid-shelf")
            }
            guard seenShelves.insert(shelf.id).inserted else { return .fatal(safeCode: "duplicate-shelf-id") }
            shelves.append(shelf)
        }

        let shelfIds = Set(shelves.map(\.id))
        let danglingParent = shelves.contains { $0.parentId.map { !shelfIds.contains($0) } == true }
        let danglingMembership = books.contains { book in book.shelfIds.contains { !shelfIds.contains($0) } }
        if danglingParent || danglingMembership { return .fatal(safeCode: "dangling-shelf-reference") }
        if hasShelfParentCycle(shelves) { return .fatal(safeCode: "shelf-parent-cycle") }

        var preferences: PortableReaderPreferences?
        if let raw = root["preferences"] {
            guard let preferencesObject = raw.objectValue, preferencesObject.hasOnly(["reader"]) else {
                return .fatal(safeCode: "invalid-reader-preferences")
            }
            if let readerRaw = preferencesObject["reader"] {
                guard let readerObject = readerRaw.objectValue,
                      let parsed = try? parseReaderPreferences(readerObject, version: version) else {
                    return .fatal(safeCode: "invalid-reader-preferences")
                }
                preferences = parsed
            }
        }

        let snapshot = TransferSnapshot(
            createdAt: createdAt,
            library: books,
            shelves: shelves,
            readerPreferences: preferences
        )
        guard let canonical = try? encode(snapshot) else { return .fatal(safeCode: "invalid-transfer") }
        return .ready(
            plan: ImportPlan(
                kind: .tsuyomiTransfer,
                sourceCreatedAt: createdAt,
                books: books,
                shelves: shelves,
                readerPreferences: preferences
            ),
            canonicalDigest: digest(canonical)
        )
    }

    private static func parseBook(_ value: [String: JSONValue], version: Int) throws -> TransferBook {
        guard value.hasOnly(bookFields(version)) else { throw ProtocolError.unknownField("book") }
        guard let identityObject = value.object("identity"),
              Set(identityObject.keys) == ["sourceId", "remoteBookId"],
              let sourceId = identityObject.string("sourceId"),
              let remoteBookId = identityObject.string("remoteBookId") else {
            throw ProtocolError.missingField("identity")
        }
        let identity = try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId)
        guard let title = value.string("title"), (1...4_096).contains(title.utf16.count) else {
            throw ProtocolError.invalidBookTitle
        }
        guard let updatedAt = value.instant("updatedAt") else {
            throw ProtocolError.invalidTimestamp(field: "updatedAt")
        }
        let status = value.string("status") ?? "unknown"
        guard TransferBook.statuses.contains(status) else { throw ProtocolError.unknownField("status") }
        let rating = value.double("rating")
        if let rating, !(rating >= 0 && rating <= 5) { throw ProtocolError.unknownField("rating") }
        let localPin: Bool
        if version >= 3 {
            guard let pin = value.bool("localPin") else { throw ProtocolError.missingField("localPin") }
            localPin = pin
        } else {
            localPin = true
        }
        return TransferBook(
            identity: identity,
            title: title,
            authors: try stringSet(value, "authors", maximumItems: 32, maximumCodePoints: 1_024),
            canonicalUrl: try absoluteUrl(value.string("canonicalUrl")),
            coverUrl: try absoluteUrl(value.string("coverUrl")),
            status: status,
            remoteTags: try stringSet(value, "remoteTags", maximumItems: 128, maximumCodePoints: 256),
            localTags: try stringSet(value, "localTags", maximumItems: 64, maximumCodePoints: 64),
            shelfIds: try stringSet(value, "shelfIds", maximumItems: 512, maximumCodePoints: 128),
            rating: rating,
            readLater: value.bool("readLater") ?? false,
            localPin: localPin,
            addedAt: value.instant("addedAt"),
            updatedAt: updatedAt,
            progress: try value.object("progress").map(parseProgress),
            completedChapterIds: try completedChapterIds(value)
        )
    }

    /// An explicit, bounded list of chapter ids: nothing is inferred from ordering or progress, and
    /// a blank, numeric, duplicated or object element invalidates the record.
    private static func completedChapterIds(_ value: [String: JSONValue]) throws -> Set<String> {
        guard let raw = value["completedChapterIds"] else { return [] }
        guard let items = raw.arrayValue, items.count <= maximumCompletedChapters else {
            throw ProtocolError.unknownField("completedChapterIds")
        }
        var ids: [String] = []
        for item in items {
            guard let id = item.stringValue, Grammar.hasCodePoints(id, in: 1...512),
                  id.contains(where: { !$0.isWhitespace }) else {
                throw ProtocolError.unknownField("completedChapterIds")
            }
            ids.append(id)
        }
        guard ids.hasDistinctElements else { throw ProtocolError.unknownField("completedChapterIds") }
        return Set(ids)
    }

    private static func parseProgress(_ value: [String: JSONValue]) throws -> TransferProgress {
        guard value.hasOnly(progressFields) else { throw ProtocolError.unknownField("progress") }
        let chapterId = value.string("chapterId")
        let textAnchor = value.string("textAnchor")
        let offset = value.int("characterOffset")
        let chapterProgress = value.double("chapterProgress")
        let bookProgress = value.double("bookProgress")
        guard textAnchor != nil || offset != nil || chapterProgress != nil || bookProgress != nil else {
            throw ProtocolError.locatorAnchorMissing
        }
        if let chapterId, !(1...1_024).contains(chapterId.utf16.count) { throw ProtocolError.invalidChapterId }
        if let textAnchor, !Grammar.isSha256(textAnchor) { throw ProtocolError.textAnchorDigest }
        if let offset, offset < 0 { throw ProtocolError.negativeCharacterOffset }
        if let chapterProgress, !Grammar.isBoundedProgress(chapterProgress) {
            throw ProtocolError.progressRange(field: "chapterProgress")
        }
        if let bookProgress, !Grammar.isBoundedProgress(bookProgress) {
            throw ProtocolError.progressRange(field: "bookProgress")
        }
        guard let updatedAt = value.instant("updatedAt") else {
            throw ProtocolError.invalidTimestamp(field: "updatedAt")
        }
        return TransferProgress(
            chapterId: chapterId,
            textAnchor: textAnchor,
            characterOffset: offset,
            chapterProgress: chapterProgress,
            bookProgress: bookProgress,
            updatedAt: updatedAt
        )
    }

    private static func parseShelf(_ value: [String: JSONValue]) throws -> TransferShelf {
        guard value.hasOnly(["id", "name", "parentId", "position"]) else { throw ProtocolError.unknownField("shelf") }
        guard let id = value.string("id"), (1...128).contains(id.utf16.count) else {
            throw ProtocolError.missingField("id")
        }
        guard let name = value.string("name"), (1...256).contains(name.utf16.count) else {
            throw ProtocolError.missingField("name")
        }
        let parent = value.string("parentId")
        if let parent, !(1...128).contains(parent.utf16.count) { throw ProtocolError.unknownField("parentId") }
        let position = value.int("position") ?? 0
        guard position >= 0 else { throw ProtocolError.unknownField("position") }
        return TransferShelf(id: id, name: name, parentId: parent, position: position)
    }

    private static func parseReaderPreferences(
        _ value: [String: JSONValue],
        version: Int
    ) throws -> PortableReaderPreferences {
        guard value.hasOnly(readerFields(version)) else { throw ProtocolError.unknownField("reader") }
        func text(_ name: String, allowed: Set<String>) throws -> String? {
            guard let element = value[name] else { return nil }
            guard let content = element.stringValue, allowed.contains(content) else {
                throw ProtocolError.unknownField(name)
            }
            return content
        }
        func number(_ name: String, range: ClosedRange<Double>) throws -> Double? {
            guard let element = value[name] else { return nil }
            guard element.stringValue == nil, let content = element.doubleValue, range.contains(content) else {
                throw ProtocolError.unknownField(name)
            }
            return content
        }
        func flag(_ name: String) throws -> Bool? {
            guard let element = value[name] else { return nil }
            guard let content = element.boolValue else { throw ProtocolError.unknownField(name) }
            return content
        }
        return PortableReaderPreferences(
            flow: try text("flow", allowed: PortableReaderPreferences.flows),
            fontScale: try number("fontScale", range: 0.5...3.0),
            lineHeight: try number("lineHeight", range: 0.8...3.0),
            theme: try text("theme", allowed: PortableReaderPreferences.themes),
            horizontalMargin: try number("horizontalMargin", range: PortableReaderPreferences.horizontalMarginRange),
            paragraphSpacing: try number("paragraphSpacing", range: PortableReaderPreferences.paragraphSpacingRange),
            lockPortrait: try flag("lockPortrait"),
            progressVisible: try flag("progressVisible"),
            immersive: try flag("immersive"),
            keepAwake: try flag("keepAwake"),
            volumePaging: try flag("volumePaging")
        )
    }

    static func bookJson(_ book: TransferBook) -> JSONValue {
        var fields: [String: JSONValue] = [
            "identity": .object([
                "sourceId": .string(book.identity.sourceId),
                "remoteBookId": .string(book.identity.remoteBookId)
            ]),
            "title": .string(book.title),
            "updatedAt": .string(ProtocolTimestamp.format(book.updatedAt))
        ]
        putStringSet(&fields, "authors", book.authors)
        book.canonicalUrl.map { fields["canonicalUrl"] = .string($0) }
        book.coverUrl.map { fields["coverUrl"] = .string($0) }
        if book.status != "unknown" { fields["status"] = .string(book.status) }
        putStringSet(&fields, "remoteTags", book.remoteTags)
        putStringSet(&fields, "localTags", book.localTags)
        putStringSet(&fields, "shelfIds", book.shelfIds)
        book.rating.map { fields["rating"] = .double($0) }
        if book.readLater { fields["readLater"] = .bool(true) }
        fields["localPin"] = .bool(book.localPin)
        book.addedAt.map { fields["addedAt"] = .string(ProtocolTimestamp.format($0)) }
        book.progress.map { fields["progress"] = progressJson($0) }
        fields["completedChapterIds"] = .array(CanonicalOrder.sorted(book.completedChapterIds).map { .string($0) })
        return .object(fields)
    }

    private static func progressJson(_ progress: TransferProgress) -> JSONValue {
        var fields: [String: JSONValue] = ["updatedAt": .string(ProtocolTimestamp.format(progress.updatedAt))]
        progress.chapterId.map { fields["chapterId"] = .string($0) }
        progress.textAnchor.map { fields["textAnchor"] = .string($0) }
        progress.characterOffset.map { fields["characterOffset"] = .int($0) }
        progress.chapterProgress.map { fields["chapterProgress"] = .double($0) }
        progress.bookProgress.map { fields["bookProgress"] = .double($0) }
        return .object(fields)
    }

    static func shelfJson(_ shelf: TransferShelf) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(shelf.id),
            "name": .string(shelf.name),
            "position": .int(shelf.position)
        ]
        shelf.parentId.map { fields["parentId"] = .string($0) }
        return .object(fields)
    }

    static func readerPreferencesJson(_ preferences: PortableReaderPreferences) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        preferences.flow.map { fields["flow"] = .string($0) }
        preferences.fontScale.map { fields["fontScale"] = .double($0) }
        preferences.lineHeight.map { fields["lineHeight"] = .double($0) }
        preferences.theme.map { fields["theme"] = .string($0) }
        preferences.horizontalMargin.map { fields["horizontalMargin"] = .double($0) }
        preferences.paragraphSpacing.map { fields["paragraphSpacing"] = .double($0) }
        preferences.lockPortrait.map { fields["lockPortrait"] = .bool($0) }
        preferences.progressVisible.map { fields["progressVisible"] = .bool($0) }
        preferences.immersive.map { fields["immersive"] = .bool($0) }
        preferences.keepAwake.map { fields["keepAwake"] = .bool($0) }
        preferences.volumePaging.map { fields["volumePaging"] = .bool($0) }
        return .object(fields)
    }

    private static func canonicalShelves(_ shelves: [TransferShelf]) throws -> [TransferShelf] {
        guard shelves.map(\.id).hasDistinctElements else { throw ProtocolError.duplicateShelfIdentity }
        guard !hasShelfParentCycle(shelves) else { throw ProtocolError.shelfParentCycle }
        return shelves.sorted { lhs, rhs in
            let byParent = CanonicalOrder.compare(lhs.parentId ?? "", rhs.parentId ?? "")
            if byParent != 0 { return byParent < 0 }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return CanonicalOrder.precedes(lhs.id, rhs.id)
        }
    }

    private static func stringSet(
        _ value: [String: JSONValue],
        _ name: String,
        maximumItems: Int,
        maximumCodePoints: Int
    ) throws -> Set<String> {
        guard let values = value.array(name) else { return [] }
        guard values.count <= maximumItems else { throw ProtocolError.unknownField(name) }
        var strings: [String] = []
        for element in values {
            guard let text = element.stringValue,
                  Grammar.hasCodePoints(text, in: 1...maximumCodePoints) else {
                throw ProtocolError.unknownField(name)
            }
            strings.append(text)
        }
        guard strings.hasDistinctElements else { throw ProtocolError.unknownField(name) }
        return Set(strings)
    }

    private static func putStringSet(_ fields: inout [String: JSONValue], _ name: String, _ values: Set<String>) {
        guard !values.isEmpty else { return }
        fields[name] = .array(CanonicalOrder.sorted(values).map { .string($0) })
    }

    private static func absoluteUrl(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let scheme = URLComponents(string: value)?.scheme, !scheme.isEmpty else {
            throw ProtocolError.invalidCanonicalUrl
        }
        return value
    }

    private static func bookFields(_ version: Int) -> Set<String> {
        var fields: Set<String> = [
            "identity", "title", "authors", "canonicalUrl", "coverUrl", "status", "remoteTags", "localTags",
            "shelfIds", "rating", "readLater", "addedAt", "updatedAt", "progress"
        ]
        if version >= 2 { fields.insert("completedChapterIds") }
        if version >= 3 { fields.insert("localPin") }
        return fields
    }

    private static func readerFields(_ version: Int) -> Set<String> {
        var fields: Set<String> = ["flow", "fontScale", "lineHeight", "theme"]
        if version >= 2 {
            fields.formUnion([
                "horizontalMargin", "paragraphSpacing", "lockPortrait", "progressVisible", "immersive",
                "keepAwake", "volumePaging"
            ])
        }
        return fields
    }
    private static let progressFields: Set<String> = [
        "chapterId", "textAnchor", "characterOffset", "chapterProgress", "bookProgress", "updatedAt"
    ]
}

func hasShelfParentCycle(_ shelves: [TransferShelf]) -> Bool {
    var parents: [String: String?] = [:]
    for shelf in shelves { parents[shelf.id] = shelf.parentId }
    return shelves.contains { shelf in
        var visited = Set<String>()
        var cursor: String? = shelf.id
        while let current = cursor, visited.insert(current).inserted {
            cursor = parents[current] ?? nil
        }
        return cursor != nil
    }
}
