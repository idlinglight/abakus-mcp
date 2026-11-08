import AbakusCore
import Foundation
import Testing

private func d(_ text: String) -> Decimal {
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("Foundation cannot read the test literal \(text)")
    }
    return value
}

@Suite struct NumberReaderTests {
    @Test(arguments: [
        // Plain numbers and whitespace
        ("42", "42"), (" 42 ", "42"), ("\t42\n", "42"), ("007", "7"),
        // Signs: + is allowed, -0 is 0, the Unicode minus sign counts as minus
        ("-12", "-12"), ("+5", "5"), ("\u{2212}5", "-5"), ("-0", "0"),
        // Fractions, a leading decimal mark included
        ("0.5", "0.5"), (".5", "0.5"), ("-.5", "-0.5"), ("123.456", "123.456"),
        // Grouping with the other mark, in threes
        ("1,234", "1234"), ("1,234,567.5", "1234567.5"), ("-1,000", "-1000"), ("999,999.99", "999999.99"),
        // Exponents
        ("2.5e3", "2500"), ("2.5E-3", "0.0025"), ("1e+2", "100"), ("1e\u{2212}3", "0.001"),
        // Suffixes
        ("410k", "410000"), ("410K", "410000"), ("1.5M", "1500000"), ("2G", "2000000000"),
        ("3T", "3000000000000"), ("1,234k", "1234000"), ("-2.5k", "-2500"), (".5k", "500"),
        // Limits: 38 significant digits, 10^164, 10^-128; trailing zeros are not significant
        ("12345678901234567890123456789012345678", "12345678901234567890123456789012345678"),
        ("1e164", "10000000000000000000000000000000000000e127"), ("1e-128", "1e-128"),
        ("1" + String(repeating: "0", count: 50), "10000000000000000000000000000000000000e13"),
        ("0e999999999", "0"), ("0.000", "0"),
    ])
    func readsWithDecimalPoint(input: String, expected: String) throws {
        #expect(try NumberReader.read(.string(input), decimal: .point) == d(expected), "\(input)")
        // Without decimal, the point is the default.
        #expect(try NumberReader.read(.string(input)) == d(expected), "\(input)")
    }

    @Test(arguments: [
        ("1.234", "1234"), ("1.234,5", "1234.5"), ("1,234", "1.234"), ("1,23", "1.23"), ("0,5", "0.5"),
        (",5", "0.5"), ("1.234.567,89", "1234567.89"), ("1,5M", "1500000"), ("410k", "410000"),
        ("-1.234,5e2", "-123450"), (" 42 ", "42"), ("+1,5", "1.5"),
    ])
    func readsWithDecimalComma(input: String, expected: String) throws {
        #expect(try NumberReader.read(.string(input), decimal: .comma) == d(expected), "\(input)")
    }

    @Test(arguments: [
        // Grouping that is not in threes, or could be a decimal comma
        "1,23", "12,5", "1,2345", "1234,567", "0,123", ",5", "1,", "1,,234",
        // Decimal marks
        "5.", ".", "1.234.567", "1,234.5.6", "1.5,3",
        // Units, currency, percent, other notations
        "12%", "€5", "5 €", "$1,000", "5kg", "0x10", "1_000", "NaN", "Infinity", "\u{0661}\u{0662}", "\u{2013}5",
        // Whitespace
        "", "   ", "1 234", "410 k", "1.5 M",
        // Signs, exponents, suffixes
        "--5", "+-5", "5-", "1e", "1e+", "e3", "1e3k", "5kk", "5m", "1.5m",
        // Out of range or more digits than Decimal holds: errors, never rounded
        "1e400", "1e-400", "1e165", "1.5e-128", "123456789012345678901234567890123456789",
    ])
    func refusesWithDecimalPoint(input: String) {
        #expect(throws: ToolError.self, "\(input)") { try NumberReader.read(.string(input), decimal: .point) }
    }

    @Test(arguments: [
        "1,234,567", "1.23", "1.5M", "0.5", "1,234.5", "5,", "12%", "1.2345", "1 234,5",
    ])
    func refusesWithDecimalComma(input: String) {
        #expect(throws: ToolError.self, "\(input)") { try NumberReader.read(.string(input), decimal: .comma) }
    }

    @Test func errorsNameTheInputAndSayWhatIsAccepted() throws {
        let grouping = try #require(error("1,23"))
        #expect(grouping.message.contains("\"1,23\""))
        #expect(grouping.message.contains("decimal: \",\""))
        #expect(grouping.message.contains("Accepted:"))
        #expect(grouping.details == ["input": "1,23"])

        #expect(message("1.23", .comma).contains("1.234.567,5"))
        #expect(message("").contains("\"\" as a number: the string is empty"))
        #expect(message("5m").contains("milli"))
        #expect(message("410 k").contains("410k, not 410 k"))
        #expect(message("12%").contains("\"%\" is not part of a number"))
        #expect(message("1e3k").contains("cannot be combined"))
        #expect(message("1e400").contains("too large"))
        #expect(message("1.5e-128").contains("10^-128"))
        #expect(message("1.234.567").contains("pass decimal: \",\""))
        #expect(message(true).contains("got true"))
    }

    @Test(arguments: [("0.1", "0.1"), ("-0", "0"), ("2.5e3", "2500"), ("1E-2", "0.01"), ("123456", "123456")])
    func readsJSONNumbers(literal: String, expected: String) throws {
        #expect(try NumberReader.read(.number(literal)) == d(expected))
        // A JSON number always uses "."; the decimal argument is for strings.
        #expect(try NumberReader.read(.number(literal), decimal: .comma) == d(expected))
    }

    @Test(arguments: ["01", "1.", ".5", "+1", "1e", "0x1", "1,5", "1k", " 1", "", "NaN", "1E400", "1e-129",
                      "12345678901234567890123456789012345678901"])
    func refusesInvalidOrUnholdableJSONNumbers(literal: String) {
        #expect(throws: ToolError.self, "\(literal)") { try NumberReader.read(.number(literal)) }
    }

    @Test(arguments: [JSONValue.null, true, [1], ["a": 1]])
    func refusesOtherTypes(value: JSONValue) {
        #expect(throws: ToolError.self) { try NumberReader.read(value) }
    }

    @Test func decimalArgument() throws {
        #expect(try DecimalMark.argument(nil) == .point)
        #expect(try DecimalMark.argument(.null) == .point)
        #expect(try DecimalMark.argument(".") == .point)
        #expect(try DecimalMark.argument(",") == .comma)
        #expect(throws: ToolError.self) { try DecimalMark.argument(";") }
        #expect(throws: ToolError.self) { try DecimalMark.argument("comma") }
        #expect(throws: ToolError.self) { try DecimalMark.argument(1) }
    }

    @Test func rulesSummaryStatesTheRules() {
        for part in ["decimal mark", "\",\"", "thousands", "2.5e3", "k/K, M, G, T", "lowercase m", "%"] {
            #expect(NumberReader.rulesSummary.contains(part), "\(part)")
        }
    }

    private func error(_ value: JSONValue, _ decimal: DecimalMark = .point) -> ToolError? {
        do {
            _ = try NumberReader.read(value, decimal: decimal)
            return nil
        } catch {
            return error
        }
    }

    private func message(_ value: JSONValue, _ decimal: DecimalMark = .point) -> String {
        error(value, decimal)?.message ?? "(no error)"
    }
}
