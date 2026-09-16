// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
@testable import LibraryFeature
import TsuyomiCore
import TsuyomiProtocol
import XCTest

/// The shelf's smart order and its local search are pure functions over what is stored.
final class LibraryProjectionTests: XCTestCase {
    private func entry(
        _ remoteBookId: String,
        title: String,
        authors: Set<String> = [],
        tags: [String] = [],
        addedAt: TimeInterval = 0,
        readAt: TimeInterval? = nil
    ) throws -> LibraryEntry {
        let identity = try BookIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: remoteBookId)
        let book = LibraryBook(
            identity: identity, title: title, addedAt: Date(timeIntervalSince1970: addedAt),
            metadataUpdatedAt: Date(timeIntervalSince1970: addedAt), authors: authors, remoteTags: ["奇幻"]
        )
        var progress: ReadingProgress?
        if let readAt {
            progress = try ReadingProgress(
                identity: identity,
                locator: try ReaderLocator(
                    document: try DocumentIdentity(sourceId: "org.tsuyomi.wenku8", remoteBookId: remoteBookId, contentId: "c1"),
                    chapterProgress: 0.5, bookProgress: 0.5, capturedAt: Date(timeIntervalSince1970: readAt)
                ),
                updatedAt: Date(timeIntervalSince1970: readAt)
            )
        }
        return try LibraryEntry(
            book: book, libraryAddedAt: Date(timeIntervalSince1970: addedAt), rating: nil, localTags: tags,
            sourceAvailable: true, reconciliation: nil, progress: progress
        )
    }

    private func update(_ entry: LibraryEntry, date: String?, detectedAt: TimeInterval) -> UnresolvedUpdate {
        UnresolvedUpdate(
            identity: entry.book.identity, title: entry.book.title, anchor: "a", chapters: [],
            newChapterIds: ["n"], lastUpdatedDate: date, detectedAt: Date(timeIntervalSince1970: detectedAt), revision: 1
        )
    }

    func testSmartOrderPromotesUpdatedBooksByRecentReadingThenDateThenDetection() throws {
        let readRecently = try entry("1", title: "甲", addedAt: 1, readAt: 500)
        let newestDate = try entry("2", title: "乙", addedAt: 2)
        let olderDate = try entry("3", title: "丙", addedAt: 3)
        let detectedLater = try entry("4", title: "丁", addedAt: 4)
        let untouched = try entry("5", title: "戊", addedAt: 5, readAt: 900)
        let updates = Dictionary(uniqueKeysWithValues: [
            (readRecently.book.identity, update(readRecently, date: "2026-01-01", detectedAt: 10)),
            (newestDate.book.identity, update(newestDate, date: "2026-09-01", detectedAt: 10)),
            (olderDate.book.identity, update(olderDate, date: "2026-03-01", detectedAt: 50)),
            (detectedLater.book.identity, update(detectedLater, date: "2026-03-01", detectedAt: 90))
        ])
        let ordered = LibraryProjection.apply(
            [untouched, detectedLater, olderDate, newestDate, readRecently],
            filter: .all, sort: .smart, descending: false, updates: updates
        )
        XCTAssertEqual(ordered.map(\.book.identity.remoteBookId), ["1", "2", "4", "3", "5"])

        let explicit = LibraryProjection.apply(
            [untouched, detectedLater, olderDate, newestDate, readRecently],
            filter: .all, sort: .title, descending: false, updates: updates
        )
        XCTAssertEqual(explicit.map(\.book.identity.remoteBookId), ["1", "2", "3", "4", "5"], "an explicit sort never partitions")
    }

    func testSearchNormalisesAndOrdersCollectionsBeforeBooks() throws {
        let books = [
            try entry("1", title: "雾港纪事", authors: ["林川"]),
            try entry("2", title: "星环邮差", tags: ["科幻 太空"]),
            try entry("3", title: "Ａｌｐｈａ Ｂｅｔａ")
        ]
        let collections = [
            try LibraryCollection(collectionId: "c1", kind: .manual, title: "科幻精选", parentCollectionId: nil, displayOrder: 1),
            try LibraryCollection(collectionId: "c2", kind: .subscription, title: "科幻订阅", parentCollectionId: nil, displayOrder: 0)
        ]
        XCTAssertEqual(LibrarySearch.normalize("  Ａｌｐｈａ   BETA "), "alpha beta")
        let hits = LibrarySearch.search("科幻", books: books, collections: collections)
        XCTAssertEqual(hits.map(\.id), ["collection:c1", "book:org.tsuyomi.wenku8:2"], "subscriptions are not offered")
        XCTAssertEqual(LibrarySearch.search("alpha beta", books: books, collections: collections).map(\.id), ["book:org.tsuyomi.wenku8:3"])
        XCTAssertEqual(LibrarySearch.search("林川", books: books, collections: collections).count, 1)
        XCTAssertTrue(LibrarySearch.search("   ", books: books, collections: collections).isEmpty)
    }

    func testRecommendationsPreferRecentlyReadThenRecentlyAdded() throws {
        let books = [
            try entry("1", title: "旧", addedAt: 10),
            try entry("2", title: "读过", addedAt: 5, readAt: 100),
            try entry("3", title: "新", addedAt: 20)
        ]
        let hits = LibrarySearch.recommendations(books: books, collections: [])
        XCTAssertEqual(hits.map(\.id), ["book:org.tsuyomi.wenku8:2", "book:org.tsuyomi.wenku8:3", "book:org.tsuyomi.wenku8:1"])
    }

    func testEachTabRestoresItsOwnPresentation() {
        XCTAssertEqual(LibraryTab.all.defaultPresentation.sortMode, "smart")
        XCTAssertEqual(LibraryTab.continueReading.defaultPresentation.sortMode, "recent")
        XCTAssertTrue(LibraryTab.continueReading.defaultPresentation.sortDescending)
        XCTAssertEqual(LibraryTab.readLater.defaultPresentation.sortMode, "added")
        XCTAssertEqual(LibraryShortcut(id: "mirror:org.tsuyomi.wenku8"), .mirror("org.tsuyomi.wenku8"))
    }
}
