// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import XCTest
@testable import TsuyomiReader

@MainActor
final class ReaderTextLayoutTests: XCTestCase {
    private func document(paragraphs: Int = 40) throws -> ReaderDocument {
        var blocks: [ReaderBlock] = [
            .heading(try ReaderBlock.Heading(blockId: "h0", text: "第一章 雾中的灯塔", level: 1))
        ]
        for index in 0..<paragraphs {
            blocks.append(
                .paragraph(
                    try ReaderBlock.Paragraph(
                        blockId: "p\(index)",
                        text: String(repeating: "清晨的海雾漫过石阶，灯塔只剩一圈微光。", count: 3)
                    )
                )
            )
        }
        return try ReaderDocument(
            kind: .chapter,
            identity: try DocumentIdentity(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1234",
                contentId: "10001"
            ),
            title: "第一章",
            revision: "r1",
            contentDigest: ReaderDocument.contentDigest(of: blocks),
            blocks: blocks
        )
    }

    func testPagesPartitionExactlyTheLaidOutText() throws {
        let layout = try ReaderTextLayout(document: try document(), settings: ReaderSettings())
        try layout.layout(width: 390, height: 600, settings: ReaderSettings())

        XCTAssertGreaterThan(layout.pages.count, 1)
        let storageLength = try XCTUnwrap(layout.contentStorage.textStorage?.length)
        XCTAssertEqual(layout.pages.first?.location, 0)
        for (index, page) in layout.pages.enumerated() {
            XCTAssertEqual(page.index, index)
            if index > 0 {
                let previous = layout.pages[index - 1]
                XCTAssertEqual(previous.location + previous.length, page.location, "pages must not overlap or gap")
            }
        }
        let last = try XCTUnwrap(layout.pages.last)
        XCTAssertEqual(last.location + last.length, storageLength)
    }

    func testEveryPageFitsTheViewportExceptWhenOneFragmentCannot() throws {
        let height: CGFloat = 480
        let layout = try ReaderTextLayout(document: try document(), settings: ReaderSettings())
        try layout.layout(width: 390, height: height, settings: ReaderSettings())
        for page in layout.pages.dropLast() {
            XCTAssertLessThanOrEqual(page.height, Double(height) + 0.5)
        }
    }

    func testAPositionSurvivesAFontSizeChange() throws {
        let settings = ReaderSettings()
        let layout = try ReaderTextLayout(document: try document(), settings: settings)
        let firstKey = try layout.layout(width: 390, height: 600, settings: settings)
        let before = try XCTUnwrap(layout.page(forBlockIndex: 20, characterOffset: 5))
        XCTAssertNotNil(layout.position(atPageIndex: before.index))

        var larger = settings
        larger.fontSize = 24
        let secondKey = try layout.layout(width: 390, height: 600, settings: larger)
        XCTAssertNotEqual(firstKey, secondKey)

        // The same semantic position still resolves, on a page the new plan actually contains.
        let after = try XCTUnwrap(layout.page(forBlockIndex: 20, characterOffset: 5))
        XCTAssertTrue(layout.pages.contains(after))
        let position = try XCTUnwrap(layout.position(atPageIndex: after.index))
        XCTAssertLessThanOrEqual(position.blockIndex, 20)
    }

    func testAColourOnlyChangeKeepsTheLayoutKey() throws {
        var settings = ReaderSettings()
        let first = try ReaderTextLayout.key(settings: settings, width: 390)
        settings.theme = .nightInk
        let second = try ReaderTextLayout.key(settings: settings, width: 390)
        XCTAssertEqual(first, second)

        settings.fontSize = 22
        let third = try ReaderTextLayout.key(settings: settings, width: 390)
        XCTAssertNotEqual(second, third)
    }

    func testCodePointOffsetsSurviveAstralCharacters() throws {
        let blocks: [ReaderBlock] = [
            .paragraph(try ReaderBlock.Paragraph(blockId: "p0", text: "𝄞𝄞𝄞 音符 𝄞𝄞"))
        ]
        let document = try ReaderDocument(
            kind: .chapter,
            identity: try DocumentIdentity(
                sourceId: "org.tsuyomi.wenku8",
                remoteBookId: "1234",
                contentId: "10001"
            ),
            title: "音符",
            revision: "r1",
            contentDigest: ReaderDocument.contentDigest(of: blocks),
            blocks: blocks
        )
        let layout = try ReaderTextLayout(document: document, settings: ReaderSettings())
        try layout.layout(width: 390, height: 600, settings: ReaderSettings())
        let position = try XCTUnwrap(layout.position(atPageIndex: 0))
        XCTAssertEqual(position.blockIndex, 0)
        XCTAssertEqual(position.characterOffset, 0)
    }
}
