// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Internal crash-recovery format. It is not a portable transfer format and is never exported.
public enum ImportPlanCodec {
    public static func encode(_ plan: ImportPlan) throws -> Data {
        let transfer = try TransferCodec.encode(
            TransferSnapshot(
                createdAt: plan.sourceCreatedAt,
                library: plan.books,
                shelves: plan.shelves,
                readerPreferences: plan.readerPreferences
            )
        )
        let searchHistory = plan.searchHistory.sorted { lhs, rhs in
            let bySource = CanonicalOrder.compare(lhs.sourceId, rhs.sourceId)
            if bySource != 0 { return bySource < 0 }
            let byQuery = CanonicalOrder.compare(lhs.query, rhs.query)
            if byQuery != 0 { return byQuery < 0 }
            return lhs.lastUsedAt < rhs.lastUsedAt
        }
        let browsingHistory = plan.browsingHistory.sorted { lhs, rhs in
            if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
            return lhs.lastViewedAt < rhs.lastViewedAt
        }
        let root = JSONValue.object([
            "format": .string("tsuyomi-import-plan"),
            "version": .int(1),
            "kind": .string(plan.kind.rawValue),
            "sourceCreatedAt": .string(ProtocolTimestamp.format(plan.sourceCreatedAt)),
            "transfer": try JSONValue.decode(transfer),
            "searchHistory": .array(searchHistory.map { row in
                .object([
                    "sourceId": .string(row.sourceId),
                    "query": .string(row.query),
                    "lastUsedAt": .string(ProtocolTimestamp.format(row.lastUsedAt))
                ])
            }),
            "browsingHistory": .array(browsingHistory.map { row in
                .object([
                    "sourceId": .string(row.identity.sourceId),
                    "remoteBookId": .string(row.identity.remoteBookId),
                    "lastViewedAt": .string(ProtocolTimestamp.format(row.lastViewedAt))
                ])
            }),
            "warnings": .array(plan.warnings.sorted { $0.ordinal < $1.ordinal }.map { warning in
                var fields: [String: JSONValue] = [
                    "ordinal": .int(warning.ordinal),
                    "safeCode": .string(warning.safeCode),
                    "severity": .string(warning.severity.rawValue)
                ]
                warning.safeRecordRef.map { fields["safeRecordRef"] = .string($0) }
                warning.fieldName.map { fields["fieldName"] = .string($0) }
                return .object(fields)
            }),
            "smartCollections": .array(
                plan.smartCollections
                    .sorted { CanonicalOrder.precedes($0.collectionId, $1.collectionId) }
                    .map { smart in
                        .object([
                            "collectionId": .string(smart.collectionId),
                            "title": .string(smart.title),
                            "astJson": .string(smart.astJson)
                        ])
                    }
            ),
            "subscriptionDrafts": .array(
                plan.subscriptionDrafts
                    .sorted { CanonicalOrder.precedes($0.collectionId, $1.collectionId) }
                    .map { draft in
                        .object([
                            "collectionId": .string(draft.collectionId),
                            "title": .string(draft.title),
                            "mode": .string(draft.mode),
                            "sourceScopeJson": .string(draft.sourceScopeJson),
                            "queryJson": .string(draft.queryJson)
                        ])
                    }
            )
        ])
        return try root.encoded()
    }

