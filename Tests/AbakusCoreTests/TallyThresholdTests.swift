@testable import AbakusCore
import Foundation
import Testing

@Suite struct TallyThresholdParsingTests {
    private func parse(_ value: JSONValue) throws(ToolError) -> [Threshold] {
        var numbers = NumberReading()
        return try Threshold.parseList(value, numbers: &numbers)
    }

    @Test func readsEachKindAndDefaultsToTheValue() throws {
        let thresholds = try parse([["limit": 20], ["at": [50, 10, 10]], ["every": 5, "of": "count"]])
        #expect(thresholds == [
            Threshold(.limit(20)),
            Threshold(.at([10, 50])),
            Threshold(.every(5), of: .count),
        ])
    }

    @Test func numberStringsAreReadAndRemembered() throws {
        var numbers = NumberReading()
        let thresholds = try Threshold.parseList([["limit": "2.5"], ["at": ["10", 20]]], numbers: &numbers)
        #expect(thresholds == [Threshold(.limit(TallyTest.decimal("2.5"))), Threshold(.at([10, 20]))])
        #expect(numbers.reads == [NumberRead(input: "2.5", value: TallyTest.decimal("2.5")), NumberRead(input: "10", value: 10)])
        // "2.5" reads only with "." (one digit after the mark cannot be a group of three): no second reading.
        #expect(numbers.otherReadings.noted == nil)
    }

    /// The decimal note names the argument as errors do, with the index the agent gave, before sorting.
    @Test func aSecondReadingIsNotedWithItsLabel() throws {
        var numbers = NumberReading()
        _ = try Threshold.parseList([["limit": 20], ["at": [5000, "1.000"]]], numbers: &numbers)
        #expect(numbers.otherReadings.noted == .init(label: "thresholds[1].at[1]", text: "1.000", value: 1, other: 1000))
    }

    /// On the count only whole numbers go, so a second reading with a fraction is no reading at all: it rules the
    /// other mark out, as a string the other mark cannot read does.
    @Test func onTheCountASecondReadingMustBeWhole() throws {
        var whole = NumberReading()
        _ = try Threshold.parseList([["at": ["1,000"], "of": "count"]], numbers: &whole)
        #expect(whole.otherReadings.noted == .init(label: "thresholds[0].at[0]", text: "1,000", value: 1000, other: 1))
        var refused = NumberReading()
        _ = try Threshold.parseList([["every": "1,234", "of": "count"], ["limit": "2,500"]], numbers: &refused)
        #expect(refused.otherReadings.noted == nil)  // 1.234 cannot be a mark on the count
        #expect(refused.otherReadings.ruledOut)
    }

    /// At most five thresholds in an argument (files are not held to it); any number of marks.
    @Test func atMostFiveThresholdsButAnyNumberOfMarks() throws {
        let five: JSONValue = .array((1...5).map { ["limit": .number(String($0))] })
        #expect(try parse(five).count == 5)
        let marks: JSONValue = [["at": .array((1...500).map { .number(String($0)) })]]
        #expect(try parse(marks) == [Threshold(.at((1...500).map { Decimal($0) }))])

        let six: JSONValue = .array((1...6).map { ["limit": .number(String($0))] })
        let error = try #require(throws: ToolError.self) { try parse(six) }
        #expect(error.message == """
            thresholds has 6 items, and a tally takes at most 5. Pass at most 5: one at threshold takes any number of \
            marks, so marks on the value (or on the count) fit in one, e.g. {"at": [10, 50, 100]}. To watch more, \
            create a second tally with the others and add to both.
            """)
    }

    @Test(arguments: [
        (JSONValue.object(["limit": 20]), "must be a list"),
        ([20], "must be an object"),
        ([["limt": 20]], "unknown key \"limt\""),
        ([["of": "count"]], "has none"),
        ([["limit": 20, "every": 5]], "has limit and every"),
        ([["limit": 20, "of": "items"]], "of must be \"value\" or \"count\""),
        ([["every": 0]], "greater than 0"),
        ([["every": -5]], "greater than 0"),
        ([["at": []]], "non-empty list"),
        ([["at": 10]], "non-empty list"),
        ([["limit": "lots"]], "thresholds[0].limit"),
        ([["limit": 20], ["at": [1, "x"]]], "thresholds[1].at[1]"),
        ([["every": .number("2.5"), "of": "count"]], "whole numbers"),
        ([["limit": .number("0.5"), "of": "count"]], "whole numbers"),
    ] as [(JSONValue, String)])
    func refusesWhatItCannotUse(value: JSONValue, expected: String) throws {
        let error = try #require(throws: ToolError.self) { try parse(value) }
        #expect(error.message.contains(expected), "\(error.message)")
    }
}

extension String {
    fileprivate var asNumber: JSONValue { .number(self) }
}

@Suite struct TallyThresholdCrossingTests {
    private func tally(value: String = "0", count: Int = 0) -> Tally {
        TallyTest.tally("t", value: value, count: count)
    }

    private func crossing(_ threshold: Threshold, _ from: String, _ to: String) throws -> JSONObject? {
        try threshold.crossing(from: tally(value: from), to: tally(value: to))
    }

    @Test func aMarkIsCrossedWhenReachedOrPassedGoingUp() throws {
        let marks = Threshold(.at([10, 15, 20]))
        #expect(try crossing(marks, "9", "10") == ["marks_total": 3, "of": "value", "at": [10]])
        #expect(try crossing(marks, "9", "16") == ["marks_total": 3, "of": "value", "at": [10, 15]])
        #expect(try crossing(marks, "10", "14") == nil)  // 10 was reached before
        #expect(try crossing(marks, "21", "30") == nil)
    }

    @Test func goingDownReportsNothingAndGoingBackUpReportsAgain() throws {
        let marks = Threshold(.at([10]))
        #expect(try crossing(marks, "12", "5") == nil)
        #expect(try crossing(marks, "5", "10") == ["marks_total": 1, "of": "value", "at": [10]])
    }

    @Test func everyListsTheMultiplesPassed() throws {
        let period = Threshold(.every(5))
        #expect(try crossing(period, "4", "5") == ["every": 5, "of": "value", "at": [5]])
        #expect(try crossing(period, "3", "17") == ["every": 5, "of": "value", "at": [5, 10, 15]])
        #expect(try crossing(period, "5", "9") == nil)
    }

    @Test func everyCountsWhenManyMultiplesArePassed() throws {
        let period = Threshold(.every(1))
        #expect(try crossing(period, "0", "10") == ["every": 1, "of": "value", "at": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]])
        #expect(try crossing(period, "0", "250.5") == ["every": 1, "of": "value", "times": 250, "first": 1, "last": 250])
    }

    /// Near 10^38, `low + 1 == low` in 38 digits: listing the marks must not step a Decimal (it used to loop
    /// forever, holding the lock). The marks 4e38 + 1 … 4e38 + 9 are not representable, so the crossing is a
    /// count marked inexact.
    @Test func marksBeyondThirtyEightDigitsEndAndSayTheyAreInexact() throws {
        let period = Threshold(.every(1))
        let low = "400000000000000000000000000000000000000"
        let crossing = try #require(try crossing(period, low, "400000000000000000000000000000000000010"))
        #expect(crossing["times"] == 10)
        #expect(crossing["last"] == "400000000000000000000000000000000000010".asNumber)
        #expect(crossing["exact"] == false)
        #expect(try period.status(of: tally(value: low))["exact"] == false)
    }

    /// Rounding the quotient to 38 digits first would give 2e37, one above the true floor.
    @Test func multiplesAreTheFloorOfTheExactQuotient() throws {
        let x = TallyTest.decimal("39999999999999999999999999999999999999")
        #expect(try Threshold.multiples(upTo: x, of: 2) == TallyTest.decimal("19999999999999999999999999999999999999"))
        let period = Threshold(.every(2))
        let below = TallyTest.decimal("39999999999999999999999999999999999998")
        let crossing = try period.crossing(from: tally(value: below.description), to: tally(value: x.description))
        #expect(crossing == nil)  // 4e37 is the next mark, not reached
        #expect(try period.status(of: tally(value: x.description))["next"] == .number("40000000000000000000000000000000000000"))
    }

    /// Up to ten marks crossed are listed, as for every; beyond that, how many with the first and the last.
    @Test func atListsAtMostTenMarksCrossed() throws {
        let marks = Threshold(.at((1...400).map { Decimal($0) }))
        #expect(try crossing(marks, "0", "10") == ["marks_total": 400, "of": "value", "at": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]])
        #expect(try crossing(marks, "0", "11") == ["marks_total": 400, "of": "value", "times": 11, "first": 1, "last": 11])
        #expect(try crossing(marks, "149.5", "399.5") == ["marks_total": 400, "of": "value", "times": 250, "first": 150, "last": 399])
        #expect(Threshold.listedMarks == 10)
    }

    /// The binary searches give what a scan of the marks gives, at the marks themselves and between them.
    @Test func atAgreesWithAScanOfTheMarks() throws {
        let marks = ["-5", "0", "2.5", "10", "15", "20"].map(TallyTest.decimal)
        let threshold = Threshold(.at(marks))
        let values = (-14...44).map { TallyTest.decimal("\($0 * 5)e-1") }  // -7 to 22 in steps of 0.5
        for old in values {
            let passed = marks.filter { $0 <= old }.count
            #expect(Threshold.marksReached(by: old, in: marks) == passed, "\(old)")
            let status = try threshold.status(of: tally(value: old.description))
            #expect(status["passed"] == .number(String(passed)))
            #expect(status["ahead"] == .array(marks.filter { $0 > old }.prefix(5).map(JSONValue.decimal)), "\(old)")
            for new in values where new > old {
                let crossed = marks.filter { old < $0 && $0 <= new }
                let expected: JSONObject? = crossed.isEmpty ? nil : ["marks_total": 6, "of": "value", "at": .array(crossed.map(JSONValue.decimal))]
                #expect(try threshold.crossing(from: tally(value: old.description), to: tally(value: new.description)) == expected, "\(old) to \(new)")
            }
        }
        #expect(Threshold.marksReached(by: 1, in: []) == 0)
    }

    @Test func everyMarksArePositiveMultiples() throws {
        let period = Threshold(.every(5))
        #expect(try crossing(period, "-12", "-1") == nil)
        #expect(try crossing(period, "-7", "6") == ["every": 5, "of": "value", "at": [5]])
    }

    @Test func everyWorksWithDecimalPeriods() throws {
        let period = Threshold(.every(TallyTest.decimal("0.25")))
        #expect(try crossing(period, "0.2", "0.8") == ["every": .number("0.25"), "of": "value", "at": [.number("0.25"), .number("0.5"), .number("0.75")]])
        #expect(try Threshold.multiples(upTo: TallyTest.decimal("1"), of: TallyTest.decimal("0.1")) == 10)
        #expect(try Threshold.multiples(upTo: TallyTest.decimal("0.99"), of: TallyTest.decimal("0.1")) == 9)
    }

    @Test func aLimitIsCrossedOnceAndItsStatusAlwaysShows() throws {
        let limit = Threshold(.limit(20))
        #expect(try crossing(limit, "18", "20") == ["limit": 20, "of": "value"])
        #expect(try crossing(limit, "20", "25") == nil)
        #expect(try limit.status(of: tally(value: "13")) == ["limit": 20, "of": "value", "reached": false, "remaining": 7])
        #expect(try limit.status(of: tally(value: "20")) == ["limit": 20, "of": "value", "reached": true, "over": 0])
        #expect(try limit.status(of: tally(value: "23.5")) == ["limit": 20, "of": "value", "reached": true, "over": .number("3.5")])
    }

    /// An at threshold shows how many marks it has, how many are passed (at or below the current value) and the
    /// marks ahead, at most 5: an agent that lost its request still sees what comes next, and the status has the
    /// same size for 7 marks or 2000. [] once all are passed, as crossed is [] when nothing was crossed.
    @Test func statusGivesTheMarksAhead() throws {
        let marks = Threshold(.at([10, 20]))
        #expect(try marks.status(of: tally(value: "-5")) == ["marks_total": 2, "of": "value", "passed": 0, "ahead": [10, 20]])
        #expect(try marks.status(of: tally(value: "10")) == ["marks_total": 2, "of": "value", "passed": 1, "ahead": [20]])
        #expect(try marks.status(of: tally(value: "19.99")) == ["marks_total": 2, "of": "value", "passed": 1, "ahead": [20]])
        #expect(try marks.status(of: tally(value: "20")) == ["marks_total": 2, "of": "value", "passed": 2, "ahead": []])
        // The two cases of the approved preview.
        #expect(try Threshold(.at([50, 100, 150])).status(of: tally(value: "60")) == ["marks_total": 3, "of": "value", "passed": 1, "ahead": [100, 150]])
        let hundreds = Threshold(.at((1...200).map { Decimal($0) }))
        #expect(try hundreds.status(of: tally(value: "18.5")) == ["marks_total": 200, "of": "value", "passed": 18, "ahead": [19, 20, 21, 22, 23]])
        let many = Threshold(.at((1...2000).map { Decimal($0 * 1000) }), of: .count)
        #expect(try many.status(of: tally(count: 2500)) == ["marks_total": 2000, "of": "count", "passed": 2, "ahead": [3000, 4000, 5000, 6000, 7000]])
        #expect(Threshold.marksAhead == 5)
    }

    /// The worst case per at threshold is fixed: five marks of 38 significant digits.
    @Test func theMarksAheadKeepTheStatusBounded() throws {
        let long = (1...200).map { TallyTest.decimal(String(repeating: "9", count: 34) + String(1000 + $0)) }
        #expect(long[0].description.count == 38)
        let status = try Threshold(.at(long)).status(of: tally(value: "0"))
        #expect(status["ahead"]?.arrayValue?.count == 5)
        #expect(JSONWriter.write(status).count <= 260, "\(JSONWriter.write(status).count)")
    }

    @Test func everyStatusGivesTheNextMark() throws {
        #expect(try Threshold(.every(5)).status(of: tally(value: "0")) == ["every": 5, "of": "value", "next": 5])
        #expect(try Threshold(.every(5)).status(of: tally(value: "10")) == ["every": 5, "of": "value", "next": 15])
        #expect(try Threshold(.every(5)).status(of: tally(value: "-3")) == ["every": 5, "of": "value", "next": 5])
    }

    @Test func countThresholdsWatchTheCount() throws {
        let checkpoint = Threshold(.every(5), of: .count)
        let before = tally(value: "100", count: 4), after = tally(value: "90", count: 5)
        #expect(try checkpoint.crossing(from: before, to: after) == ["every": 5, "of": "count", "at": [5]])
        #expect(try checkpoint.status(of: after) == ["every": 5, "of": "count", "next": 10])
    }
}
