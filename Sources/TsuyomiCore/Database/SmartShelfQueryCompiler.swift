// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// Compiles a validated smart-shelf AST into one parameterised SELECT. Every user value becomes a
/// binding: no rule text is ever concatenated into SQL.
public enum SmartShelfQueryCompiler {
    public struct CompiledQuery: Sendable {
        public let sql: String
        public let bindings: [SQLiteValue]
    }

    static let maximumArguments = 900

    public static func compile(_ rule: SmartRule, now: Date) throws -> CompiledQuery {
        try requireWithinArgumentLimit(rule)
        var bindings: [SQLiteValue] = []
        let predicate = compileNode(rule.root, &bindings, now.epochSecond)
        guard bindings.count <= maximumArguments else {
            throw DatabaseError.invariantViolated("smart rule exceeds SQL argument limit")
        }
        return CompiledQuery(
            sql: """
            SELECT le.source_id, le.remote_book_id
            FROM library_entries le
            JOIN books b ON b.source_id = le.source_id AND b.remote_book_id = le.remote_book_id
            LEFT JOIN source_availability sa ON sa.source_id = le.source_id
            WHERE \(predicate)
            ORDER BY b.title COLLATE NOCASE, le.source_id, le.remote_book_id
            """,
            bindings: bindings
        )
    }

    public static func requireWithinArgumentLimit(_ rule: SmartRule) throws {
        guard argumentCost(rule.root) <= maximumArguments else {
            throw DatabaseError.invariantViolated("smart rule exceeds SQL argument limit")
        }
    }

    private static func argumentCost(_ node: SmartRuleNode) -> Int {
        switch node {
        case .all(let children), .any(let children):
            return children.reduce(0) { $0 + argumentCost($1) }
        case .not(let child):
            return argumentCost(child)
        case .predicate(let predicate):
            switch predicate {
            case .sourceIn(let values): return values.count
            case .inManualCollection(let values): return values.count
            case .tagContains(_, let tags): return tags.count * 2
            case .facetIn(_, let facetIds): return 1 + facetIds.count
            case .titleContains(let terms): return terms.count
            case .authorContains(let terms): return terms.count
            case .statusIn(let statuses): return statuses.count
            case .ratingBetween(let minimum, let maximum):
                return (minimum == nil ? 0 : 1) + (maximum == nil ? 0 : 1)
            case .addedWithinDays, .lastReadWithinDays, .metadataUpdatedWithinDays: return 1
            case .progressIn, .hasUnreadUpdate, .hasSourceUpdate, .isDormantSource: return 0
            }
        }
    }

    private static func compileNode(_ node: SmartRuleNode, _ bindings: inout [SQLiteValue], _ now: Int64) -> String {
        switch node {
        case .all(let children):
            return "(" + children.map { compileNode($0, &bindings, now) }.joined(separator: " AND ") + ")"
        case .any(let children):
            return "(" + children.map { compileNode($0, &bindings, now) }.joined(separator: " OR ") + ")"
        case .not(let child):
            return "(NOT \(compileNode(child, &bindings, now)))"
        case .predicate(let predicate):
            return compilePredicate(predicate, &bindings, now)
        }
    }

    private static func compilePredicate(
        _ predicate: SmartPredicate,
        _ bindings: inout [SQLiteValue],
        _ now: Int64
    ) -> String {
        switch predicate {
        case .sourceIn(let values):
            return inClause("le.source_id", CanonicalOrder.sorted(values), &bindings)
        case .inManualCollection(let values):
            let ordered = CanonicalOrder.sorted(values)
            bindings.append(contentsOf: ordered.map { .text($0) })
            return """
            EXISTS (SELECT 1 FROM manual_collection_memberships m WHERE m.source_id = le.source_id \
            AND m.remote_book_id = le.remote_book_id AND m.collection_id IN (\(placeholders(ordered.count))))
            """
        case .tagContains(let mode, let tags):
            return combine(mode, CanonicalOrder.sorted(tags)) { tagClause($0, &bindings) }
        case .facetIn(let sourceId, let facetIds):
            bindings.append(.text(sourceId))
            let facets = "(" + CanonicalOrder.sorted(facetIds)
                .map { jsonArrayValueClause("b.remote_tags_json", $0, &bindings) }
                .joined(separator: " OR ") + ")"
            return "(le.source_id = ? AND \(facets))"
        case .titleContains(let terms):
            return combine(.any, CanonicalOrder.sorted(terms)) { likeClause("b.title", $0, &bindings) }
        case .authorContains(let terms):
            return combine(.any, CanonicalOrder.sorted(terms)) {
                jsonArrayValueClause("b.authors_json", $0, &bindings)
            }
        case .statusIn(let statuses):
            return inClause(
                "LOWER(COALESCE(b.status, 'unknown'))",
                CanonicalOrder.sorted(statuses.map(\.rawValue)),
                &bindings
            )
        case .ratingBetween(let minimum, let maximum):
            var clauses: [String] = []
            if let minimum {
                bindings.append(.real(minimum))
                clauses.append("le.rating >= ?")
            }
            if let maximum {
                bindings.append(.real(maximum))
                clauses.append("le.rating <= ?")
            }
            return "(" + clauses.joined(separator: " AND ") + ")"
        case .addedWithinDays(let days):
            return withinDays("le.added_at_epoch_second", days, &bindings, now)
        case .lastReadWithinDays(let days):
            bindings.append(.integer(now - days * 86_400))
            return """
            EXISTS (SELECT 1 FROM reading_progress p WHERE p.source_id = le.source_id \
            AND p.remote_book_id = le.remote_book_id AND p.updated_at_epoch_second >= ?)
            """
        case .metadataUpdatedWithinDays(let days):
            return withinDays("b.metadata_updated_at_epoch_second", days, &bindings, now)
        case .progressIn(let states):
            return progressClause(states)
        case .hasUnreadUpdate:
            return "b.has_unread_update = 1"
        case .hasSourceUpdate:
            return "b.source_update_key IS NOT NULL"
        case .isDormantSource:
            return "sa.available IS NOT 1"
        }
    }

