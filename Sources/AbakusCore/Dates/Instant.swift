import Foundation

/// An instant in UTC: whole seconds since 1970-01-01T00:00:00Z plus nanoseconds. Integers, so differences and
/// totals stay exact; a `Date` (a Double) is only used for whole seconds, which it holds exactly (ADR-0006).
struct Instant: Comparable, Sendable {
    var seconds: Int64
    /// 0 ..< 1_000_000_000
    var nanoseconds: Int64

    /// The supported range: the Gregorian calendar as Foundation computes it is proleptic only from 15 October 1582
    /// (before that it switches to the Julian calendar), and four-digit years end in 9999.
    static let earliest = Instant(seconds: Int64(Civil.days(year: 1583, month: 1, day: 1)) * 86400, nanoseconds: 0)
    static let latest = Instant(seconds: Int64(Civil.days(year: 9999, month: 12, day: 31)) * 86400 + 86399, nanoseconds: 999_999_999)

    init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    /// A `Date`, to the nearest millisecond: what `Date` holds reliably at today's distance from 1970.
    init(_ date: Date) {
        // Far outside the supported range either way; clamped so the conversion to Int64 cannot trap.
        let milliseconds = Int64(min(max((date.timeIntervalSince1970 * 1000).rounded(), -1e15), 1e15))
        let (quotient, remainder) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        seconds = remainder < 0 ? quotient - 1 : quotient
        nanoseconds = (remainder < 0 ? remainder + 1000 : remainder) * 1_000_000
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }

    var isSupported: Bool { self >= Instant.earliest && self <= Instant.latest }

    /// The whole second, for Foundation's calendar arithmetic.
    var wholeSecondDate: Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    /// UTC ISO 8601, `2026-11-08T14:30:00Z`, with a fraction only when there is one, without trailing zeros.
    var iso8601: String {
        let (days, secondOfDay) = floorDivision(seconds, 86400)
        let date = Civil.date(days: Int(days))
        var text = pad(date.year, 4) + "-" + pad(date.month, 2) + "-" + pad(date.day, 2) + "T"
            + pad(Int(secondOfDay / 3600), 2) + ":" + pad(Int(secondOfDay % 3600 / 60), 2) + ":" + pad(Int(secondOfDay % 60), 2)
        if nanoseconds > 0 {
            var fraction = pad(Int(nanoseconds), 9)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text + "Z"
    }
}

/// Proleptic Gregorian dates as day numbers (0 is 1970-01-01), after Howard Hinnant's `days_from_civil` and
/// `civil_from_days`.
enum Civil {
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
}

/// Reads `from` and `to` (ADR-0006): ISO 8601 dates and date-times in the extended format, or `now`.
enum ISODateReader {
    struct Reading {
        var instant: Instant
        /// A date-time without `Z` or an offset, read as UTC.
        var assumedUTC: Bool
        var isNow: Bool
    }

    static let accepted = "Accepted: 2026-11-08 (read as 00:00 UTC), 2026-11-08T14:30Z, 2026-11-08T14:30:00+01:00, "
        + "2026-11-08T14:30:00.25Z (seconds and up to 9 fractional digits optional), or \"now\"."

    static func read(_ original: String, argument: String, now: () throws(ToolError) -> Instant) throws(ToolError) -> Reading {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ problem: String) -> ToolError {
            ToolError("\(argument): Cannot read \(original.quotedForMessage) as a date: \(problem) \(accepted)", details: ["input": .string(original.cutForMessage)])
        }
        if text.lowercased() == "now" {
            return Reading(instant: try now(), assumedUTC: false, isNow: true)
        }
        let pattern = /([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[Tt ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:[.,]([0-9]+))?)?([Zz]|[+\-−][0-9]{2}(?::?[0-9]{2})?)?)?/
        guard let match = text.wholeMatch(of: pattern) else {
            throw fail("it is not an ISO 8601 date or date-time in the extended format.")
        }
        let (_, yearText, monthText, dayText, hourText, minuteText, secondText, fractionText, offsetText) = match.output
        let year = Int(yearText)!, month = Int(monthText)!, day = Int(dayText)!
        let hour = hourText.map { Int($0)! } ?? 0
        let minute = minuteText.map { Int($0)! } ?? 0
        let second = secondText.map { Int($0)! } ?? 0

        if year < 1583 {
            throw fail(
                "years before 1583 are not supported: Foundation's Gregorian calendar, which abakus uses, switches to "
                    + "the Julian calendar before 15 October 1582."
            )
        }
        guard (1...12).contains(month) else { throw fail("there is no month \(monthText).") }
        let length = Civil.daysInMonth(year: year, month: month)
        guard (1...length).contains(day) else {
            throw fail("\(Civil.monthNames[month - 1]) \(year) has \(length) days.")
        }
        guard hour <= 23 else { throw fail("the hour must be 00 to 23; midnight at the end of a day is 00:00 of the next day.") }
        guard minute <= 59 else { throw fail("the minute must be 00 to 59.") }
        if second == 60 { throw fail("second 60 is a leap second; abakus ignores leap seconds, so use :59 or the next minute.") }
        guard second <= 59 else { throw fail("the second must be 00 to 59.") }

        var nanoseconds: Int64 = 0
        if let fractionText {
            guard fractionText.count <= 9 else {
                throw fail("fractional seconds may have at most 9 digits (nanoseconds); this one has \(fractionText.count).")
            }
            nanoseconds = Int64(fractionText + String(repeating: "0", count: 9 - fractionText.count))!
        }

        var offsetSeconds = 0
        if let offsetText, offsetText != "Z", offsetText != "z" {
            let digits = offsetText.dropFirst().filter { $0 != ":" }
            let offsetHours = Int(digits.prefix(2))!
            let offsetMinutes = digits.count > 2 ? Int(digits.suffix(2))! : 0
            guard offsetHours <= 23, offsetMinutes <= 59 else {
                throw fail("the UTC offset \(offsetText) is not valid; it runs from -23:59 to +23:59.")
            }
            offsetSeconds = (offsetText.first == "+" ? 1 : -1) * (offsetHours * 3600 + offsetMinutes * 60)
        }

        let days = Int64(Civil.days(year: year, month: month, day: day))
        let local = days * 86400 + Int64(hour * 3600 + minute * 60 + second)
        let instant = Instant(seconds: local - Int64(offsetSeconds), nanoseconds: nanoseconds)
        guard instant.isSupported else {
            throw fail("in UTC it is \(instant.iso8601), outside the supported years 1583 to 9999.")
        }
        return Reading(instant: instant, assumedUTC: hourText != nil && offsetText == nil, isNow: false)
    }
}

private func floorDivision(_ a: Int64, _ b: Int64) -> (quotient: Int64, remainder: Int64) {
    let (quotient, remainder) = a.quotientAndRemainder(dividingBy: b)
    return remainder < 0 ? (quotient - 1, remainder + b) : (quotient, remainder)
}

private func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}
