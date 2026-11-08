import AbakusCore
import Foundation
import Testing

@Suite struct DecimalMathTests {
    private func d(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    }

    @Test func pointOnePlusPointTwoIsExact() throws {
        let result = try DecimalMath.add(d("0.1"), d("0.2"))
        #expect(result == .init(value: d("0.3"), exact: true))
    }

    // Foundation's NSDecimal functions never report .lossOfPrecision; DecimalMath has to detect rounding itself.
    @Test func roundingIsReported() throws {
        let result = try DecimalMath.divide(1, 3)
        withKnownIssue("rounding detection not implemented yet") { #expect(result.exact == false) }
    }

    @Test func divisionThatFitsIsExact() throws {
        let result = try DecimalMath.divide(36, 5)
        #expect(result == .init(value: d("7.2"), exact: true))
    }

    @Test func precisionLossInAdditionIsReported() throws {
        let result = try DecimalMath.add(d("1e37"), d("0.1"))
        withKnownIssue("rounding detection not implemented yet") { #expect(result.exact == false) }
    }

    @Test func divisionByZeroThrows() {
        #expect(throws: ToolError.self) { try DecimalMath.divide(1, 0) }
    }

    @Test func overflowThrows() {
        #expect(throws: ToolError.self) { try DecimalMath.multiply(d("1e100"), d("1e100")) }
    }

    @Test func sumCarriesInexactness() throws {
        let result = try DecimalMath.sum([d("1e37"), d("0.1"), 1])
        withKnownIssue("rounding detection not implemented yet") { #expect(result.exact == false) }
        #expect(try DecimalMath.sum([]) == .init(value: 0, exact: true))
    }
}
