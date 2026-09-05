// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum HikariLimits {
    static let books = 20_000
    static let folders = 5_000
    static let progress = 20_000
    static let searchHistory = 10_000
    static let browsingHistory = 20_000
    static let smartRecords = 128
    static let subscriptionRecords = 1_000
    static let records = 50_000
    static let warnings = 10_000
}

struct HikariWarningLimitExceeded: Error {}

struct HikariWarningCollector {
    private(set) var warnings: [ImportWarning] = []

    mutating func add(
        _ code: String,
        ref: String? = nil,
        field: String? = nil,
        severity: ImportSeverity = .warning
    ) throws {
        guard warnings.count < HikariLimits.warnings else { throw HikariWarningLimitExceeded() }
        warnings.append(
            ImportWarning(
                ordinal: warnings.count,
                safeCode: code,
                safeRecordRef: ref,
                fieldName: field,
                severity: severity
            )
        )
    }
}

enum HikariBackupCodec {
    static func parse(_ root: [String: JSONValue]) -> ImportParseResult {
        guard root.int("schemaVersion") == 1 else { return .fatal(safeCode: "unsupported-version") }
        guard let createdAt = root.instant("createdAt") else { return .fatal(safeCode: "invalid-created-at") }
        guard let payload = root.object("payload") else { return .fatal(safeCode: "invalid-payload") }
        guard withinRecordBounds(payload) else { return .fatal(safeCode: "record-limit") }
        do {
            var warnings = HikariWarningCollector()
            try warnSecrets(payload, &warnings)
            let shelves = try parseShelves(payload.object("bookshelf"), &warnings)
            if hasShelfParentCycle(shelves) { return .fatal(safeCode: "shelf-parent-cycle") }
            let progress = try parseProgress(payload.object("readingData"), createdAt, &warnings)
            let books = try parseBooks(payload.object("bookshelf"), createdAt, progress, shelves, &warnings)
            let reader = try parseReaderPreferences(payload.object("readerSettings"), &warnings)
            let search = try parseSearchHistory(payload.object("readingData"), createdAt, &warnings)
            let browsing = try parseBrowsingHistory(payload.object("readingData"), createdAt, &warnings)
            let smart = try parseSmartSettings(payload.object("appSettings"), &warnings)
            let plan = ImportPlan(
                kind: .hikariBackup,
                sourceCreatedAt: createdAt,
                books: books,
                shelves: shelves,
                readerPreferences: reader,
                searchHistory: search,
                browsingHistory: browsing,
                warnings: warnings.warnings,
                smartCollections: smart.collections,
                subscriptionDrafts: smart.drafts
            )
            return .ready(plan: plan, canonicalDigest: TransferCodec.digest(canonicalPlanDigestInput(plan)))
        } catch is HikariWarningLimitExceeded {
            return .fatal(safeCode: "warning-limit")
        } catch {
            return .fatal(safeCode: "invalid-payload")
        }
    }

    private static func withinRecordBounds(_ payload: [String: JSONValue]) -> Bool {
        let bookshelf = payload.object("bookshelf")
        let readingData = payload.object("readingData")
        let appSettings = payload.object("appSettings")
        let counts: [(Int, Int)] = [
            (recordCount(bookshelf, "items"), HikariLimits.books),
            (recordCount(bookshelf, "folders"), HikariLimits.folders),
            (recordCount(readingData, "readHistory"), HikariLimits.progress),
            (recordCount(readingData, "searchHistory"), HikariLimits.searchHistory),
            (recordCount(readingData, "browsingHistory"), HikariLimits.browsingHistory),
            (recordCount(appSettings, "smartShelfMemberships"), HikariLimits.smartRecords),
            (recordCount(appSettings, "smartShelfSyncMetadata"), HikariLimits.subscriptionRecords)
        ]
        return counts.allSatisfy { $0.0 <= $0.1 } && counts.reduce(0) { $0 + $1.0 } <= HikariLimits.records
    }

    private static func recordCount(_ object: [String: JSONValue]?, _ name: String) -> Int {
        switch object?[name] {
        case .array(let value): return value.count
        case .object(let value): return value.count
        case nil: return 0
        default: return 1
        }
    }

