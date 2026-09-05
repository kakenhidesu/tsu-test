// SPDX-License-Identifier: AGPL-3.0-only

/// Canonical ordering used by every exported protocol document. It is UTF-16 code-unit order so
/// that a snapshot exported by one host sorts identically on the other (transfer-v1 §Canonical form).
public enum CanonicalOrder {
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool { compare(lhs, rhs) < 0 }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        var left = lhs.utf16.makeIterator()
        var right = rhs.utf16.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (leftUnit?, rightUnit?):
                if leftUnit != rightUnit { return leftUnit < rightUnit ? -1 : 1 }
            }
        }
    }

    public static func sorted(_ values: some Sequence<String>) -> [String] {
        values.sorted(by: precedes)
    }
}
