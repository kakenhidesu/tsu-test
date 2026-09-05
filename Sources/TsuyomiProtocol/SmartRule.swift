// SPDX-License-Identifier: AGPL-3.0-only

public enum MatchMode: String, Sendable, Codable, CaseIterable {
    case all
    case any
}

public enum ProgressState: String, Sendable, Codable, CaseIterable {
    case unstarted
    case reading
    case finished
}

public enum PublicationStatus: String, Sendable, Codable, CaseIterable {
    case unknown
    case ongoing
    case completed
    case hiatus
    case cancelled
}

public indirect enum SmartRuleNode: Hashable, Sendable {
    case all([SmartRuleNode])
    case any([SmartRuleNode])
    case not(SmartRuleNode)
    case predicate(SmartPredicate)
}

public enum SmartPredicate: Hashable, Sendable {
    case sourceIn(Set<String>)
    case inManualCollection(Set<String>)
    case tagContains(mode: MatchMode, tags: Set<String>)
    case facetIn(sourceId: String, facetIds: Set<String>)
    case titleContains(Set<String>)
    case authorContains(Set<String>)
    case statusIn(Set<PublicationStatus>)
    case ratingBetween(minimum: Double?, maximum: Double?)
    case addedWithinDays(Int64)
    case lastReadWithinDays(Int64)
    case metadataUpdatedWithinDays(Int64)
    case progressIn(Set<ProgressState>)
    case hasUnreadUpdate
    case hasSourceUpdate
    case isDormantSource
}

public struct SmartRule: Hashable, Sendable {
    public static let currentVersion = 1
    public static let maximumDepth = 8
    public static let maximumNodes = 128
    public static let maximumTextCodePoints = 256
    public static let maximumTerms = 64
    public static let maximumWindowDays: Int64 = 36_500

    public let version: Int
    public let root: SmartRuleNode

    public init(version: Int = SmartRule.currentVersion, root: SmartRuleNode) throws {
        guard version == SmartRule.currentVersion else { throw ProtocolError.invalidSmartRuleVersion }
        self.version = version
        self.root = root
    }
}

public struct SmartRuleViolation: Hashable, Sendable {
    public let code: String
    public let path: String

    public init(code: String, path: String) {
        self.code = code
        self.path = path
    }
}

public enum SmartRuleValidator {
    public static func validate(_ rule: SmartRule) -> [SmartRuleViolation] {
        var violations: [SmartRuleViolation] = []
        var nodes = 0

        func text(_ value: String, _ path: String) {
            if !Grammar.hasCodePoints(value, in: 1...SmartRule.maximumTextCodePoints) {
                violations.append(SmartRuleViolation(code: "invalid-text-length", path: path))
            }
        }
        func terms(_ values: Set<String>, _ path: String) {
            if values.isEmpty || values.count > SmartRule.maximumTerms {
                violations.append(SmartRuleViolation(code: "invalid-term-count", path: path))
            }
            for (index, value) in CanonicalOrder.sorted(values).enumerated() { text(value, "\(path)[\(index)]") }
        }
        func window(_ days: Int64, _ path: String) {
            if days < 0 || days > SmartRule.maximumWindowDays {
                violations.append(SmartRuleViolation(code: "invalid-time-window", path: path))
            }
        }
        func visit(_ node: SmartRuleNode, _ depth: Int, _ path: String) {
            nodes += 1
            if depth > SmartRule.maximumDepth {
                violations.append(SmartRuleViolation(code: "max-depth", path: path))
            }
            switch node {
            case .all(let children), .any(let children):
                if children.isEmpty { violations.append(SmartRuleViolation(code: "empty-group", path: path)) }
                for (index, child) in children.enumerated() {
                    visit(child, depth + 1, "\(path).children[\(index)]")
                }
            case .not(let child):
                visit(child, depth + 1, "\(path).child")
            case .predicate(let predicate):
                switch predicate {
                case .sourceIn(let values): terms(values, "\(path).sourceIds")
                case .inManualCollection(let values): terms(values, "\(path).collectionIds")
                case .tagContains(_, let tags): terms(tags, "\(path).tags")
                case .facetIn(let sourceId, let facetIds):
                    text(sourceId, "\(path).sourceId")
                    terms(facetIds, "\(path).facetIds")
                case .titleContains(let values): terms(values, "\(path).terms")
                case .authorContains(let values): terms(values, "\(path).terms")
                case .statusIn(let statuses):
                    if statuses.isEmpty || statuses.count > SmartRule.maximumTerms {
                        violations.append(SmartRuleViolation(code: "invalid-term-count", path: "\(path).statuses"))
                    }
                case .ratingBetween(let minimum, let maximum):
                    let invalid = (minimum == nil && maximum == nil)
                        || minimum.map { !$0.isFinite || $0 < 0 || $0 > 5 } == true
                        || maximum.map { !$0.isFinite || $0 < 0 || $0 > 5 } == true
                        || (minimum.flatMap { low in maximum.map { low > $0 } } == true)
                    if invalid { violations.append(SmartRuleViolation(code: "invalid-rating-range", path: path)) }
                case .addedWithinDays(let days): window(days, path)
                case .lastReadWithinDays(let days): window(days, path)
                case .metadataUpdatedWithinDays(let days): window(days, path)
                case .progressIn(let states):
                    if states.isEmpty || states.count > SmartRule.maximumTerms {
                        violations.append(SmartRuleViolation(code: "invalid-term-count", path: "\(path).states"))
                    }
                case .hasUnreadUpdate, .hasSourceUpdate, .isDormantSource:
                    break
                }
            }
        }

        visit(rule.root, 1, "rule")
        if nodes > SmartRule.maximumNodes {
            violations.append(SmartRuleViolation(code: "max-nodes", path: "rule"))
        }
        var seen = Set<SmartRuleViolation>()
        return violations.filter { seen.insert($0).inserted }
    }

    @discardableResult
    public static func requireValid(_ rule: SmartRule) throws -> SmartRule {
        let violations = validate(rule)
        guard violations.isEmpty else { throw ProtocolError.invalidSmartRule(violations: violations) }
        return rule
    }
}
