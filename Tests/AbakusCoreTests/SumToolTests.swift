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

    /// read grows with the list, so it is a detail: the command line prints it, an MCP result leaves it out
    /// (ADR-0008).
    @Test func readIsADetail() throws {
        #expect(tool.detailKeys == ["read"])
        let result = try sum(["numbers": ["410k", "1,234.5", 12]])
        #expect(tool.withoutDetails(result) == ["total": .number("411246.5"), "count": 3, "mean": .number("137082.166666667"), "mean_exact": false])
        #expect(tool.withoutDetails(result).keys == ["total", "count", "mean", "mean_exact"])
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
        // 15 significant digits, half away from zero.
        let result = try sum(["numbers": [1, 2, .number("3.5")]])
        #expect(result["total"] == .number("6.5"))
        #expect(result["mean"] == .number("2.16666666666667"))
        #expect(result["mean_exact"] == false)
        #expect(result.keys == ["total", "count", "mean", "mean_exact"])
        #expect(try sum(["numbers": [2, 0, 0]])["mean"] == .number("0.666666666666667"))
        #expect(try sum(["numbers": [-2, 0, 0]])["mean"] == .number("-0.666666666666667"))
        // A long integer part stays whole.
        #expect(try sum(["numbers": ["1e20", 0, 0]])["mean"] == .number("33333333333333333333"))
    }

    /// Many numbers summing to 1: the mean keeps 15 significant digits instead of a fixed number of places. (With
    /// three million numbers, six places used to give 0; DecimalMathTests checks 1 / 3,000,000 directly, as a list
    /// that long is slow in a debug build.)
    @Test func smallMeanOfManyNumbersKeepsItsDigits() throws {
        let numbers: [JSONValue] = [1] + Array(repeating: 0, count: 29_999)
        let result = try sum(["numbers": .array(numbers)])
        #expect(result["count"] == 30_000)
        #expect(result["mean"] == .number("0.0000333333333333333"))
        #expect(result["mean_exact"] == false)
        #expect(try sum(["numbers": [-1, 0, 0]])["mean"] == .number("-0.333333333333333"))
    }

    @Test func roundedTotalIsFlagged() throws {
        let result = try sum(["numbers": ["1e37", "0.1"]])
        #expect(result["total"] == .decimal(Decimal(string: "1e37", locale: Locale(identifier: "en_US_POSIX"))!))
        #expect(result["total_exact"] == false)
        #expect(result.keys == ["total", "total_exact", "count", "mean", "mean_exact", "read"])
    }

    @Test func meanBelowTheSmallestStepIsAnErrorNotZero() throws {
        // 2e-128 / 3 still rounds to the smallest step, 1e-128 ...
        #expect(try sum(["numbers": ["2e-128", 0, 0]])["mean"] == .decimal(Decimal(string: "1e-128", locale: Locale(identifier: "en_US_POSIX"))!))
        // ... 1e-128 / 3 would be 0, which would hide a non-zero mean.
        let error = try #require(failure(["numbers": ["1e-128", 0, 0]]))
        #expect(error.message.contains("below 10^-128"))
        #expect(error.message.contains("The total itself is exact"))
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

    /// An error quotes at most 100 characters of an input, cut in the middle (ADR-0008): one long string must not
    /// make the error long.
    @Test func errorsCutLongInputs() throws {
        let long = "1" + String(repeating: "x", count: 5000) + "9"
        let error = try #require(failure(["numbers": [.string(long)]]))
        let cut = "1" + String(repeating: "x", count: 49) + "…" + String(repeating: "x", count: 48) + "9"
        #expect(error.message.hasPrefix("numbers[0]: Cannot read \"\(cut)\" as a number"))
        #expect(error.text.count < 1000)
        #expect(error.details == ["index": 0, "input": .string(cut)])
        // 100 characters are quoted whole.
        let hundred = String(repeating: "x", count: 100)
        #expect(failure(["numbers": [.string(hundred)]])?.message.contains("\"\(hundred)\"") == true)
        // An unknown argument's name too.
        let name = String(repeating: "a", count: 300)
        let unknown = try #require(failure(JSONObject([("numbers", [1]), (name, 1)])))
        #expect(unknown.text.count < 400)
    }

    @Test func badArguments() {
        #expect(failure([:])?.message.contains("numbers is missing") == true)
        #expect(failure(["numbers": 5])?.message.contains("must be a list") == true)
        #expect(failure(["numbers": [1], "decimal": ";"])?.message.contains("decimal must be") == true)
        let unknown = failure(["numbers": [1], "decimal_mark": ","])
        #expect(unknown?.message == "Unknown argument \"decimal_mark\". sum takes \"numbers\" (required) and \"decimal\".")
        #expect(unknown?.details == ["argument": "decimal_mark"])
    }

    @Test func totalOverflowIsAnError() {
        let big = "9" + String(repeating: "0", count: 164)
        #expect(failure(["numbers": [.string(big), .string(big)]])?.message.contains("too large") == true)
    }
}