    public static func decode(_ bytes: Data) throws -> ImportPlan {
        guard let root = try JSONValue.decode(bytes).objectValue else {
            throw ProtocolError.unexpectedJsonType(field: "plan")
        }
        guard Set(root.keys) == rootFields else { throw ProtocolError.unknownField("plan") }
        guard root.string("format") == "tsuyomi-import-plan", root.int("version") == 1 else {
            throw ProtocolError.unknownField("format")
        }
        guard let rawKind = root.string("kind"), let kind = ImportKind(rawValue: rawKind) else {
            throw ProtocolError.missingField("kind")
        }
        guard let sourceCreatedAt = root.instant("sourceCreatedAt") else {
            throw ProtocolError.invalidTimestamp(field: "sourceCreatedAt")
        }
        guard let transferValue = root["transfer"] else { throw ProtocolError.missingField("transfer") }
        guard case .ready(let transfer, _) = TransferCodec.parse(try transferValue.encoded()) else {
            throw ProtocolError.malformedJson
        }
        guard transfer.sourceCreatedAt == sourceCreatedAt else {
            throw ProtocolError.invalidTimestamp(field: "sourceCreatedAt")
        }
        return ImportPlan(
            kind: kind,
            sourceCreatedAt: sourceCreatedAt,
            books: transfer.books,
            shelves: transfer.shelves,
            readerPreferences: transfer.readerPreferences,
            searchHistory: try (root.array("searchHistory") ?? []).map { element in
                guard let row = element.objectValue,
                      Set(row.keys) == ["sourceId", "query", "lastUsedAt"],
                      let sourceId = row.string("sourceId"), let query = row.string("query"),
                      let lastUsedAt = row.instant("lastUsedAt") else {
                    throw ProtocolError.unknownField("searchHistory")
                }
                return SourceSearchHistory(sourceId: sourceId, query: query, lastUsedAt: lastUsedAt)
            },
            browsingHistory: try (root.array("browsingHistory") ?? []).map { element in
                guard let row = element.objectValue,
                      Set(row.keys) == ["sourceId", "remoteBookId", "lastViewedAt"],
                      let sourceId = row.string("sourceId"), let remoteBookId = row.string("remoteBookId"),
                      let lastViewedAt = row.instant("lastViewedAt") else {
                    throw ProtocolError.unknownField("browsingHistory")
                }
                return SourceBrowsingHistory(
                    identity: try BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
                    lastViewedAt: lastViewedAt
                )
            },
            warnings: try (root.array("warnings") ?? []).map { element in
                guard let row = element.objectValue, row.hasOnly(warningFields),
                      let ordinal = row.int("ordinal"), let safeCode = row.string("safeCode"),
                      let rawSeverity = row.string("severity"),
                      let severity = ImportSeverity(rawValue: rawSeverity) else {
                    throw ProtocolError.unknownField("warnings")
                }
                return ImportWarning(
                    ordinal: ordinal,
                    safeCode: safeCode,
                    safeRecordRef: row.string("safeRecordRef"),
                    fieldName: row.string("fieldName"),
                    severity: severity
                )
            },
            smartCollections: try (root.array("smartCollections") ?? []).map { element in
                guard let row = element.objectValue,
                      Set(row.keys) == ["collectionId", "title", "astJson"],
                      let collectionId = row.string("collectionId"), let title = row.string("title"),
                      let astJson = row.string("astJson") else {
                    throw ProtocolError.unknownField("smartCollections")
                }
                return ImportedSmartCollection(collectionId: collectionId, title: title, astJson: astJson)
            },
            subscriptionDrafts: try (root.array("subscriptionDrafts") ?? []).map { element in
                guard let row = element.objectValue,
                      Set(row.keys) == ["collectionId", "title", "mode", "sourceScopeJson", "queryJson"],
                      let collectionId = row.string("collectionId"), let title = row.string("title"),
                      let mode = row.string("mode"), let sourceScopeJson = row.string("sourceScopeJson"),
                      let queryJson = row.string("queryJson") else {
                    throw ProtocolError.unknownField("subscriptionDrafts")
                }
                return ImportedSubscriptionDraft(
                    collectionId: collectionId,
                    title: title,
                    mode: mode,
                    sourceScopeJson: sourceScopeJson,
                    queryJson: queryJson
                )
            }
        )
    }

    private static let rootFields: Set<String> = [
        "format", "version", "kind", "sourceCreatedAt", "transfer",
        "searchHistory", "browsingHistory", "warnings", "smartCollections", "subscriptionDrafts"
    ]
    private static let warningFields: Set<String> = [
        "ordinal", "safeCode", "safeRecordRef", "fieldName", "severity"
    ]
}
