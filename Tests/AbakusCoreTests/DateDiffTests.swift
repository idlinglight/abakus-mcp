import AbakusCore
import Foundation
import Testing

@Suite struct DateDiffTests {
    private let tool = DateDiffTool()
    /// 2026-11-08T17:20:31.123Z. date_diff writes nothing; the folder is never created.
    private let context = ToolContext(
        stateDirectory: FileManager.default.temporaryDirectory.appending(path: "abakus-tests-\(UUID())"),
        now: { Date(timeIntervalSince1970: 1_794_158_431.123) }
    )

    private func diff(_ arguments: JSONObject) throws(ToolError) -> JSONObject {
        try tool.call(arguments, in: context)
    }

    private func failure(_ arguments: JSONObject) -> ToolError? {
        do {
            _ = try diff(arguments)
            return nil
        } catch {
            return error
        }
    }

    private func calendar(_ years: Int, _ months: Int, _ days: Int, _ hours: Int, _ minutes: Int, _ seconds: JSONValue) -> JSONValue {
        ["years": .number(String(years)), "months": .number(String(months)), "days": .number(String(days)),
         "hours": .number(String(hours)), "minutes": .number(String(minutes)), "seconds": seconds]
    }

    @Test func isListed() {
        #expect(DateTools.all.contains { $0.name == "date_diff" })
        #expect(Catalog.tool(named: "date_diff") != nil)
    }

