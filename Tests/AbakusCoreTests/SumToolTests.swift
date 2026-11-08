import AbakusCore
import Foundation
import Testing

@Suite struct SumToolTests {
    private let tool = SumTool()
    /// sum writes nothing; the folder is never created.
    private let context = ToolContext(stateDirectory: FileManager.default.temporaryDirectory.appending(path: "abakus-tests-\(UUID())"))

    private func sum(_ arguments: JSONObject) throws(ToolError) -> JSONObject {
        try tool.call(arguments, in: context)
    }

    private func failure(_ arguments: JSONObject) -> ToolError? {
        do {
            _ = try sum(arguments)
            return nil
        } catch {
            return error
        }
    }

    @Test func isListed() {
        #expect(ArithmeticTools.all.contains { $0.name == "sum" })
        #expect(Catalog.tool(named: "sum") != nil)
    }

    @Test func annotationsAndSchema() throws {
        #expect(tool.annotations == ToolAnnotations(title: "Exact sum", readOnly: true, destructive: false, idempotent: true))
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["type"] == "object")
        #expect(schema["required"] == ["numbers"])
        #expect(schema["additionalProperties"] == false)
        #expect(schema["properties"]?.objectValue?.keys == ["numbers", "decimal"])
        #expect(tool.description.contains(NumberReader.rulesSummary))
    }

    @Test func addsExactly() throws {
        let result = try sum(["numbers": [.number("0.1"), .number("0.2")]])
        #expect(result == ["total": .number("0.3"), "count": 2, "mean": .number("0.15")])
        #expect(result.keys == ["total", "count", "mean"])
    }

    @Test func showsHowStringsWereRead() throws {
        let result = try sum(["numbers": ["410k", "1,234.5", 12, " 7 "]])
        #expect(result["total"] == .number("411253.5"))
        #expect(result["count"] == 4)
        #expect(result["read"] == [
            ["index": 0, "input": "410k", "value": 410000],
            ["index": 1, "input": "1,234.5", "value": .number("1234.5")],
            ["index": 3, "input": " 7 ", "value": 7],
        ])
        #expect(result.keys == ["total", "count", "mean", "read"])
    }

    @Test func decimalComma() throws {
        let result = try sum(["numbers": ["1.234,5", "0,5", .number("1.5")], "decimal": ","])
        #expect(result["total"] == .number("1236.5"))
        #expect(result["read"]?.arrayValue?.map { $0.objectValue?["value"] } == [.number("1234.5"), .number("0.5")])
        // The same strings with "." as the decimal mark: 1.234 + error.
        #expect(failure(["numbers": ["1.234,5"]]) != nil)
    }

    @Test func meanIsExactWhenItFits() throws {
        #expect(try sum(["numbers": [1, 2]])["mean"] == .number("1.5"))
        #expect(try sum(["numbers": [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]])["mean"] == .number("0.0625"))
        #expect(try sum(["numbers": [1, 2]])["mean_exact"] == nil)
    }

    @Test func meanThatDoesNotTerminateIsRoundedAndFlagged() throws {
        // Most precise input: 1 decimal place, so the mean gets 1 + 6 = 7.
        let result = try sum(["numbers": [1, 2, .number("3.5")]])
        #expect(result["total"] == .number("6.5"))
        #expect(result["mean"] == .number("2.1666667"))
        #expect(result["mean_exact"] == false)
        #expect(result.keys == ["total", "count", "mean", "mean_exact"])
        // Integers: 6 places, half away from zero.
        #expect(try sum(["numbers": [2, 0, 0]])["mean"] == .number("0.666667"))
        #expect(try sum(["numbers": [-2, 0, 0]])["mean"] == .number("-0.666667"))
    }

    @Test func roundedTotalIsFlagged() throws {
        let result = try sum(["numbers": ["1e37", "0.1"]])
        #expect(result["total"] == .decimal(Decimal(string: "1e37", locale: Locale(identifier: "en_US_POSIX"))!))
        #expect(result["total_exact"] == false)
        #expect(result.keys == ["total", "total_exact", "count", "mean", "mean_exact", "read"])
    }

    @Test func meanTooSmallToShowIsZeroNotAnError() throws {
        let result = try sum(["numbers": ["1e-128", 0, 0]])
        #expect(result["total"] == .decimal(Decimal(string: "1e-128", locale: Locale(identifier: "en_US_POSIX"))!))
        #expect(result["mean"] == 0)
        #expect(result["mean_exact"] == false)
    }

    @Test func emptyListIsZero() throws {
        #expect(try sum(["numbers": []]) == ["total": 0, "count": 0, "mean": nil])
    }

    @Test func unreadableNumberNamesItsIndex() throws {
        let error = try #require(failure(["numbers": [1, "12%"]]))
        #expect(error.message.hasPrefix("numbers[1]: Cannot read \"12%\" as a number"))
        #expect(error.details == ["index": 1, "input": "12%"])
        #expect(failure(["numbers": [1, true]])?.message.hasPrefix("numbers[1]: Expected a number") == true)
    }

    @Test func badArguments() {
        #expect(failure([:])?.message.contains("numbers is missing") == true)
        #expect(failure(["numbers": 5])?.message.contains("must be a list") == true)
        #expect(failure(["numbers": [1], "decimal": ";"])?.message.contains("decimal must be") == true)
        #expect(failure(["numbers": [1], "decimal_mark": ","])?.message.contains("Unknown argument \"decimal_mark\"") == true)
    }

    @Test func totalOverflowIsAnError() {
        let big = "9" + String(repeating: "0", count: 164)
        #expect(failure(["numbers": [.string(big), .string(big)]])?.message.contains("too large") == true)
    }
}
