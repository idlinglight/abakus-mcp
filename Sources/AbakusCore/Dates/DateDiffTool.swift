import Foundation

/// `date_diff`: the time between two instants, as a calendar breakdown and as exact totals (ADR-0006).
public struct DateDiffTool: Tool {
    public init() {}

    public let name = "date_diff"

    public let description = """
        Time between two dates or times, exactly: a calendar breakdown (years, months, days, hours, minutes, \
        seconds; Gregorian calendar, UTC), a short text such as "1 year 2 months 5 days" or "2 weeks 3 days", and \
        exact totals in days, hours, minutes and seconds (17.5 days). Use it instead of counting days or months in \
        your head.

        Arguments: from (required) and to (optional). Each is an ISO 8601 date (2026-11-08, read as 00:00 UTC), a \
        date-time with Z or a UTC offset (2026-11-08T14:30:00+01:00; seconds optional, up to 9 fractional \
        digits), or "now". A date-time without an offset is read as UTC, and the response notes it. Years 1583 to \
        9999. Without to, the current time is used; whenever the current time is used, to_is_now: true (or \
        from_is_now: true) is added, and the answer changes from call to call.

        Response: {"from", "to", "to_before_from", "calendar", "text", "totals", "notes"}: from and to in UTC, \
        notes only when something was assumed. When to is before from, to_before_from is true and every number in \
        calendar and totals is negative; text gives the size only. The breakdown counts forward from the earlier \
        instant: whole years, then months, then days, hours, minutes, seconds. A month added to Jan 31 ends on the \
        last day of February, so Jan 31 to Feb 28 is 1 month and Jan 31 to Mar 1 is 1 month 1 day. In text, 7 or \
        more days are written as weeks and days, and fractions of a second are left out ("less than 1 second" when \
        that is all there is); calendar and totals keep them. totals.seconds is always exact. Other totals that do \
        not come out even are rounded half away from zero to 15 significant digits (1 hour is 0.0416666666666667 \
        days) and flagged with days_exact: false, hours_exact: false or minutes_exact: false. Leap seconds are \
        ignored: every day has 86400 seconds.
        """

    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "from": [
                "type": "string",
                "description": "Start: 2026-11-08, 2026-11-08T14:30:00Z, 2026-11-08T14:30:00.5+01:00, or \"now\".",
            ],
            "to": [
                "type": "string",
                "description": "End, in the same forms. Default: the current time.",
            ],
        ],
        "required": ["from"],
        "additionalProperties": false,
    ]

    /// Read-only and idempotent; not deterministic when `to` defaults to now (the description says so).
    public let annotations = ToolAnnotations(title: "Date difference", readOnly: true, destructive: false, idempotent: true)

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    public func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        if let unknown = arguments.keys.first(where: { !["from", "to"].contains($0) }) {
            throw ToolError("Unknown argument \"\(unknown)\". date_diff takes from (required) and to.")
        }
        var cachedNow: Instant?
        let now = { () throws(ToolError) -> Instant in
            if let cachedNow { return cachedNow }
            let instant = Instant(context.now())
            guard instant.isSupported else {
                throw ToolError("The current time, \(instant.iso8601), is outside the supported years 1583 to 9999.")
            }
            cachedNow = instant
            return instant
        }

        guard let fromValue = arguments["from"], !fromValue.isNull else {
            throw ToolError("from is missing: pass the start as an ISO 8601 date, e.g. {\"from\": \"2026-11-08\"}.")
        }
        let from = try ISODateReader.read(try string(fromValue, argument: "from"), argument: "from", now: now)
        let to: ISODateReader.Reading
        if let toValue = arguments["to"], !toValue.isNull {
            to = try ISODateReader.read(try string(toValue, argument: "to"), argument: "to", now: now)
        } else {
            to = ISODateReader.Reading(instant: try now(), assumedUTC: false, isNow: true)
        }

        var result: JSONObject = ["from": .string(from.instant.iso8601), "to": .string(to.instant.iso8601)]
        if from.isNow { result["from_is_now"] = true }
        if to.isNow { result["to_is_now"] = true }
        let backward = to.instant < from.instant
        result["to_before_from"] = .bool(backward)
        try difference(between: from.instant, and: to.instant, negative: backward, into: &result)

        var notes: [JSONValue] = []
        for (argument, reading) in [("from", from), ("to", to)] where reading.assumedUTC {
            notes.append(.string("\(argument) has no UTC offset; it was read as UTC."))
        }
        if !notes.isEmpty { result["notes"] = .array(notes) }
        return result
    }

    private func string(_ value: JSONValue, argument: String) throws(ToolError) -> String {
        guard let text = value.stringValue else {
            throw ToolError("\(argument) must be a string such as \"2026-11-08\" or \"2026-11-08T14:30:00Z\", or \"now\".")
        }
        return text
    }

    private func difference(between a: Instant, and b: Instant, negative: Bool, into result: inout JSONObject) throws(ToolError) {
        let (earlier, later) = negative ? (b, a) : (a, b)
        // Borrow a second when the fraction of the later instant is smaller.
        var endSeconds = later.seconds
        var fraction = later.nanoseconds - earlier.nanoseconds
        if fraction < 0 {
            fraction += 1_000_000_000
            endSeconds -= 1
        }
        let parts = Self.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: earlier.wholeSecondDate,
            to: Date(timeIntervalSince1970: TimeInterval(endSeconds))
        )
        let years = parts.year ?? 0, months = parts.month ?? 0, days = parts.day ?? 0
        let hours = parts.hour ?? 0, minutes = parts.minute ?? 0
        // Seconds with their fraction; exact (well below 38 digits).
        let secondsInNanoseconds = BigUInt(UInt64(parts.second ?? 0)).timesPowerOfTen(9) + BigUInt(UInt64(fraction))
        let seconds = try DecimalMath.round(ExactDecimal(negative: false, magnitude: secondsInNanoseconds, exponent: -9)).value

        func signed(_ value: Int) -> JSONValue { .number(String(negative ? -value : value)) }
        result["calendar"] = [
            "years": signed(years),
            "months": signed(months),
            "days": signed(days),
            "hours": signed(hours),
            "minutes": signed(minutes),
            // Decimal has no negative zero; only non-zero seconds get a sign.
            "seconds": .decimal(negative && !seconds.isZero ? -seconds : seconds),
        ]
        result["text"] = .string(Self.text(
            years: years, months: months, days: days, hours: hours, minutes: minutes, seconds: parts.second ?? 0,
            fraction: fraction != 0
        ))

        let totalNanoseconds = BigUInt(UInt64(endSeconds - earlier.seconds)).timesPowerOfTen(9) + BigUInt(UInt64(fraction))
        let totalSeconds = ExactDecimal(negative: negative, magnitude: totalNanoseconds, exponent: -9)
        var totals = JSONObject()
        for (unit, length) in [("days", 86400), ("hours", 3600), ("minutes", 60), ("seconds", 1)] {
            // The readable policy shared with sum's mean (ADR-0005); seconds always come out exact.
            let total = try DecimalMath.round(totalSeconds, dividingBy: BigUInt(UInt64(length)), .readable)
            totals[unit] = .decimal(total.value)
            if !total.exact { totals["\(unit)_exact"] = false }
        }
        result["totals"] = .object(totals)
    }

    /// "1 year 2 months 2 weeks 3 days 4 hours 5 minutes 6 seconds", leaving out zero parts and the fraction of a
    /// second (`fraction`: whether there is one), which only `calendar` and `totals` keep (ADR-0006). A difference
    /// of a fraction only is "less than 1 second", so a non-zero difference never reads as "0 seconds".
    static func text(years: Int, months: Int, days: Int, hours: Int, minutes: Int, seconds: Int, fraction: Bool) -> String {
        func part(_ count: Int, _ unit: String) -> String? {
            count == 0 ? nil : "\(count) \(unit)\(count == 1 ? "" : "s")"
        }
        let parts = [
            part(years, "year"), part(months, "month"), part(days / 7, "week"), part(days % 7, "day"),
            part(hours, "hour"), part(minutes, "minute"), part(seconds, "second"),
        ].compactMap { $0 }
        if parts.isEmpty {
            return fraction ? "less than 1 second" : "0 seconds"
        }
        return parts.joined(separator: " ")
    }
}
