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

@Suite struct TallyThresholdCrossingTests {
    private func tally(value: String = "0", count: Int = 0) -> Tally {
        TallyTest.tally("t", value: value, count: count)
    }

    private func crossing(_ threshold: Threshold, _ from: String, _ to: String) throws -> JSONObject? {
        try threshold.crossing(from: tally(value: from), to: tally(value: to))
    }

    @Test func aMarkIsCrossedWhenReachedOrPassedGoingUp() throws {
        let marks = Threshold(.at([10, 15, 20]))
        #expect(try crossing(marks, "9", "10") == ["at": [10], "of": "value"])
        #expect(try crossing(marks, "9", "16") == ["at": [10, 15], "of": "value"])
        #expect(try crossing(marks, "10", "14") == nil)  // 10 was reached before
        #expect(try crossing(marks, "21", "30") == nil)
    }

    @Test func goingDownReportsNothingAndGoingBackUpReportsAgain() throws {
        let marks = Threshold(.at([10]))
        #expect(try crossing(marks, "12", "5") == nil)
        #expect(try crossing(marks, "5", "10") == ["at": [10], "of": "value"])
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

    @Test func statusGivesTheNextMark() throws {
        #expect(try Threshold(.at([10, 20])).status(of: tally(value: "10")) == ["at": [10, 20], "of": "value", "next": 20])
        #expect(try Threshold(.at([10, 20])).status(of: tally(value: "20")) == ["at": [10, 20], "of": "value"])
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