    private static func progressClause(_ states: Set<ProgressState>) -> String {
        let valid = validProgressClause("p")
        let ordered = ProgressState.allCases.filter(states.contains)
        return "(" + ordered.map { state in
            switch state {
            case .unstarted:
                return """
                NOT EXISTS (SELECT 1 FROM reading_progress p WHERE p.source_id = le.source_id \
                AND p.remote_book_id = le.remote_book_id AND \(valid))
                """
            case .reading:
                return """
                EXISTS (SELECT 1 FROM reading_progress p WHERE p.source_id = le.source_id \
                AND p.remote_book_id = le.remote_book_id AND \(valid) AND COALESCE(p.book_progress, 0.0) < 1.0)
                """
            case .finished:
                return """
                EXISTS (SELECT 1 FROM reading_progress p WHERE p.source_id = le.source_id \
                AND p.remote_book_id = le.remote_book_id AND \(valid) AND p.book_progress = 1.0)
                """
            }
        }.joined(separator: " OR ") + ")"
    }

    /// A stored row only counts as progress when it still satisfies reader-locator-v1; a corrupt row
    /// must not make a book look started.
    private static func validProgressClause(_ alias: String) -> String {
        """
        \(alias).content_id IS NOT NULL AND length(\(alias).content_id) BETWEEN 1 AND 1024 \
        AND (\(alias).revision IS NULL OR length(\(alias).revision) BETWEEN 1 AND 256) \
        AND (\(alias).block_id IS NULL OR length(\(alias).block_id) BETWEEN 1 AND 1024) \
        AND (\(alias).text_anchor_digest IS NULL OR ( \
        \(alias).block_id IS NOT NULL AND length(\(alias).text_anchor_digest) = 64 \
        AND \(alias).text_anchor_digest NOT GLOB '*[^0-9a-f]*')) \
        AND (\(alias).character_offset IS NULL OR (\(alias).block_id IS NOT NULL \
        AND \(alias).character_offset >= 0)) \
        AND (\(alias).chapter_progress IS NULL OR (typeof(\(alias).chapter_progress) IN ('integer', 'real') \
        AND \(alias).chapter_progress >= 0.0 AND \(alias).chapter_progress <= 1.0)) \
        AND (\(alias).book_progress IS NULL OR (typeof(\(alias).book_progress) IN ('integer', 'real') \
        AND \(alias).book_progress >= 0.0 AND \(alias).book_progress <= 1.0)) \
        AND ((\(alias).block_id IS NOT NULL AND \(alias).character_offset IS NOT NULL) \
        OR (\(alias).block_id IS NOT NULL AND \(alias).text_anchor_digest IS NOT NULL) \
        OR \(alias).chapter_progress IS NOT NULL OR \(alias).book_progress IS NOT NULL)
        """
    }

    private static func tagClause(_ tag: String, _ bindings: inout [SQLiteValue]) -> String {
        bindings.append(.text(tag))
        let remote = jsonArrayValueClause("b.remote_tags_json", tag, &bindings)
        return """
        (EXISTS (SELECT 1 FROM local_book_tags t WHERE t.source_id = le.source_id \
        AND t.remote_book_id = le.remote_book_id AND t.display_tag = ?) OR \(remote))
        """
    }

    private static func jsonArrayValueClause(
        _ column: String,
        _ value: String,
        _ bindings: inout [SQLiteValue]
    ) -> String {
        bindings.append(.text("%\"\(escapeLike(value).replacingOccurrences(of: "\"", with: "\\\""))\"%"))
        return "\(column) LIKE ? ESCAPE '\\'"
    }

    private static func likeClause(_ column: String, _ value: String, _ bindings: inout [SQLiteValue]) -> String {
        bindings.append(.text("%\(escapeLike(value))%"))
        return "\(column) LIKE ? ESCAPE '\\'"
    }

    private static func withinDays(
        _ column: String,
        _ days: Int64,
        _ bindings: inout [SQLiteValue],
        _ now: Int64
    ) -> String {
        bindings.append(.integer(now - days * 86_400))
        return "\(column) >= ?"
    }

    private static func inClause(
        _ column: String,
        _ values: [String],
        _ bindings: inout [SQLiteValue]
    ) -> String {
        bindings.append(contentsOf: values.map { .text($0) })
        return "\(column) IN (\(placeholders(values.count)))"
    }

    private static func combine(_ mode: MatchMode, _ values: [String], _ clause: (String) -> String) -> String {
        "(" + values.map(clause).joined(separator: mode == .all ? " AND " : " OR ") + ")"
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
