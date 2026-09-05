// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol
import XCTest
@testable import TsuyomiSource

/// Replays the sanitized acceptance fixtures through the real signed extension. The field values
/// asserted here are the ones `tsuyomi-extensions/test/wenku8.test.mjs` asserts on the other host.
final class Wenku8ReplayTests: XCTestCase {
    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// Fixtures are stored as UTF-8; the source declares `gb18030`, so the bytes the transport
    /// returns are re-encoded to match what the real site would send.
    private func fixtureBytes(_ name: String) throws -> Data {
        let utf8 = try ExtensionFixtures.data("fixtures/wenku8/\(name).html")
        guard let text = String(data: utf8, encoding: .utf8),
              let encoded = text.data(using: Wenku8ReplayTests.gb18030) else {
            throw XCTSkip("Cannot re-encode fixture \(name)")
        }
        return encoded
    }

    private func client(_ responder: @escaping @Sendable (HostHttpRequest) throws -> HostHttpResponse) async throws
        -> SourceExtensionClient {
        #if DEBUG
        let keys = InMemoryPublisherKeyStore(keys: [try Phase2TestPublisher.key()])
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
        let verifier = HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try SemanticVersion("1.1.0"))
        let verified = try verifier.verify(
            archiveBytes: try ExtensionFixtures.data("fixtures/wenku8/wenku8-fixture.hxp")
        )
        return try await SourceExtensionClient.open(
            packageInfo: verified,
            gateway: HostNetworkGateway(transport: RecordingTransport(responder: responder))
        )
    }

    private func serving(_ name: String) async throws -> SourceExtensionClient {
        let bytes = try fixtureBytes(name)
        return try await client { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["content-type": "text/html; charset=gb18030"],
                bytes: bytes
            )
        }
    }

    func testSearchProducesStableIdentities() async throws {
        let client = try await serving("search")
        defer { Task { await client.close() } }
        let items = try await client.search(query: "雾港")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].identity.sourceId, "org.tsuyomi.wenku8")
        XCTAssertEqual(items[0].identity.remoteBookId, "1234")
        XCTAssertEqual(items[0].title, "雾港纪事")
        XCTAssertEqual(items[0].author, "林川")
        XCTAssertEqual(items[0].coverUrl, "https://pic.wenku8.com/files/article/image/12/1234/1234s.jpg")
        XCTAssertEqual(items[0].canonicalUrl, "https://www.wenku8.net/book/1234.htm")
        XCTAssertEqual(items[1].identity.remoteBookId, "5678")
        XCTAssertEqual(items[1].title, "星环邮差")
        XCTAssertEqual(items[1].author, "苏遥")
    }

    func testDetailExposesNoRawHtml() async throws {
        let client = try await serving("detail")
        defer { Task { await client.close() } }
        let detail = try await client.detail(remoteBookId: "1234")
        XCTAssertEqual(detail.summary.title, "雾港纪事")
        XCTAssertEqual(detail.summary.author, "林川")
        XCTAssertEqual(detail.description, "一名邮差在雾港追寻遗失的航线。此文本为测试用虚构简介。")
        XCTAssertEqual(detail.tags, ["奇幻", "冒险"])
        XCTAssertEqual(detail.status, "连载中")
        XCTAssertEqual(detail.summary.coverUrl, "https://pic.wenku8.com/files/article/image/12/1234/1234.jpg")
    }

    func testDirectoryPreservesOrderAndVolumeTitles() async throws {
        let client = try await serving("directory")
        defer { Task { await client.close() } }
        let directory = try await client.directory(remoteBookId: "1234")
        XCTAssertEqual(directory.bookIdentity.remoteBookId, "1234")
        XCTAssertEqual(directory.chapters.map(\.chapterId), ["10001", "10002"])
        XCTAssertEqual(directory.chapters.map(\.title), ["第一章 雾中的灯塔", "第二章 旧船票"])
        XCTAssertEqual(
            directory.chapters[0].url,
            "https://www.wenku8.net/modules/article/reader.php?aid=1234&cid=10001"
        )
        XCTAssertEqual(directory.chapters.map(\.volumeTitle), ["第一卷", "第一卷"])
    }

    func testChapterEmitsOrderedParagraphsWithoutNavigationChrome() async throws {
        let client = try await serving("chapter")
        defer { Task { await client.close() } }
        let chapter = try SourceChapter(
            chapterId: "10001",
            title: "第一章 雾中的灯塔",
            url: "https://www.wenku8.net/modules/article/reader.php?aid=1234&cid=10001"
        )
        let document = try await client.chapter(chapter, remoteBookId: "1234")
        XCTAssertEqual(document.identity.contentId, "10001")
        XCTAssertEqual(document.title, "第一章 雾中的灯塔")
        XCTAssertEqual(document.blocks.map(\.blockId), ["p-0001", "p-0002"])
        guard case .paragraph(let first) = document.blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(first.text, "清晨的海雾漫过石阶，灯塔只剩一圈微光。")
        guard case .paragraph(let second) = document.blocks[1] else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(second.text, "邮差把未署名的信收入防水袋，沿着旧轨道继续前行。")
        XCTAssertTrue(Grammar.isSha256(document.contentDigest))
    }

    func testChallengePageBecomesATypedVerificationFailure() async throws {
        let client = try await serving("challenge")
        defer { Task { await client.close() } }
        do {
            _ = try await client.search(query: "雾港")
            XCTFail("expected a typed source failure for the challenge page")
        } catch let failure as SourceException {
            XCTAssertTrue(
                [.verificationRequired, .sessionRequired, .malformedSourceResponse].contains(failure.code)
            )
            XCTAssertFalse(failure.diagnostic.safeCode.contains("<"))
        }
    }

    func testRemoteLibraryReadIsPurelyLocalOnTheHostSide() async throws {
        let bytes = try fixtureBytes("remote-library-page-1")
        let transport = RecordingTransport { request in
            HostHttpResponse(
                status: 200,
                finalUrl: request.url,
                headers: ["content-type": "text/html; charset=gb18030"],
                bytes: bytes
            )
        }
        #if DEBUG
        let keys = InMemoryPublisherKeyStore(keys: [try Phase2TestPublisher.key()])
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
        let verifier = HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try SemanticVersion("1.1.0"))
        let verified = try verifier.verify(
            archiveBytes: try ExtensionFixtures.data("fixtures/wenku8/wenku8-fixture.hxp")
        )
        let client = try await SourceExtensionClient.open(
            packageInfo: verified,
            gateway: HostNetworkGateway(transport: transport)
        )
        defer { Task { await client.close() } }

        let page = try await client.listRemoteLibrary(cursor: nil)
        XCTAssertFalse(page.items.isEmpty)
        let recorded = await transport.requests()
        XCTAssertTrue(recorded.allSatisfy { $0.method == .get })
        XCTAssertTrue(recorded.allSatisfy { $0.body == nil })
    }
}