    private static func parseBooks(
        _ bookshelf: [String: JSONValue]?,
        _ createdAt: Date,
        _ progress: [BookIdentity: TransferProgress],
        _ shelves: [TransferShelf],
        _ warnings: inout HikariWarningCollector
    ) throws -> [TransferBook] {
        let items = bookshelf?.array("items") ?? []
        let knownShelves = Set(shelves.map(\.id))
        var books: [BookIdentity: TransferBook] = [:]
        for (index, element) in items.enumerated() {
            let title = element.objectValue?.firstString("title", "name", "bookName")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let item = element.objectValue,
                  let identity = item.string("aid").flatMap(legacyIdentity),
                  let title, (1...4_096).contains(title.utf16.count) else {
                try warnings.add("invalid-book-record", ref: "bookshelf.items[\(index)]")
                continue
            }
            guard books[identity] == nil else {
                try warnings.add("duplicate-book-identity", ref: safeRef(identity), severity: .conflict)
                continue
            }
            let folder = item.firstString("folderId", "shelfId")
            let rating = item.double("rating").flatMap { $0 > 0 && $0 <= 5 ? $0 : nil }
            let authors = try stringListLenient(
                item, "authors", &warnings,
                field: "bookshelf.items[\(index)].authors", maximumItems: 32, maximumCodePoints: 1_024
            )
            let canonicalUrl = try portableUri(
                item.firstString("url", "canonicalUrl"), &warnings,
                field: "bookshelf.items[\(index)].canonicalUrl"
            )
            let coverUrl = try portableUri(
                item.firstString("coverUrl", "cover"), &warnings,
                field: "bookshelf.items[\(index)].coverUrl"
            )
            let remoteTags = try stringListLenient(
                item, "tags", &warnings,
                field: "bookshelf.items[\(index)].tags", maximumItems: 128, maximumCodePoints: 256
            )
            let localTags = try stringListLenient(
                item, "localTags", &warnings,
                field: "bookshelf.items[\(index)].localTags", maximumItems: 64, maximumCodePoints: 64
            )
            books[identity] = TransferBook(
                identity: identity,
                title: title,
                authors: Set(authors),
                canonicalUrl: canonicalUrl,
                coverUrl: coverUrl,
                status: normalizeStatus(item.string("status")),
                remoteTags: Set(remoteTags),
                localTags: Set(localTags),
                shelfIds: Set([folder].compactMap { $0 }.filter(knownShelves.contains)),
                rating: rating,
                addedAt: item.instant("addedAt") ?? createdAt,
                updatedAt: item.instant("updatedAt") ?? item.instant("lastUpdate") ?? createdAt,
                progress: progress[identity]
            )
        }
        return books.values.sorted { $0.identity < $1.identity }
    }

