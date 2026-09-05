// SPDX-License-Identifier: AGPL-3.0-only

import BookFeature
import Foundation
import os
import ReaderFeature
import SearchFeature
import TsuyomiCore
import TsuyomiProtocol
import TsuyomiSource
import TsuyomiUI
import XCTest

/// The M3 journey: search, open a book, read a chapter, leave, come back. Every byte comes from the
/// sanitized acceptance fixtures through a fake transport; no test may reach a real site.
final class SourceJourneyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testSearchToReaderKeepsSemanticProgress() async throws {
        let world = try await FixtureWorld(directory: directory)

        let search = SearchModel(
            sourceId: world.sourceId,
            registry: world.registry,
            library: world.library
        )
        search.query = "雾港"
        await search.submit()
        guard case .content(let results) = search.state else {
            return XCTFail("search did not produce results: \(search.state)")
        }
        XCTAssertFalse(results.isStaleOffline)
        XCTAssertEqual(results.items.first?.identity.remoteBookId, "1234")
        let identity = try XCTUnwrap(results.items.first?.identity)
        let history = try await world.library.searchHistory(sourceId: world.sourceId.value)
        XCTAssertEqual(history, ["雾港"])

        let book = BookModel(
            identity: identity,
            registry: world.registry,
            library: world.library,
            progressStore: world.progress
        )
        await book.load()
        guard case .content(let detail) = book.state else {
            return XCTFail("detail did not load: \(book.state)")
        }
        XCTAssertEqual(detail.detail.summary.title, "雾港纪事")
        XCTAssertEqual(detail.chapters.map(\.chapterId), ["10001", "10002"])
        XCTAssertFalse(detail.inLibrary)

        await book.addToLibrary()
        guard case .content(let added) = book.state else { return XCTFail("shelf write lost the page") }
        XCTAssertTrue(added.inLibrary)
        XCTAssertEqual(world.transport.remoteWriteCount, 0, "加入书架 must never write remotely")

        let reader = ReaderModel(
            identity: identity,
            bookTitle: detail.detail.summary.title,
            startChapterId: "10001",
            settings: ReaderSettings(),
            registry: world.registry,
            progressStore: world.progress
        )
        await reader.open()
        reader.resize(CGSize(width: 320, height: 480))
        guard case .content(let opened) = reader.state else {
            return XCTFail("chapter did not load: \(reader.state)")
        }
        XCTAssertEqual(opened.chapterTitle, "第一章 雾中的灯塔")
        XCTAssertGreaterThan(opened.pageCount, 0)
        XCTAssertTrue(opened.hasNext)
        XCTAssertFalse(opened.hasPrevious)

        await reader.flush()
        let saved = try await world.progress.progress(identity)
        let stored = try XCTUnwrap(saved)
        XCTAssertEqual(stored.locator.document.contentId, "10001")
        XCTAssertNotNil(stored.locator.blockId)
        XCTAssertNotNil(stored.locator.textAnchorDigest)

        await reader.openAdjacent(1)
        XCTAssertEqual(reader.chapter?.chapterId, "10002")
        await reader.flush()
        let latest = try await world.progress.progress(identity)
        let advanced = try XCTUnwrap(latest)
        XCTAssertEqual(advanced.locator.document.contentId, "10002")

        let reopened = BookModel(
            identity: identity,
            registry: world.registry,
            library: world.library,
            progressStore: world.progress
        )
        await reopened.load()
        guard case .content(let resumed) = reopened.state else {
            return XCTFail("detail did not reload: \(reopened.state)")
        }
        XCTAssertEqual(resumed.resumeChapterId, "10002")
        XCTAssertEqual(resumed.readChapterIds, ["10001"])
        XCTAssertTrue(resumed.inLibrary)
    }

    @MainActor
    func testChallengePageStopsTheJourneyWithoutLeakingHtml() async throws {
        let world = try await FixtureWorld(directory: directory, page: "challenge")
        let search = SearchModel(
            sourceId: world.sourceId,
            registry: world.registry,
            library: world.library
        )
        search.query = "雾港"
        await search.submit()
        guard case .failed(let code, _) = search.state else {
            return XCTFail("a challenge page must not look like a result: \(search.state)")
        }
        XCTAssertFalse(code.contains("<"))
        XCTAssertFalse(code.contains("wenku8"))
    }
}

