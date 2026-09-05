// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Identifier grammars defined by the Tsuyomi protocol schemas. Every bound here is normative:
/// hosts reject values outside it before the value reaches storage, network, or the reader.
public enum Grammar {
    /// `^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$` — the durable-record source identifier.
    public static func isLegacySourceId(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...128).contains(scalars.count) else { return false }
        guard isLowerAlphanumeric(scalars[0]) else { return false }
        guard scalars.count > 1 else { return true }
        guard isLowerAlphanumeric(scalars[scalars.count - 1]) else { return false }
        return scalars[1..<(scalars.count - 1)].allSatisfy { isLowerAlphanumeric($0) || $0 == "." || $0 == "-" }
    }

    /// `^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$` — the manifest and repository identifier grammar.
    public static func isStrictSourceId(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...128).contains(scalars.count) else { return false }
        guard let first = scalars.first, isLowerAlpha(first) else { return false }
        var index = 1
        while index < scalars.count, isLowerAlphanumeric(scalars[index]) { index += 1 }
        var separators = 0
        while index < scalars.count {
            guard scalars[index] == "." || scalars[index] == "-" else { return false }
            separators += 1
            index += 1
            let start = index
            while index < scalars.count, isLowerAlphanumeric(scalars[index]) { index += 1 }
            guard index > start else { return false }
        }
        return separators > 0
    }

    /// `^[a-f0-9]{64}$`
    public static func isSha256(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        return scalars.count == 64 && scalars.allSatisfy { isDigit($0) || ("a"..."f").contains($0) }
    }

    /// `^[A-Za-z0-9._-]{1,limit}$` — home filter, feature, section, and cursor tokens.
    public static func isToken(_ value: String, limit: Int) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...limit).contains(scalars.count) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `^[A-Za-z0-9._:-]{1,160}$`
    public static func isSemanticCacheKey(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...160).contains(scalars.count) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" || $0 == ":" }
    }

    /// `^[A-Za-z0-9_-]{8,128}$`
    public static func isDiagnosticId(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (8...128).contains(scalars.count) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    public static func codePointCount(_ value: String) -> Int { value.unicodeScalars.count }

    public static func hasCodePoints(_ value: String, in range: ClosedRange<Int>) -> Bool {
        range.contains(value.unicodeScalars.count)
    }

    public static func isBoundedProgress(_ value: Double) -> Bool {
        value.isFinite && value >= 0.0 && value <= 1.0
    }

    /// An absolute `https://` URL with a host, as required by every protocol URL field.
    public static func isHttpsUrl(_ value: String) -> Bool {
        guard (1...4096).contains(value.unicodeScalars.count) else { return false }
        guard let components = URLComponents(string: value) else { return false }
        guard components.scheme?.lowercased() == "https" else { return false }
        guard let host = components.host, !host.isEmpty else { return false }
        return true
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
    private static func isLowerAlpha(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }
    private static func isUpperAlpha(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) }
    private static func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool { isDigit(scalar) || isLowerAlpha(scalar) }
    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || isLowerAlpha(scalar) || isUpperAlpha(scalar)
    }
}

extension Array where Element: Hashable {
    var hasDistinctElements: Bool { Set(self).count == count }
}
