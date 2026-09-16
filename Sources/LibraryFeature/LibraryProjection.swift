// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// The shelf's own views over its entries. `unread` was retired with the update inbox: an update
/// is a detected fact in `unresolved_updates`, not a flag on the book.
public enum SystemLibraryFilter: String, Sendable, CaseIterable, Hashable {
    case all
    case continueReading
    case readLater
    case dormant

    public var title: String {
        switch self {
        case .all: return "全部"
        case .continueReading: return "继续阅读"
        case .readLater: return "稍后再读"
        case .dormant: return "来源休眠"
        }
    }

    func accepts(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: return true
        case .continueReading:
            guard let progress = entry.progress else { return false }
            guard let bookProgress = progress.locator.bookProgress else { return true }
            return bookProgress < 1.0
        case .readLater: return entry.readLater
        case .dormant: return !entry.sourceAvailable
        }
    }
}

/// The three fixed tabs at the shelf root. Each keeps its own layout and sort.
public enum LibraryTab: String, Sendable, CaseIterable, Hashable {
    case all
    case continueReading
    case readLater

    public var title: String { filter.title }

    public var filter: SystemLibraryFilter {
        switch self {
        case .all: return .all
        case .continueReading: return .continueReading
        case .readLater: return .readLater
        }
    }

    public var defaultPresentation: LibraryTabPresentation {
        switch self {
        case .all: return LibraryTabPresentation(layout: "grid", sortMode: "smart", sortDescending: false)
        case .continueReading: return LibraryTabPresentation(layout: "grid", sortMode: "recent", sortDescending: true)
        case .readLater: return LibraryTabPresentation(layout: "grid", sortMode: "added", sortDescending: true)
        }
    }
}

public enum LibraryLayout: String, Sendable, CaseIterable, Hashable {
    case grid
    case list

    public var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        }
    }

    public var next: LibraryLayout {
        let all = LibraryLayout.allCases
        return all[(all.firstIndex(of: self).map { $0 + 1 } ?? 0) % all.count]
    }
}

public enum LibrarySortMode: String, Sendable, CaseIterable, Hashable {
    case smart
    case custom
    case title
    case added
    case recent

    public var label: String {
        switch self {
        case .smart: return "智能"
        case .custom: return "自定义"
        case .title: return "书名"
        case .added: return "加入时间"
        case .recent: return "最近阅读"
        }
    }
}

public enum LibraryProjection {
    /// Filters then sorts. Smart order promotes the books with unread updates: the one most recently
    /// read first, then by the source's own last-updated date, then by when the update was detected;
    /// everything else follows in the shelf's manual order. An explicit sort never partitions.
    public static func apply(
        _ entries: [LibraryEntry],
        filter: SystemLibraryFilter,
        sort: LibrarySortMode,
        descending: Bool,
        updates: [BookIdentity: UnresolvedUpdate] = [:]
    ) -> [LibraryEntry] {
        let filtered = entries.filter(filter.accepts)
        switch sort {
        case .smart:
            let updated = filtered.filter { updates[$0.book.identity] != nil }
            let rest = filtered.filter { updates[$0.book.identity] == nil }
            let promoted = updated.sorted { lhs, rhs in
                let left = updates[lhs.book.identity]
                let right = updates[rhs.book.identity]
                if let l = lhs.progress?.updatedAt, let r = rhs.progress?.updatedAt, l != r { return l > r }
                if (lhs.progress == nil) != (rhs.progress == nil) { return lhs.progress != nil }
                let leftDate = left?.lastUpdatedDate ?? ""
                let rightDate = right?.lastUpdatedDate ?? ""
                if leftDate != rightDate { return leftDate > rightDate }
                let leftDetected = left?.detectedAt ?? .distantPast
                let rightDetected = right?.detectedAt ?? .distantPast
                if leftDetected != rightDetected { return leftDetected > rightDetected }
                return CanonicalOrder.precedes(lhs.book.title, rhs.book.title)
            }
            return promoted + rest
        case .custom:
            switch filter {
            case .continueReading:
                return filtered.sorted { later($0.progress?.updatedAt, $1.progress?.updatedAt) }
            case .all, .readLater, .dormant:
                return filtered
            }
        case .title:
            let sorted = filtered.sorted { CanonicalOrder.precedes($0.book.title, $1.book.title) }
            return descending ? sorted.reversed() : sorted
        case .added:
            let sorted = filtered.sorted { $0.libraryAddedAt < $1.libraryAddedAt }
            return descending ? sorted.reversed() : sorted
        case .recent:
            let read = filtered.filter { $0.progress != nil }
                .sorted { ($0.progress?.updatedAt ?? .distantPast) < ($1.progress?.updatedAt ?? .distantPast) }
            return (descending ? read.reversed() : read) + filtered.filter { $0.progress == nil }
        }
    }

    private static func later(_ lhs: Date?, _ rhs: Date?) -> Bool {
        (lhs ?? .distantPast) > (rhs ?? .distantPast)
    }
}
