// SPDX-License-Identifier: AGPL-3.0-only

public struct HikariSmartCondition: Hashable, Sendable {
    public let field: String
    public let values: [String]
    public let matchAll: Bool
    public let minimum: Double?
    public let maximum: Double?
    public let days: Int64?
    public let excluded: Bool

    public init(
        field: String,
        values: [String] = [],
        matchAll: Bool = false,
        minimum: Double? = nil,
        maximum: Double? = nil,
        days: Int64? = nil,
        excluded: Bool = false
    ) {
        self.field = field
        self.values = values
        self.matchAll = matchAll
        self.minimum = minimum
        self.maximum = maximum
        self.days = days
        self.excluded = excluded
    }
}

public enum HikariSmartRuleTranslation: Hashable, Sendable {
    case compatible(SmartRule)
    case disabledDraft(warningCode: String)
}

public enum HikariSmartRuleTranslator {
    public static func translate(matchAll: Bool, conditions: [HikariSmartCondition]) -> HikariSmartRuleTranslation {
        guard !conditions.isEmpty else { return .disabledDraft(warningCode: "empty-smart-rule") }
        var nodes: [SmartRuleNode] = []
        for condition in conditions {
            let predicate: SmartPredicate
            switch condition.field.lowercased() {
            case "source":
                predicate = .sourceIn(Set(condition.values))
            case "folder", "manualcollection":
                predicate = .inManualCollection(Set(condition.values))
            case "tag":
                predicate = .tagContains(mode: condition.matchAll ? .all : .any, tags: Set(condition.values))
            case "title":
                predicate = .titleContains(Set(condition.values))
            case "author":
                predicate = .authorContains(Set(condition.values))
            case "status", "update":
                var statuses = Set<PublicationStatus>()
                for value in condition.values {
                    guard let status = PublicationStatus(rawValue: value.lowercased()) else {
                        return .disabledDraft(warningCode: "invalid-smart-rule")
                    }
                    statuses.insert(status)
                }
                predicate = .statusIn(statuses)
            case "rating":
                predicate = .ratingBetween(minimum: condition.minimum, maximum: condition.maximum)
            case "added":
                guard let days = condition.days else { return .disabledDraft(warningCode: "invalid-smart-window") }
                predicate = .addedWithinDays(days)
            case "lastread", "date":
                guard let days = condition.days else { return .disabledDraft(warningCode: "invalid-smart-window") }
                predicate = .lastReadWithinDays(days)
            case "metadataupdated":
                guard let days = condition.days else { return .disabledDraft(warningCode: "invalid-smart-window") }
                predicate = .metadataUpdatedWithinDays(days)
            case "progress":
                var states = Set<ProgressState>()
                for value in condition.values {
                    guard let state = ProgressState(rawValue: value.lowercased()) else {
                        return .disabledDraft(warningCode: "invalid-smart-rule")
                    }
                    states.insert(state)
                }
                predicate = .progressIn(states)
            case "unread":
                predicate = .hasUnreadUpdate
            case "sourceupdate":
                predicate = .hasSourceUpdate
            case "dormant":
                predicate = .isDormantSource
            case "section", "subscription":
                return .disabledDraft(warningCode: "unsupported-smart-condition")
            default:
                return .disabledDraft(warningCode: "unknown-smart-condition")
            }
            let node = SmartRuleNode.predicate(predicate)
            nodes.append(condition.excluded ? .not(node) : node)
        }
        let root: SmartRuleNode = matchAll ? .all(nodes) : .any(nodes)
        guard let rule = try? SmartRule(root: root), SmartRuleValidator.validate(rule).isEmpty else {
            return .disabledDraft(warningCode: "invalid-smart-rule")
        }
        return .compatible(rule)
    }
}