    private static func parseShelves(
        _ bookshelf: [String: JSONValue]?,
        _ warnings: inout HikariWarningCollector
    ) throws -> [TransferShelf] {
        guard let folders = bookshelf?.array("folders") else { return [] }
        var result: [TransferShelf] = []
        var seen = Set<String>()
        for (index, element) in folders.enumerated() {
            let folder = element.objectValue
            let id = folder?.firstString("id", "folderId")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = folder?.firstString("name", "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawParentId = folder?.string("parentId")
            let parentId = rawParentId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validId = id.flatMap { (1...128).contains($0.utf16.count) ? $0 : nil }
            let validName = name.flatMap { (1...256).contains($0.utf16.count) ? $0 : nil }
            let validParent = parentId.flatMap { (1...128).contains($0.utf16.count) ? $0 : nil }
            guard let validId, let validName, !seen.contains(validId),
                  !(rawParentId != nil && validParent == nil) else {
                try warnings.add("invalid-manual-shelf", ref: "bookshelf.folders[\(index)]")
                continue
            }
            seen.insert(validId)
            result.append(
                TransferShelf(
                    id: validId,
                    name: validName,
                    parentId: validParent,
                    position: folder?.int("position").map { max($0, 0) } ?? index
                )
            )
        }
        var repaired: [TransferShelf] = []
        for shelf in result {
            if let parentId = shelf.parentId, !seen.contains(parentId) {
                try warnings.add("dangling-shelf-parent", ref: shelf.id, field: "parentId")
                repaired.append(shelf.withParentId(nil))
            } else {
                repaired.append(shelf)
            }
        }
        return repaired
    }

    private static func parseProgress(
        _ readingData: [String: JSONValue]?,
        _ createdAt: Date,
        _ warnings: inout HikariWarningCollector
    ) throws -> [BookIdentity: TransferProgress] {
        guard let rows = readingData?.array("readHistory") else { return [:] }
        var result: [BookIdentity: TransferProgress] = [:]
        for (index, element) in rows.enumerated() {
            let row = element.objectValue
            guard let row, let identity = row.string("aid").flatMap(legacyIdentity) else {
                try warnings.add("invalid-progress-identity", ref: "readingData.readHistory[\(index)]")
                continue
            }
            var candidate = row.string("locatorJson").flatMap(HikariSemanticLocator.parse)
            if candidate == nil {
                let rawChapterId = row.firstString("cid", "chapterId")
                let trimmedChapterId = rawChapterId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let chapterId = trimmedChapterId.flatMap { (1...1_024).contains($0.utf16.count) ? $0 : nil }
                let offset = row.int("location").flatMap { $0 >= 0 ? $0 : nil }
                let bookProgress = row.double("progress").flatMap { Grammar.isBoundedProgress($0) ? $0 : nil }
                if (offset == nil && bookProgress == nil) || (rawChapterId != nil && chapterId == nil) {
                    try warnings.add("invalid-progress-record", ref: safeRef(identity))
                    continue
                }
                try warnings.add("reduced-progress-time-precision", ref: safeRef(identity), field: "updatedAt")
                candidate = TransferProgress(
                    chapterId: chapterId,
                    characterOffset: offset,
                    bookProgress: bookProgress,
                    updatedAt: createdAt
                )
            }
            if result[identity] == nil, let candidate {
                result[identity] = candidate.withUpdatedAt(createdAt)
            }
        }
        return result
    }

    private static func parseSearchHistory(
        _ readingData: [String: JSONValue]?,
        _ createdAt: Date,
        _ warnings: inout HikariWarningCollector
    ) throws -> [SourceSearchHistory] {
        var result: [SourceSearchHistory] = []
        for (index, element) in (readingData?.array("searchHistory") ?? []).enumerated() {
            let row = element.objectValue
            let sourceId = row?.firstString("sourceId", "source").flatMap(legacySourceId)
            let query = row?.firstString("query", "keyword")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sourceId, let query, !query.isEmpty else {
                try warnings.add("invalid-search-history", ref: "readingData.searchHistory[\(index)]")
                continue
            }
            result.append(
                SourceSearchHistory(
                    sourceId: sourceId,
                    query: String(query.prefix(256)),
                    lastUsedAt: row?.instant("lastUsedAt") ?? createdAt
                )
            )
        }
        return result
    }

    private static func parseBrowsingHistory(
        _ readingData: [String: JSONValue]?,
        _ createdAt: Date,
        _ warnings: inout HikariWarningCollector
    ) throws -> [SourceBrowsingHistory] {
        var result: [SourceBrowsingHistory] = []
        for (index, element) in (readingData?.array("browsingHistory") ?? []).enumerated() {
            let row = element.objectValue
            guard let identity = row?.string("aid").flatMap(legacyIdentity) else {
                try warnings.add("invalid-browsing-history", ref: "readingData.browsingHistory[\(index)]")
                continue
            }
            result.append(
                SourceBrowsingHistory(identity: identity, lastViewedAt: row?.instant("lastViewedAt") ?? createdAt)
            )
        }
        return result
    }

    private static func parseReaderPreferences(
        _ settings: [String: JSONValue]?,
        _ warnings: inout HikariWarningCollector
    ) throws -> PortableReaderPreferences? {
        guard let settings else { return nil }
        var flow: String?
        switch settings.firstString("flow", "readingMode")?.lowercased() {
        case "scroll", "vertical": flow = "scroll"
        case "paged", "page", "horizontal": flow = "paged"
        case nil: flow = nil
        default: try warnings.add("unknown-reader-flow", field: "flow")
        }
        return PortableReaderPreferences(
            flow: flow,
            fontScale: settings.double("fontScale").flatMap { (0.5...3.0).contains($0) ? $0 : nil },
            lineHeight: settings.double("lineHeight").flatMap { (0.8...3.0).contains($0) ? $0 : nil },
            theme: settings.string("theme").flatMap { PortableReaderPreferences.themes.contains($0) ? $0 : nil }
        )
    }

    private static func canonicalPlanDigestInput(_ plan: ImportPlan) -> Data {
        var text = "\(plan.kind.rawValue)\n\(ProtocolTimestamp.format(plan.sourceCreatedAt))\n"
        for book in plan.books {
            text += "\(book.identity.sourceId)\u{0}\(book.identity.remoteBookId)\u{0}"
            text += "\(ProtocolTimestamp.format(book.updatedAt))\n"
        }
        for shelf in plan.shelves.sorted(by: { CanonicalOrder.precedes($0.id, $1.id) }) {
            text += "\(shelf.id)\u{0}\(shelf.parentId ?? "")\n"
        }
        for warning in plan.warnings {
            text += "\(warning.safeCode)\u{0}\(warning.safeRecordRef ?? "")\u{0}\(warning.fieldName ?? "")\n"
        }
        return Data(text.utf8)
    }

    static func legacyIdentity(_ aid: String) -> BookIdentity? {
        let value = aid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let mapped: (String, String)
        if value.hasPrefix("esj:"), value.count > 4 {
            mapped = ("org.tsuyomi.esjzone", String(value.dropFirst(4)))
        } else if value.hasPrefix("yamibo:"), value.count > 7 {
            mapped = ("org.tsuyomi.yamibo", String(value.dropFirst(7)))
        } else if !value.contains(":") {
            mapped = ("org.tsuyomi.wenku8", value)
        } else {
            return nil
        }
        guard Grammar.hasCodePoints(mapped.1, in: 1...1_024) else { return nil }
        return try? BookIdentity(sourceId: mapped.0, remoteBookId: mapped.1)
    }

    private static func legacySourceId(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wenku8", "org.tsuyomi.wenku8": return "org.tsuyomi.wenku8"
        case "esj", "esjzone", "org.tsuyomi.esjzone": return "org.tsuyomi.esjzone"
        case "yamibo", "org.tsuyomi.yamibo": return "org.tsuyomi.yamibo"
        default: return nil
        }
    }

