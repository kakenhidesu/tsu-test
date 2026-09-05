// SPDX-License-Identifier: AGPL-3.0-only

extension HikariBackupCodec {
    struct SmartSettings {
        let collections: [ImportedSmartCollection]
        let drafts: [ImportedSubscriptionDraft]
    }

    static func parseSmartSettings(
        _ settings: [String: JSONValue]?,
        _ warnings: inout HikariWarningCollector
    ) throws -> SmartSettings {
        guard let settings else { return SmartSettings(collections: [], drafts: []) }
        var collections: [ImportedSmartCollection] = []
        var drafts: [ImportedSubscriptionDraft] = []
        for (index, element) in (settings.array("smartShelfMemberships") ?? []).enumerated() {
            let row = element.objectValue
            let id = row?.firstString("id", "shelfId")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = row?.firstString("name", "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let conditions = row?.array("conditions")
            guard let row, let id, (1...128).contains(id.utf16.count),
                  let title, (1...256).contains(title.utf16.count),
                  let conditions, conditions.count <= 128 else {
                try warnings.add("invalid-smart-rule", ref: "appSettings.smartShelfMemberships[\(index)]")
                continue
            }
            let parsed = conditions.compactMap(smartCondition)
            guard parsed.count == conditions.count else {
                try warnings.add("invalid-smart-condition", ref: id)
                drafts.append(disabledSmartDraft(id: id, title: title))
                continue
            }
            switch HikariSmartRuleTranslator.translate(matchAll: row.bool("matchAll") != false, conditions: parsed) {
            case .compatible(let rule):
                collections.append(
                    ImportedSmartCollection(collectionId: id, title: title, astJson: try SmartRuleCodec.encode(rule))
                )
            case .disabledDraft(let warningCode):
                try warnings.add(warningCode, ref: id)
                drafts.append(disabledSmartDraft(id: id, title: title))
            }
        }
        if settings["smartShelfSyncMetadata"]?.isNonEmpty == true {
            try warnings.add("subscription-imported-disabled", field: "appSettings.smartShelfSyncMetadata")
            drafts.append(
                ImportedSubscriptionDraft(
                    collectionId: "hikari-subscriptions",
                    title: "Hikari 订阅草稿",
                    mode: "disabled",
                    sourceScopeJson: "[]",
                    queryJson: "{}"
                )
            )
        }
        return SmartSettings(collections: collections, drafts: drafts)
    }

    private static func disabledSmartDraft(id: String, title: String) -> ImportedSubscriptionDraft {
        ImportedSubscriptionDraft(
            collectionId: id,
            title: title,
            mode: "disabled-smart",
            sourceScopeJson: "[]",
            queryJson: "{}"
        )
    }

    private static func smartCondition(_ element: JSONValue) -> HikariSmartCondition? {
        guard let condition = element.objectValue,
              let field = condition.firstString("field", "type") else { return nil }
        let values: [String]
        if let listed = condition.array("values") {
            values = Array(listed.compactMap(\.stringValue).prefix(64))
        } else {
            values = [condition.firstString("value", "term")].compactMap { $0 }
        }
        return HikariSmartCondition(
            field: field,
            values: values,
            matchAll: condition.bool("matchAll") == true || condition.string("match") == "all",
            minimum: condition.double("minimum"),
            maximum: condition.double("maximum"),
            days: condition.int("days").map(Int64.init),
            excluded: condition.bool("excluded") == true
        )
    }

    /// Credentials, caches, and device state never enter an import plan: the field is reported by
    /// name and dropped (hxp-package-v1 §Trust forbids carrying source secrets across hosts).
    static func warnSecrets(_ payload: [String: JSONValue], _ warnings: inout HikariWarningCollector) throws {
        try visit(.object(payload), path: "payload", &warnings)
    }

    private static func visit(
        _ element: JSONValue,
        path: String,
        _ warnings: inout HikariWarningCollector
    ) throws {
        switch element {
        case .object(let fields):
            for name in CanonicalOrder.sorted(fields.keys) {
                guard let value = fields[name] else { continue }
                let childPath = path.isEmpty ? name : "\(path).\(name)"
                if excludedFieldNames.contains(normalizedFieldName(name)), value.isNonEmpty {
                    try warnings.add("credential-field-skipped", field: childPath)
                } else {
                    try visit(value, path: childPath, &warnings)
                }
            }
        case .array(let items):
            for (index, value) in items.enumerated() {
                try visit(value, path: "\(path)[\(index)]", &warnings)
            }
        default:
            break
        }
    }

    private static func normalizedFieldName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let excludedFieldNames: Set<String> = [
        "account", "assistedhtmlcache", "cache", "cookie", "cookies", "credential", "daybgimage",
        "devicerefreshstate", "esjcookie", "fontfilepath", "fontpath", "nightbgimage", "password",
        "readerpredictivepreloadstats", "readerttsengine", "readerttsvoice", "readertextfamily",
        "readertextstylefilepath", "refreshstate", "screenrefreshstate", "smartshelfsyncmetadata",
        "smartsubscriptionaddstosourceshelf", "smartsubscriptionminsyncintervalseconds", "sourcecache",
        "sourcelocalhiddenaids", "sourcesyncconfigs", "sourcetagusecounts", "textfamily",
        "textstylefilepath", "token", "ttsengine", "ttsvoice", "userinfo", "webview", "webviewcookies",
        "webviewstate", "webviewstorage", "wenku8userinfo", "wenku8useragent", "yamibocookie",
        "yamiboownercatalogue", "yamiboownercataloguefailures", "yamiboownercataloguekeys"
    ]
}
