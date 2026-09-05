// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TsuyomiProtocol

/// The state the system may hand back to the app: which chapter of which book was open. It carries
/// no progress and no content — the position lives in the local database, so a restored activity
/// resumes at the same semantic locator without the activity ever having held one.
public enum ReadingActivity {
    public static let type = "org.tsuyomi.ios.reading"

    private enum Key {
        static let sourceId = "sourceId"
        static let remoteBookId = "remoteBookId"
        static let chapterId = "chapterId"
        static let bookTitle = "bookTitle"
    }

    public static func payload(
        identity: BookIdentity,
        chapterId: String,
        bookTitle: String
    ) -> [String: String] {
        [
            Key.sourceId: identity.sourceId,
            Key.remoteBookId: identity.remoteBookId,
            Key.chapterId: chapterId,
            Key.bookTitle: bookTitle
        ]
    }

    public static func route(from userInfo: [AnyHashable: Any]) -> Route? {
        guard let sourceId = userInfo[Key.sourceId] as? String,
              let remoteBookId = userInfo[Key.remoteBookId] as? String,
              let chapterId = userInfo[Key.chapterId] as? String,
              let identity = try? BookIdentity(sourceId: sourceId, remoteBookId: remoteBookId) else {
            return nil
        }
        return .reader(identity, chapterId)
    }

    public static func title(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[Key.bookTitle] as? String
    }
}