/// One installed fixture source backed by a fake transport that answers from the fixture files.
@MainActor
private struct FixtureWorld {
    let sourceId: SourceId
    let registry: SourceRegistry
    let library: LibraryRepository
    let progress: ReadingProgressStore
    let transport: FixtureTransport

    init(directory: URL, page: String? = nil) async throws {
        sourceId = try SourceId("org.tsuyomi.wenku8")
        transport = FixtureTransport(forcedPage: page)
        let roots = try StorageRoots(base: directory)
        let database = try TsuyomiDatabase(path: directory.appendingPathComponent("t.sqlite").path)
        library = LibraryRepository(database: database)
        progress = ReadingProgressStore(database: database)
        #if DEBUG
        let keys = InMemoryPublisherKeyStore(keys: [try Phase2TestPublisher.key()])
        #else
        throw XCTSkip("The fixture publisher is only compiled into DEBUG builds")
        #endif
        let store = InstalledExtensionStore(
            files: try QuotaFileStore(
                roots: roots,
                root: .extensions,
                namespace: "installed-extensions",
                quota: StorageQuota(maximumBytes: 64 * 1024 * 1024, maximumEntries: 64)
            )
        )
        let installer = ExtensionInstaller(
            verifier: HxpArchiveVerifier(publisherKeys: keys, hostApiVersion: try SemanticVersion("1.1.0")),
            store: store
        )
        let prepared = try await installer.prepare(
            archiveBytes: try JourneyFixtures.data("wenku8-fixture.hxp")
        )
        try await installer.activate(prepared, approval: ExtensionInstallApproval.approve(prepared))
        registry = SourceRegistry(
            installer: installer,
            store: store,
            gateway: HostNetworkGateway(transport: transport)
        )
    }
}

/// Answers every request from a fixture chosen by the request URL, and counts anything that would be
/// a remote write.
final class FixtureTransport: HostHttpTransport {
    private let forcedPage: String?
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    init(forcedPage: String?) {
        self.forcedPage = forcedPage
    }

    var remoteWriteCount: Int { writes.withLock { $0 } }

    func execute(_ request: HostHttpRequest) async throws -> HostHttpResponse {
        if request.method != .get { writes.withLock { $0 += 1 } }
        let name = forcedPage ?? FixtureTransport.page(for: request.url.absoluteString)
        return HostHttpResponse(
            status: 200,
            finalUrl: request.url,
            headers: ["content-type": "text/html; charset=gb18030"],
            bytes: try JourneyFixtures.encoded(name)
        )
    }

    /// The fixture source builds a directory request and a chapter request against the same path;
    /// only the chapter carries a chapter id.
    private static func page(for url: String) -> String {
        if url.contains("search.php") { return "search" }
        if url.contains("cid=") { return "chapter" }
        if url.contains("reader.php") { return "directory" }
        return "detail"
    }
}

enum JourneyFixtures {
    private static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url
            .appendingPathComponent("Tsuyomi-main")
            .appendingPathComponent("tsuyomi-extensions")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("wenku8")
    }()

    static func data(_ name: String) throws -> Data {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Missing fixture \(name); check out Tsuyomi-main next to this repository")
        }
        return try Data(contentsOf: url)
    }

    /// Fixtures are stored as UTF-8; the source declares `gb18030`, so the fake transport returns the
    /// bytes the real site would send.
    static func encoded(_ name: String) throws -> Data {
        let utf8 = try data("\(name).html")
        guard let text = String(data: utf8, encoding: .utf8),
              let encoded = text.data(
                  using: String.Encoding(
                      rawValue: CFStringConvertEncodingToNSStringEncoding(
                          CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                      )
                  )
              ) else {
            throw XCTSkip("Cannot re-encode fixture \(name)")
        }
        return encoded
    }
}