    @Test func annotationsAndSchema() throws {
        #expect(tool.annotations == ToolAnnotations(title: "Date difference", readOnly: true, destructive: false, idempotent: true))
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["required"] == ["from"])
        #expect(schema["additionalProperties"] == false)
        #expect(schema["properties"]?.objectValue?.keys == ["from", "to"])
        #expect(tool.description.contains("changes from call to call"))
    }

    @Test func daysAndHours() throws {
        let result = try diff(["from": "2026-11-08", "to": "2026-11-25T12:00:00Z"])
        #expect(result == [
            "from": "2026-11-08T00:00:00Z",
            "to": "2026-11-25T12:00:00Z",
            "to_before_from": false,
            "calendar": calendar(0, 0, 17, 12, 0, 0),
            "text": "2 weeks 3 days 12 hours",
            "totals": ["days": .number("17.5"), "hours": 420, "minutes": 25200, "seconds": 1_512_000],
        ])
        #expect(result.keys == ["from", "to", "to_before_from", "calendar", "text", "totals"])
    }

    @Test func toDefaultsToNow() throws {
        let result = try diff(["from": "2026-11-01"])
        #expect(result["to"] == "2026-11-08T17:20:31.123Z")
        #expect(result["to_is_now"] == true)
        #expect(result["calendar"] == calendar(0, 0, 7, 17, 20, .number("31.123")))
        #expect(result["text"] == "1 week 17 hours 20 minutes 31.123 seconds")
        // Rounded to 3 + 6 decimal places, half away from zero.
        #expect(result["totals"] == [
            "days": .number("7.722582442"), "days_exact": false,
            "hours": .number("185.341978611"), "hours_exact": false,
            "minutes": .number("11120.518716667"), "minutes_exact": false,
            "seconds": .number("667231.123"),
        ])
        #expect(result.keys == ["from", "to", "to_is_now", "to_before_from", "calendar", "text", "totals"])
    }

    @Test func nowAsAnArgument() throws {
        let result = try diff(["from": "now", "to": "2026-12-24"])
        #expect(result["from"] == "2026-11-08T17:20:31.123Z")
        #expect(result["from_is_now"] == true)
        #expect(result["to_is_now"] == nil)
        #expect(result["calendar"] == calendar(0, 1, 15, 6, 39, .number("28.877")))
        #expect(result["text"] == "1 month 2 weeks 1 day 6 hours 39 minutes 28.877 seconds")
        #expect(result["totals"]?.objectValue?["days"] == .number("45.277417558"))
        #expect(result["totals"]?.objectValue?["seconds"] == .number("3911968.877"))
        #expect(try diff(["from": " NOW "])["text"] == "0 seconds")
    }

    @Test func toBeforeFromMakesEveryNumberNegative() throws {
        let result = try diff(["from": "2026-03-31", "to": "2026-02-28"])
        #expect(result["to_before_from"] == true)
        // Counted forward from the earlier date, Feb 28: one month to Mar 28, then 3 days.
        #expect(result["calendar"] == calendar(0, -1, -3, 0, 0, 0))
        #expect(result["text"] == "1 month 3 days")
        #expect(result["totals"] == ["days": -31, "hours": -744, "minutes": -44640, "seconds": -2_678_400])
    }

    @Test(arguments: [
        ("2026-01-31", "2026-02-28", [0, 1, 0], "1 month"),
        ("2026-01-30", "2026-02-28", [0, 1, 0], "1 month"),
        ("2026-01-31", "2026-03-01", [0, 1, 1], "1 month 1 day"),
        ("2026-01-31", "2026-03-30", [0, 1, 30], "1 month 4 weeks 2 days"),
        ("2026-01-31", "2026-03-31", [0, 2, 0], "2 months"),
        ("2024-02-29", "2025-02-28", [1, 0, 0], "1 year"),
        ("2024-02-29", "2025-03-01", [1, 0, 1], "1 year 1 day"),
        ("2026-02-28", "2026-03-31", [0, 1, 3], "1 month 3 days"),
        ("2025-11-08", "2026-11-08", [1, 0, 0], "1 year"),
        ("2026-11-08", "2026-11-15", [0, 0, 7], "1 week"),
    ])
    func monthEnds(from: String, to: String, expected: [Int], text: String) throws {
        let result = try diff(["from": .string(from), "to": .string(to)])
        #expect(result["calendar"] == calendar(expected[0], expected[1], expected[2], 0, 0, 0), "\(from) to \(to)")
        #expect(result["text"] == .string(text), "\(from) to \(to)")
        // The same pair the other way round: the same size, negative.
        let reversed = try diff(["from": .string(to), "to": .string(from)])
        #expect(reversed["calendar"] == calendar(-expected[0], -expected[1], -expected[2], 0, 0, 0), "\(to) to \(from)")
        #expect(reversed["text"] == .string(text))
    }

    @Test(arguments: [
        ("2026-11-08T14:30:00+01:00", "2026-11-08T13:30:00Z"),
        ("2026-11-08T14:30:00-0530", "2026-11-08T20:00:00Z"),
        ("2026-11-08T14:30\u{2212}05", "2026-11-08T19:30:00Z"),
        ("2026-11-08t14:30z", "2026-11-08T14:30:00Z"),
        ("2026-11-08 14:30Z", "2026-11-08T14:30:00Z"),
        ("2026-11-08T00:30:00+01:00", "2026-11-07T23:30:00Z"),
        ("2026-11-08T14:30:00,5Z", "2026-11-08T14:30:00.5Z"),
        ("2026-11-08T14:30:00.120Z", "2026-11-08T14:30:00.12Z"),
        ("2026-11-08T14:30:00-00:00", "2026-11-08T14:30:00Z"),
        (" 2026-11-08 ", "2026-11-08T00:00:00Z"),
    ])
    func normalizesToUTC(input: String, expected: String) throws {
        let result = try diff(["from": .string(input), "to": "2026-11-08"])
        #expect(result["from"] == .string(expected), "\(input)")
        #expect(result["notes"] == nil)
    }

    @Test func dateTimeWithoutOffsetIsReadAsUTCAndNoted() throws {
        let result = try diff(["from": "2026-11-08T14:30", "to": "2026-11-09T08:00:00"])
        #expect(result["from"] == "2026-11-08T14:30:00Z")
        #expect(result["notes"] == [
            "from has no UTC offset; it was read as UTC.",
            "to has no UTC offset; it was read as UTC.",
        ])
        #expect(result["text"] == "17 hours 30 minutes")
    }

    @Test func fractionalSecondsStayExact() throws {
        let result = try diff(["from": "2026-11-08T00:00:00.75Z", "to": "2026-11-08T00:00:01.5Z"])
        #expect(result["calendar"] == calendar(0, 0, 0, 0, 0, .number("0.75")))
        #expect(result["text"] == "0.75 seconds")
        // Rounded to 2 + 6 places; 0.75 / 60 = 0.0125 comes out even.
        #expect(result["totals"] == [
            "days": .number("0.00000868"), "days_exact": false,
            "hours": .number("0.00020833"), "hours_exact": false,
            "minutes": .number("0.0125"), "seconds": .number("0.75"),
        ])

        let nano = try diff(["from": "2026-11-08T00:00:00.000000001Z", "to": "2026-11-08T00:00:00Z"])
        #expect(nano["to_before_from"] == true)
        #expect(nano["calendar"] == calendar(0, 0, 0, 0, 0, .number("-0.000000001")))
        #expect(nano["totals"]?.objectValue?["seconds"] == .number("-0.000000001"))
        #expect(nano["text"] == "0.000000001 seconds")
    }

    @Test func sameInstantIsZero() throws {
        let result = try diff(["from": "2026-11-08T12:00:00+02:00", "to": "2026-11-08T10:00:00Z"])
        #expect(result["to_before_from"] == false)
        #expect(result["calendar"] == calendar(0, 0, 0, 0, 0, 0))
        #expect(result["text"] == "0 seconds")
        #expect(result["totals"] == ["days": 0, "hours": 0, "minutes": 0, "seconds": 0])
    }

    @Test func wholeSupportedRange() throws {
        let result = try diff(["from": "1583-01-01", "to": "9999-12-31T23:59:59.999999999Z"])
        #expect(result["calendar"] == calendar(8416, 11, 30, 23, 59, .number("59.999999999")))
        #expect(result["totals"] == [
            "days": .number("3074245.999999999999988"), "days_exact": false,
            "hours": .number("73781903.999999999999722"), "hours_exact": false,
            "minutes": .number("4426914239.999999999983333"), "minutes_exact": false,
            "seconds": .number("265614854399.999999999"),
        ])
    }

    @Test(arguments: [
        ("2026-02-29", "February 2026 has 28 days"),
        ("2026-11-31", "November 2026 has 30 days"),
        ("2026-13-01", "there is no month 13"),
        ("2026-00-10", "there is no month 00"),
        ("2026-11-08T24:00", "the hour must be 00 to 23"),
        ("2026-11-08T12:60", "the minute must be 00 to 59"),
        ("2026-11-08T23:59:60Z", "leap second"),
        ("2026-11-08T14:30:00.1234567890Z", "at most 9 digits"),
        ("2026-11-08T14:30+24:00", "UTC offset +24:00 is not valid"),
        ("1582-10-15", "years before 1583"),
        ("9999-12-31T23:00:00-05:00", "outside the supported years"),
        ("08.11.2026", "not an ISO 8601 date"),
        ("2026-11-8", "not an ISO 8601 date"),
        ("2026-11-08T14Z", "not an ISO 8601 date"),
        ("2026-11-08Z", "not an ISO 8601 date"),
        ("20261108", "not an ISO 8601 date"),
        ("2026-11-08T14:30:00 +01:00", "not an ISO 8601 date"),
        ("yesterday", "not an ISO 8601 date"),
        ("", "not an ISO 8601 date"),
    ])
    func refusesWhatItCannotRead(input: String, problem: String) throws {
        let error = try #require(failure(["from": .string(input), "to": "2026-11-08"]))
        #expect(error.message.hasPrefix("from: Cannot read \"\(input)\" as a date: "), "\(input)")
        #expect(error.message.contains(problem), "\(input): \(error.message)")
        #expect(error.message.contains("Accepted:"))
        #expect(error.details == ["input": .string(input)])
        // The same rules for to.
        #expect(failure(["from": "2026-11-08", "to": .string(input)])?.message.hasPrefix("to: ") == true)
    }

    @Test func badArguments() {
        #expect(failure([:])?.message.contains("from is missing") == true)
        #expect(failure(["from": 20261108])?.message.contains("from must be a string") == true)
        #expect(failure(["from": "2026-11-08", "to": true])?.message.contains("to must be a string") == true)
        #expect(failure(["from": "2026-11-08", "until": "2026-12-01"])?.message.contains("Unknown argument \"until\"") == true)
    }

    /// Random pairs of instants: the calendar breakdown added to the earlier instant gives the later one, and the
    /// total in seconds matches the difference Foundation computes on its own.
    @Test func breakdownAddsUpAndTotalsMatch() throws {
        var random = SplitMix64(seed: 0x0da7_e5)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        for _ in 0..<300 {
            var instants: [(text: String, date: Date)] = []
            for _ in 0..<2 {
                let year = Bool.random(using: &random) ? Int.random(in: 2020...2030, using: &random) : Int.random(in: 1583...9999, using: &random)
                let parts = DateComponents(
                    year: year, month: Int.random(in: 1...12, using: &random), day: Int.random(in: 1...28, using: &random) + (Bool.random(using: &random) ? 3 : 0),
                    hour: Int.random(in: 0...23, using: &random), minute: Int.random(in: 0...59, using: &random), second: Int.random(in: 0...59, using: &random)
                )
                // Days 29 to 31 that do not exist roll over in Foundation; take whatever date that gives.
                let date = try #require(utc.date(from: parts))
                let shown = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let text = String(
                    format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ldZ",
                    shown.year!, shown.month!, shown.day!, shown.hour!, shown.minute!, shown.second!
                )
                instants.append((text, date))
            }
            let (from, to) = (instants[0], instants[1])

            let result = try diff(["from": .string(from.text), "to": .string(to.text)])
            #expect(result["from"] == .string(from.text))
            #expect(result["to"] == .string(to.text))
            let seconds = Int(to.date.timeIntervalSince1970) - Int(from.date.timeIntervalSince1970)
            #expect(result["totals"]?.objectValue?["seconds"] == .number(String(seconds)), "\(from.text) to \(to.text)")

            let breakdown = try #require(result["calendar"]?.objectValue)
            func part(_ key: String) -> Int { abs(Int(breakdown[key]!.numberLiteral!)!) }
            let added = utc.date(
                byAdding: DateComponents(year: part("years"), month: part("months"), day: part("days"),
                                         hour: part("hours"), minute: part("minutes"), second: part("seconds")),
                to: min(from.date, to.date)
            )
            #expect(added == max(from.date, to.date), "\(from.text) to \(to.text): \(breakdown)")
            #expect(part("months") < 12 && part("hours") < 24 && part("minutes") < 60 && part("seconds") < 60)
        }
    }
}