    private static func normalizeStatus(_ value: String?) -> String {
        switch value?.lowercased() {
        case "ongoing", "completed", "hiatus", "cancelled": return value?.lowercased() ?? "unknown"
        default: return "unknown"
        }
    }

    static func safeRef(_ identity: BookIdentity) -> String {
        "\(identity.sourceId):\(identity.remoteBookId)"
    }

    private static func stringListLenient(
        _ object: [String: JSONValue],
        _ name: String,
        _ warnings: inout HikariWarningCollector,
        field: String,
        maximumItems: Int,
        maximumCodePoints: Int
    ) throws -> [String] {
        guard let value = object[name] else { return [] }
        guard let array = value.arrayValue else {
            try warnings.add("invalid-tag-list", field: field)
            return []
        }
        var valid: [String] = []
        for element in array {
            guard let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, Grammar.codePointCount(text) <= maximumCodePoints else { continue }
            if !valid.contains(text) { valid.append(text) }
        }
        if valid.count != array.count || valid.count > maximumItems {
            try warnings.add("invalid-tag-list", field: field)
        }
        return Array(valid.prefix(maximumItems))
    }

    private static func portableUri(
        _ value: String?,
        _ warnings: inout HikariWarningCollector,
        field: String
    ) throws -> String? {
        guard let value else { return nil }
        if let scheme = URLComponents(string: value)?.scheme, !scheme.isEmpty { return value }
        try warnings.add("invalid-book-uri", field: field)
        return nil
    }
}
