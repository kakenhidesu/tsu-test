// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Every timestamp column pair in the v4 schema is `(epoch_second, nano)`. Splitting it keeps the
/// column semantics identical to the Android host, which stores `Instant` the same way.
extension Date {
    var epochSecond: Int64 {
        Int64(timeIntervalSince1970.rounded(.down))
    }

    var nanoOfSecond: Int32 {
        let fraction = timeIntervalSince1970 - Double(epochSecond)
        return Int32(min(max((fraction * 1_000_000_000).rounded(), 0), 999_999_999))
    }

    init(epochSecond: Int64, nano: Int32) {
        self.init(timeIntervalSince1970: Double(epochSecond) + Double(nano) / 1_000_000_000)
    }
}

extension SQLiteRow {
    func instant(_ secondColumn: String, _ nanoColumn: String) -> Date? {
        guard let second = self[secondColumn].int else { return nil }
        return Date(epochSecond: second, nano: Int32(self[nanoColumn].int ?? 0))
    }
}
