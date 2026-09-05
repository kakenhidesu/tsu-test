// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// One editable predicate row. The editor holds a flat list of these under a single combinator,
/// which is exactly the shape the rule grammar allows without nesting; anything deeper is imported,
/// not authored here.
public struct SmartPredicateDraft: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case titleContains
        case authorContains
        case tagContains
        case sourceIn
        case statusIn
        case progressIn
        case addedWithinDays
        case lastReadWithinDays
        case hasUnreadUpdate
        case isDormantSource

        public var title: String {
            switch self {
            case .titleContains: return "书名包含"
            case .authorContains: return "作者包含"
            case .tagContains: return "标签包含"
            case .sourceIn: return "来源属于"
            case .statusIn: return "连载状态"
            case .progressIn: return "阅读进度"
            case .addedWithinDays: return "加入于最近天数"
            case .lastReadWithinDays: return "最近阅读于天数内"
            case .hasUnreadUpdate: return "有未读更新"
            case .isDormantSource: return "来源已休眠"
            }
        }

        public var takesTerms: Bool {
            switch self {
            case .titleContains, .authorContains, .tagContains, .sourceIn: return true
            case .statusIn, .progressIn, .addedWithinDays, .lastReadWithinDays,
                 .hasUnreadUpdate, .isDormantSource: return false
            }
        }

        public var takesDays: Bool {
            self == .addedWithinDays || self == .lastReadWithinDays
        }
    }

    public let id = UUID()
    public var kind: Kind = .titleContains
    public var terms: String = ""
    public var days: Int = 30
    public var statuses: Set<PublicationStatus> = [.ongoing]
    public var progress: Set<ProgressState> = [.reading]
    public var isNegated = false

    public init() {}
}

public enum SmartRuleCompilation: Sendable {
    case ready(SmartRule)
    case rejected([SmartRuleViolation])
}

public struct SmartRuleDraft: Hashable, Sendable {
    public var title: String = ""
    public var combinator: MatchMode = .all
    public var predicates: [SmartPredicateDraft] = [SmartPredicateDraft()]

    public init() {}

    /// Builds the rule the store will persist, or the violations that stop it. The editor shows these
    /// inline against the row that produced them, so a rejected rule is never silently dropped.
    public func compile() -> SmartRuleCompilation {
        var nodes: [SmartRuleNode] = []
        var violations: [SmartRuleViolation] = []
        for (index, draft) in predicates.enumerated() {
            guard let predicate = SmartRuleDraft.predicate(draft) else {
                violations.append(SmartRuleViolation(code: "invalid-term-count", path: "root[\(index)]"))
                continue
            }
            nodes.append(draft.isNegated ? .not(.predicate(predicate)) : .predicate(predicate))
        }
        guard violations.isEmpty, !nodes.isEmpty else {
            return .rejected(violations.isEmpty
                ? [SmartRuleViolation(code: "empty-rule", path: "root")]
                : violations)
        }
        let root: SmartRuleNode = combinator == .all ? .all(nodes) : .any(nodes)
        guard let rule = try? SmartRule(root: root) else {
            return .rejected([SmartRuleViolation(code: "invalid-rule", path: "root")])
        }
        let checked = SmartRuleValidator.validate(rule)
        return checked.isEmpty ? .ready(rule) : .rejected(checked)
    }

    private static func predicate(_ draft: SmartPredicateDraft) -> SmartPredicate? {
        let terms = Set(
            draft.terms
                .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        switch draft.kind {
        case .titleContains: return terms.isEmpty ? nil : .titleContains(terms)
        case .authorContains: return terms.isEmpty ? nil : .authorContains(terms)
        case .tagContains: return terms.isEmpty ? nil : .tagContains(mode: .any, tags: terms)
        case .sourceIn: return terms.isEmpty ? nil : .sourceIn(terms)
        case .statusIn: return draft.statuses.isEmpty ? nil : .statusIn(draft.statuses)
        case .progressIn: return draft.progress.isEmpty ? nil : .progressIn(draft.progress)
        case .addedWithinDays: return .addedWithinDays(Int64(draft.days))
        case .lastReadWithinDays: return .lastReadWithinDays(Int64(draft.days))
        case .hasUnreadUpdate: return .hasUnreadUpdate
        case .isDormantSource: return .isDormantSource
        }
    }
}
