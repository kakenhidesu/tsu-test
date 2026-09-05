// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

public struct SourceFlowSnapshot: Hashable, Sendable {
    public let book: SourceBookSummary
    public let chapter: SourceChapter?
}

/// The non-secret navigation target the app returns to after a relaunch. Content, cookies and
/// progress stay in their own stores; this holds only what a route needs to be rebuilt.
public final class SourceFlowSnapshotStore {
    private enum Key {
        static let sourceId = "source_flow_source_id"
        static let remoteBookId = "source_flow_remote_book_id"
        static let bookTitle = "source_flow_book_title"
        static let bookAuthor = "source_flow_book_author"
        static let coverUrl = "source_flow_cover_url"
        static let canonicalUrl = "source_flow_canonical_url"
        static let chapterId = "source_flow_chapter_id"
        static let chapterTitle = "source_flow_chapter_title"
        static let chapterUrl = "source_flow_chapter_url"
    }

    let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func save(book: SourceBookSummary) {
        defaults.set(book.identity.sourceId, forKey: Key.sourceId)
        defaults.set(book.identity.remoteBookId, forKey: Key.remoteBookId)
        defaults.set(book.title, forKey: Key.bookTitle)
        defaults.set(book.canonicalUrl, forKey: Key.canonicalUrl)
        set(book.author, forKey: Key.bookAuthor)
        set(book.coverUrl, forKey: Key.coverUrl)
        for key in [Key.chapterId, Key.chapterTitle, Key.chapterUrl] {
            defaults.removeObject(forKey: key)
        }
    }

    public func save(chapter: SourceChapter) {
        defaults.set(chapter.chapterId, forKey: Key.chapterId)
        defaults.set(chapter.title, forKey: Key.chapterTitle)
        defaults.set(chapter.url, forKey: Key.chapterUrl)
    }

    public func read(sourceId: String) -> SourceFlowSnapshot? {
        guard defaults.string(forKey: Key.sourceId) == sourceId,
              let remoteBookId = defaults.string(forKey: Key.remoteBookId),
              let title = defaults.string(forKey: Key.bookTitle),
              let canonicalUrl = defaults.string(forKey: Key.canonicalUrl),
              let identity = try? BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId),
              let book = try? SourceBookSummary(
                  identity: identity,
                  title: title,
                  author: defaults.string(forKey: Key.bookAuthor),
                  coverUrl: defaults.string(forKey: Key.coverUrl),
                  canonicalUrl: canonicalUrl
              )
        else { return nil }
        guard let chapterId = defaults.string(forKey: Key.chapterId) else {
            return SourceFlowSnapshot(book: book, chapter: nil)
        }
        guard let chapterTitle = defaults.string(forKey: Key.chapterTitle),
              let chapterUrl = defaults.string(forKey: Key.chapterUrl),
              let chapter = try? SourceChapter(chapterId: chapterId, title: chapterTitle, url: chapterUrl)
        else { return nil }
        return SourceFlowSnapshot(book: book, chapter: chapter)
    }

    private func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

extension SourceFlowSnapshotStore {
    private static let targetKey = "source_flow_restoration_target"

    public func save(target: SourceRestorationTarget?) {
        if let target {
            defaults.set(target.rawValue, forKey: SourceFlowSnapshotStore.targetKey)
        } else {
            defaults.removeObject(forKey: SourceFlowSnapshotStore.targetKey)
        }
    }

    public func readTarget() -> SourceRestorationTarget? {
        defaults.string(forKey: SourceFlowSnapshotStore.targetKey)
            .flatMap(SourceRestorationTarget.init(rawValue:))
    }
}
