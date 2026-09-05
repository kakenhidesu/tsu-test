// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

public enum SystemLibraryFilter: String, Sendable, CaseIterable, Hashable {
    case all
    case continueReading
    case recent
    case readLater
    case unread
    case dormant

    public var title: String {
        switch self {
        case .all: return "全部"
        case .continueReading: return "继续阅读"
        case .recent: return "最近阅读"
        case .readLater: return "稍后再读"
        case .unread: return "未读更新"
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
        case .recent: return entry.progress != nil
        case .readLater: return entry.readLater
        case .unread: return entry.book.hasUnreadUpdate
        case .dormant: return !entry.sourceAvailable
        }
    }
}

public enum LibraryLayout: String, Sendable, CaseIterable, Hashable {
    case grid
    case list
    case compact

    public var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        case .compact: return "紧凑"
        }
    }

    public var next: LibraryLayout {
        let all = LibraryLayout.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum LibrarySortMode: String, Sendable, CaseIterable, Hashable {
    case custom
    case title
    case added
    case recent

    public var label: String {
        switch self {
        case .custom: return "自定义"
        case .title: return "书名"
        case .added: return "加入时间"
        case .recent: return "最近阅读"
        }
    }
}

/// Filtering and ordering are pure: the same entries, filter, and sort always produce the same list,
/// so a reorder that is persisted and a reorder that is displayed can never disagree.
public enum LibraryProjection {
    public static func apply(
        _ entries: [LibraryEntry],
        filter: SystemLibraryFilter,
        sort: LibrarySortMode,
        descending: Bool
    ) -> [LibraryEntry] {
        let filtered = entries.filter(filter.accepts)
        switch sort {
        case .custom:
            switch filter {
            case .continueReading, .recent:
                return filtered.sorted { later($0.progress?.updatedAt, $1.progress?.updatedAt) }
            case .unread:
                return filtered.sorted { $0.book.metadataUpdatedAt > $1.book.metadataUpdatedAt }
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
