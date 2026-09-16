// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore

public enum LibraryShortcut: Hashable, Sendable, Identifiable {
    case system(SystemLibraryFilter)
    case collection(String)
    /// A source's website shelf, mirrored locally. Opening it costs no network.
    case mirror(String)

    public var id: String {
        switch self {
        case .system(let filter): return "system:\(filter.rawValue)"
        case .collection(let collectionId): return "collection:\(collectionId)"
        case .mirror(let sourceId): return "mirror:\(sourceId)"
        }
    }

    init?(id: String) {
        if let raw = id.dropPrefixIfPresent("system:") {
            guard let filter = SystemLibraryFilter(rawValue: String(raw)) else { return nil }
            self = .system(filter)
        } else if let raw = id.dropPrefixIfPresent("collection:") {
            self = .collection(String(raw))
        } else if let raw = id.dropPrefixIfPresent("mirror:") {
            self = .mirror(String(raw))
        } else {
            return nil
        }
    }
}

/// Ordering is derived, never stored twice: the saved order is a preference over ids, and anything it
/// no longer names is dropped while anything new is appended in its natural position.
public enum LibraryShortcutOrder {
    public static func resolve(
        storedOrder: [String],
        systemNodes: [SystemLibraryFilter],
        collections: [LibraryCollection],
        mirrors: [RemoteMirrorBinding] = []
    ) -> [LibraryShortcut] {
        let available = systemNodes.map(LibraryShortcut.system)
            + collections.map { LibraryShortcut.collection($0.collectionId) }
            + mirrors.map { LibraryShortcut.mirror($0.sourceId) }
        var remaining = available
        var ordered: [LibraryShortcut] = []
        for id in storedOrder {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        return ordered + remaining
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
