// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import TsuyomiProtocol

final class SmartRuleTests: XCTestCase {
    func testCodecRoundTripsEveryPredicate() throws {
        let predicates: [SmartPredicate] = [
            .sourceIn(["org.tsuyomi.wenku8"]),
            .inManualCollection(["c1", "c2"]),
            .tagContains(mode: .all, tags: ["a", "b"]),
            .facetIn(sourceId: "org.tsuyomi.wenku8", facetIds: ["f1"]),
            .titleContains(["title"]),
            .authorContains(["author"]),
            .statusIn([.ongoing, .completed]),
            .ratingBetween(minimum: 1.0, maximum: 4.5),
            .addedWithinDays(30),
            .lastReadWithinDays(7),
            .metadataUpdatedWithinDays(1),
            .progressIn([.reading]),
            .hasUnreadUpdate,
            .hasSourceUpdate,
            .isDormantSource
        ]
        let rule = try SmartRule(root: .all(predicates.map { .predicate($0) }))
        XCTAssertEqual(try SmartRuleCodec.decode(try SmartRuleCodec.encode(rule)), rule)
    }

    func testNestedGroupsAndNegationRoundTrip() throws {
        let rule = try SmartRule(
            root: .any([
                .not(.predicate(.hasUnreadUpdate)),
                .all([.predicate(.titleContains(["x"])), .predicate(.ratingBetween(minimum: nil, maximum: 3))])
            ])
        )
        XCTAssertEqual(try SmartRuleCodec.decode(try SmartRuleCodec.encode(rule)), rule)
    }

    func testValidatorViolationCodes() throws {
        XCTAssertEqual(
            SmartRuleValidator.validate(try SmartRule(root: .all([]))).map(\.code),
            ["empty-group"]
        )
        XCTAssertEqual(
            SmartRuleValidator.validate(try SmartRule(root: .predicate(.sourceIn([])))).map(\.code),
            ["invalid-term-count"]
        )
        XCTAssertEqual(
            SmartRuleValidator.validate(
                try SmartRule(root: .predicate(.ratingBetween(minimum: 4, maximum: 1)))
            ).map(\.code),
            ["invalid-rating-range"]
        )
        XCTAssertEqual(
            SmartRuleValidator.validate(
                try SmartRule(root: .predicate(.addedWithinDays(SmartRule.maximumWindowDays + 1)))
            ).map(\.code),
            ["invalid-time-window"]
        )
        XCTAssertEqual(
            SmartRuleValidator.validate(
                try SmartRule(root: .predicate(.titleContains([String(repeating: "x", count: 257)])))
            ).map(\.code),
            ["invalid-text-length"]
        )
    }

    func testDepthAndNodeLimitsAreEnforced() throws {
        var deep = SmartRuleNode.predicate(.hasUnreadUpdate)
        for _ in 0..<SmartRule.maximumDepth { deep = .not(deep) }
        XCTAssertTrue(SmartRuleValidator.validate(try SmartRule(root: deep)).contains { $0.code == "max-depth" })

        let wide = SmartRuleNode.all(
            (0..<SmartRule.maximumNodes).map { _ in SmartRuleNode.predicate(.hasUnreadUpdate) }
        )
        XCTAssertTrue(SmartRuleValidator.validate(try SmartRule(root: wide)).contains { $0.code == "max-nodes" })
    }

    func testHikariTranslatorMapsAndRejects() throws {
        guard case .compatible(let rule) = HikariSmartRuleTranslator.translate(
            matchAll: true,
            conditions: [
                HikariSmartCondition(field: "tag", values: ["a"], matchAll: true),
                HikariSmartCondition(field: "unread", excluded: true)
            ]
        ) else { return XCTFail("expected a compatible rule") }
        XCTAssertEqual(
            rule.root,
            .all([.predicate(.tagContains(mode: .all, tags: ["a"])), .not(.predicate(.hasUnreadUpdate))])
        )

        XCTAssertEqual(
            HikariSmartRuleTranslator.translate(matchAll: true, conditions: []),
            .disabledDraft(warningCode: "empty-smart-rule")
        )
        XCTAssertEqual(
            HikariSmartRuleTranslator.translate(
                matchAll: true,
                conditions: [HikariSmartCondition(field: "subscription")]
            ),
            .disabledDraft(warningCode: "unsupported-smart-condition")
        )
        XCTAssertEqual(
            HikariSmartRuleTranslator.translate(
                matchAll: true,
                conditions: [HikariSmartCondition(field: "nonsense")]
            ),
            .disabledDraft(warningCode: "unknown-smart-condition")
        )
        XCTAssertEqual(
            HikariSmartRuleTranslator.translate(
                matchAll: true,
                conditions: [HikariSmartCondition(field: "added")]
            ),
            .disabledDraft(warningCode: "invalid-smart-window")
        )
    }

    func testCodecRejectsUnknownNodesAndFields() {
        XCTAssertThrowsError(try SmartRuleCodec.decode(#"{"version":2,"rule":{"type":"all","children":[]}}"#))
        XCTAssertThrowsError(try SmartRuleCodec.decode(#"{"version":1,"rule":{"type":"nope"}}"#))
        XCTAssertThrowsError(
            try SmartRuleCodec.decode(#"{"version":1,"rule":{"type":"predicate","field":"source"}}"#)
        )
        XCTAssertThrowsError(
            try SmartRuleCodec.decode(
                #"{"version":1,"rule":{"type":"predicate","field":"hasUnreadUpdate","extra":1}}"#
            )
        )
    }
}
