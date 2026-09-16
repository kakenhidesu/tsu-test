// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiCore
import TsuyomiProtocol

/// How a site's folders are read on this side. The site is the authority on where a book is; these
/// rules only decide what an unlabelled item means and which folder an add lands in.
public enum RemoteMirrorTargets {
    /// The folder a site puts a book in when none is named: the one it calls its default, else the
    /// first one listed. No folders at all means the site's structure is unknown, not empty.
    public static func defaultTargetId(_ targets: [RemoteMirrorTarget]) -> String? {
        let live = targets.filter { !$0.frozen }
        let candidates = live.isEmpty ? targets : live
        if let named = candidates.first(where: { $0.displayName.contains("默认") }) { return named.targetId }
        return candidates.first?.targetId
    }

    /// An item the listing left unlabelled sits in the default folder; an explicit folder is kept
    /// even when the site no longer lists it, so a frozen folder keeps its books.
    public static func resolvedTargetId(_ item: RemoteMirrorItem, targets: [RemoteMirrorTarget]) -> String? {
        item.targetId ?? defaultTargetId(targets)
    }

    /// Grouping is worth offering only when the site has more than one folder to group by.
    public static func supportsGrouping(_ targets: [RemoteMirrorTarget]) -> Bool {
        targets.filter { !$0.frozen }.count > 1
    }

    public static func items(
        in mirror: RemoteMirror,
        targetId: String?
    ) -> [RemoteMirrorItem] {
        guard let targetId else { return mirror.items }
        return mirror.items.filter { resolvedTargetId($0, targets: mirror.targets) == targetId }
    }

    static func targets(_ list: RemoteLibraryTargetList) -> [RemoteMirrorTarget] {
        list.targets.map {
            RemoteMirrorTarget(
                sourceId: list.sourceId,
                targetId: $0.targetId,
                displayName: $0.displayName,
                parentId: $0.parentId,
                kind: $0.kind,
                frozen: false
            )
        }
    }
}
