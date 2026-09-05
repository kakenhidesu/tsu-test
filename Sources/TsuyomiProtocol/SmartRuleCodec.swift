// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum SmartRuleCodec {
    public static func encode(_ rule: SmartRule) throws -> String {
        try SmartRuleValidator.requireValid(rule)
        let root = JSONValue.object(["version": .int(rule.version), "rule": encodeNode(rule.root)])
        let data = try root.encoded()
        guard let text = String(data: data, encoding: .utf8) else { throw ProtocolError.malformedJson }
        return text
    }

    public static func decode(_ value: String) throws -> SmartRule {
        guard let data = value.data(using: .utf8) else { throw ProtocolError.malformedJson }
        guard let root = try JSONValue.decode(data).objectValue else {
            throw ProtocolError.unexpectedJsonType(field: "rule")
        }
        guard root.hasOnly(["version", "rule"]), root.count == 2 else { throw ProtocolError.unknownField("rule") }
        guard root.int("version") == SmartRule.currentVersion else { throw ProtocolError.invalidSmartRuleVersion }
        guard let node = root.object("rule") else { throw ProtocolError.missingField("rule") }
        return try SmartRuleValidator.requireValid(
            SmartRule(version: SmartRule.currentVersion, root: decodeNode(node))
        )
    }

    private static func encodeNode(_ node: SmartRuleNode) -> JSONValue {
        switch node {
        case .all(let children):
            return .object(["type": .string("all"), "children": .array(children.map(encodeNode))])
        case .any(let children):
            return .object(["type": .string("any"), "children": .array(children.map(encodeNode))])
        case .not(let child):
            return .object(["type": .string("not"), "child": encodeNode(child)])
        case .predicate(let predicate):
            return encodePredicate(predicate)
        }
    }

    private static func encodePredicate(_ predicate: SmartPredicate) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("predicate")]
        func values(_ items: some Sequence<String>) -> JSONValue {
            .array(CanonicalOrder.sorted(items).map { .string($0) })
        }
        switch predicate {
        case .sourceIn(let ids):
            fields["field"] = .string("source")
            fields["values"] = values(ids)
        case .inManualCollection(let ids):
            fields["field"] = .string("manualCollection")
            fields["values"] = values(ids)
        case .tagContains(let mode, let tags):
            fields["field"] = .string("tag")
            fields["match"] = .string(mode.rawValue)
            fields["values"] = values(tags)
        case .facetIn(let sourceId, let facetIds):
            fields["field"] = .string("facet")
            fields["sourceId"] = .string(sourceId)
            fields["values"] = values(facetIds)
        case .titleContains(let terms):
            fields["field"] = .string("title")
            fields["values"] = values(terms)
        case .authorContains(let terms):
            fields["field"] = .string("author")
            fields["values"] = values(terms)
        case .statusIn(let statuses):
            fields["field"] = .string("status")
            fields["values"] = values(statuses.map(\.rawValue))
        case .ratingBetween(let minimum, let maximum):
            fields["field"] = .string("rating")
            minimum.map { fields["minimum"] = .double($0) }
            maximum.map { fields["maximum"] = .double($0) }
        case .addedWithinDays(let days):
            fields["field"] = .string("addedWithinDays")
            fields["days"] = .int(Int(days))
        case .lastReadWithinDays(let days):
            fields["field"] = .string("lastReadWithinDays")
            fields["days"] = .int(Int(days))
        case .metadataUpdatedWithinDays(let days):
            fields["field"] = .string("metadataUpdatedWithinDays")
            fields["days"] = .int(Int(days))
        case .progressIn(let states):
            fields["field"] = .string("progress")
            fields["values"] = values(states.map(\.rawValue))
        case .hasUnreadUpdate:
            fields["field"] = .string("hasUnreadUpdate")
        case .hasSourceUpdate:
            fields["field"] = .string("hasSourceUpdate")
        case .isDormantSource:
            fields["field"] = .string("isDormantSource")
        }
        return .object(fields)
    }

    private static func decodeNode(_ value: [String: JSONValue]) throws -> SmartRuleNode {
        guard let type = value.string("type") else { throw ProtocolError.missingField("type") }
        switch type {
        case "all", "any":
            guard value.count == 2, value.hasOnly(["type", "children"]),
                  let children = value.array("children") else {
                throw ProtocolError.unknownField("children")
            }
            let nodes = try children.map { child -> SmartRuleNode in
                guard let object = child.objectValue else { throw ProtocolError.unexpectedJsonType(field: "child") }
                return try decodeNode(object)
            }
            return type == "all" ? .all(nodes) : .any(nodes)
        case "not":
            guard value.count == 2, value.hasOnly(["type", "child"]), let child = value.object("child") else {
                throw ProtocolError.unknownField("child")
            }
            return .not(try decodeNode(child))
        case "predicate":
            return .predicate(try decodePredicate(value))
        default:
            throw ProtocolError.unknownField(type)
        }
    }

    private static func decodePredicate(_ value: [String: JSONValue]) throws -> SmartPredicate {
        guard let field = value.string("field") else { throw ProtocolError.missingField("field") }
        func requireKeys(_ keys: Set<String>) throws {
            guard value.count == keys.count, value.hasOnly(keys) else { throw ProtocolError.unknownField(field) }
        }
        func strings() throws -> Set<String> {
            guard let items = value.array("values") else { throw ProtocolError.missingField("values") }
            return Set(try items.map { item -> String in
                guard let text = item.stringValue else {
                    throw ProtocolError.unexpectedJsonType(field: "values")
                }
                return text
            })
        }
        func days() throws -> Int64 {
            try requireKeys(["type", "field", "days"])
            guard let days = value.int("days") else { throw ProtocolError.missingField("days") }
            return Int64(days)
        }
        switch field {
        case "source":
            try requireKeys(["type", "field", "values"])
            return .sourceIn(try strings())
        case "manualCollection":
            try requireKeys(["type", "field", "values"])
            return .inManualCollection(try strings())
        case "tag":
            try requireKeys(["type", "field", "match", "values"])
            guard let raw = value.string("match"), let mode = MatchMode(rawValue: raw) else {
                throw ProtocolError.missingField("match")
            }
            return .tagContains(mode: mode, tags: try strings())
        case "facet":
            try requireKeys(["type", "field", "sourceId", "values"])
            guard let sourceId = value.string("sourceId") else { throw ProtocolError.missingField("sourceId") }
            return .facetIn(sourceId: sourceId, facetIds: try strings())
        case "title":
            try requireKeys(["type", "field", "values"])
            return .titleContains(try strings())
        case "author":
            try requireKeys(["type", "field", "values"])
            return .authorContains(try strings())
        case "status":
            try requireKeys(["type", "field", "values"])
            return .statusIn(Set(try strings().map { raw in
                guard let status = PublicationStatus(rawValue: raw) else {
                    throw ProtocolError.unknownField(raw)
                }
                return status
            }))
        case "rating":
            guard value.hasOnly(["type", "field", "minimum", "maximum"]) else {
                throw ProtocolError.unknownField(field)
            }
            return .ratingBetween(minimum: value.double("minimum"), maximum: value.double("maximum"))
        case "addedWithinDays":
            return .addedWithinDays(try days())
        case "lastReadWithinDays":
            return .lastReadWithinDays(try days())
        case "metadataUpdatedWithinDays":
            return .metadataUpdatedWithinDays(try days())
        case "progress":
            try requireKeys(["type", "field", "values"])
            return .progressIn(Set(try strings().map { raw in
                guard let state = ProgressState(rawValue: raw) else { throw ProtocolError.unknownField(raw) }
                return state
            }))
        case "hasUnreadUpdate":
            try requireKeys(["type", "field"])
            return .hasUnreadUpdate
        case "hasSourceUpdate":
            try requireKeys(["type", "field"])
            return .hasSourceUpdate
        case "isDormantSource":
            try requireKeys(["type", "field"])
            return .isDormantSource
        default:
            throw ProtocolError.unknownField(field)
        }
    }
}
