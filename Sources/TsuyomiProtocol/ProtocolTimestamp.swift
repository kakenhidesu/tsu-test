// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The wire timestamp of every protocol document: RFC 3339 on input, ISO-8601 UTC without a
/// fractional part on output. Sub-second precision is dropped at parse time so that a document
/// re-serialized by this host is byte-stable against the document it was parsed from.
public enum ProtocolTimestamp {
    public static func parse(_ value: String) -> Date? {
        let scalars = Array(value.utf8)
        guard scalars.count >= 20 else { return nil }
        var cursor = 0

        func digits(_ count: Int) -> Int? {
            guard cursor + count <= scalars.count else { return nil }
            var accumulated = 0
            for _ in 0..<count {
                let byte = scalars[cursor]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                accumulated = accumulated * 10 + Int(byte - 0x30)
                cursor += 1
            }
            return accumulated
        }
        func literal(_ character: UInt8) -> Bool {
            guard cursor < scalars.count, scalars[cursor] == character else { return false }
            cursor += 1
            return true
        }

        guard let year = digits(4), literal(0x2D), let month = digits(2), literal(0x2D), let day = digits(2) else {
            return nil
        }
        guard cursor < scalars.count, scalars[cursor] == 0x54 || scalars[cursor] == 0x74 else { return nil }
        cursor += 1
        guard let hour = digits(2), literal(0x3A), let minute = digits(2), literal(0x3A), let second = digits(2) else {
            return nil
        }
        if cursor < scalars.count, scalars[cursor] == 0x2E {
            cursor += 1
            let start = cursor
            while cursor < scalars.count, scalars[cursor] >= 0x30, scalars[cursor] <= 0x39 { cursor += 1 }
            guard cursor > start else { return nil }
        }

        var offsetSeconds = 0
        guard cursor < scalars.count else { return nil }
        switch scalars[cursor] {
        case 0x5A, 0x7A:
            cursor += 1
        case 0x2B, 0x2D:
            let sign = scalars[cursor] == 0x2B ? 1 : -1
            cursor += 1
            guard let offsetHour = digits(2), literal(0x3A), let offsetMinute = digits(2) else { return nil }
            guard offsetHour <= 18, offsetMinute <= 59 else { return nil }
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        default:
            return nil
        }
        guard cursor == scalars.count else { return nil }
        guard (1...12).contains(month), (1...31).contains(day), hour <= 23, minute <= 59, second <= 60 else {
            return nil
        }
        guard day <= daysInMonth(year: year, month: month) else { return nil }

        let epochDay = daysFromCivil(year: year, month: month, day: day)
        let epochSecond = epochDay * 86_400 + hour * 3_600 + minute * 60 + min(second, 59) - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epochSecond))
    }

    public static func format(_ date: Date) -> String {
        let epochSecond = Int(date.timeIntervalSince1970.rounded(.down))
        var epochDay = epochSecond / 86_400
        var secondOfDay = epochSecond % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            epochDay -= 1
        }
        let civil = civilFromDays(epochDay)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return "\(pad(civil.year, width: 4))-\(pad(civil.month, width: 2))-\(pad(civil.day, width: 2))"
            + "T\(pad(hour, width: 2)):\(pad(minute, width: 2)):\(pad(second, width: 2))Z"
    }

    /// Whole-second instant used whenever this host mints a new protocol timestamp.
    public static func now(_ clock: Date = Date()) -> Date {
        Date(timeIntervalSince1970: clock.timeIntervalSince1970.rounded(.down))
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ epochDay: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = epochDay + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth + (shiftedMonth < 10 ? 3 : -9)
        return (month <= 2 ? year + 1 : year, month, day)
    }
}
