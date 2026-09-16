// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// One hit in the local shelf search: a collection or a book, never a source result.
public enum LibrarySearchHit: Hashable, Sendable, Identifiable {
    case collection(LibraryCollection)
    case book(LibraryEntry)

    public var id: String {
        switch self {
        case .collection(let collection): return "collection:\(collection.collectionId)"
        case .book(let entry): return "book:\(entry.book.identity.sourceId):\(entry.book.identity.remoteBookId)"
        }
    }
}

/// Zero-network search over what the shelf already holds. Matching is by normalised substring;
/// the normalisation is the same on both sides, so what the reader types is what is compared.
public enum LibrarySearch {
    public static let maximumQueryLength = 100
    public static let recommendationCount = 6

    /// NFKC, lowercase, trimmed, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Collections first, then books, each in normalised-title order. A blank query returns nothing;
    /// blank queries get recommendations instead.
    public static func search(
        _ query: String,
        books: [LibraryEntry],
        collections: [LibraryCollection]
    ) -> [LibrarySearchHit] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        let matchedCollections = collections
            .filter { $0.kind == .manual || $0.kind == .smart }
            .filter { normalize($0.title).contains(needle) }
            .sorted { CanonicalOrder.precedes(normalize($0.title), normalize($1.title)) }
        let matchedBooks = books
            .filter { entry in
                let fields = [entry.book.title] + Array(entry.book.authors) + entry.localTags + Array(entry.book.remoteTags)
                return fields.contains { normalize($0).contains(needle) }
            }
            .sorted { CanonicalOrder.precedes(normalize($0.book.title), normalize($1.book.title)) }
        return matchedCollections.map(LibrarySearchHit.collection) + matchedBooks.map(LibrarySearchHit.book)
    }

    /// What an empty field offers: the books most recently read, then most recently added, and the
    /// collections in their shelf order. Books come first here because they are what is reopened.
    public static func recommendations(
        books: [LibraryEntry],
        collections: [LibraryCollection]
    ) -> [LibrarySearchHit] {
        let recentBooks = books.sorted { lhs, rhs in
            if (lhs.progress != nil) != (rhs.progress != nil) { return lhs.progress != nil }
            let left = lhs.progress?.updatedAt ?? lhs.libraryAddedAt
            let right = rhs.progress?.updatedAt ?? rhs.libraryAddedAt
            if left != right { return left > right }
            if lhs.libraryAddedAt != rhs.libraryAddedAt { return lhs.libraryAddedAt > rhs.libraryAddedAt }
            return CanonicalOrder.precedes(lhs.book.title, rhs.book.title)
        }.prefix(recommendationCount)
        let orderedCollections = collections
            .filter { $0.kind == .manual || $0.kind == .smart }
            .sorted { lhs, rhs in
                if lhs.displayOrder != rhs.displayOrder { return lhs.displayOrder < rhs.displayOrder }
                return CanonicalOrder.precedes(lhs.title, rhs.title)
            }
            .prefix(recommendationCount)
        return recentBooks.map(LibrarySearchHit.book) + orderedCollections.map(LibrarySearchHit.collection)
    }
}
