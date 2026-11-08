import AbakusCore
import Foundation
import Testing

/// A test literal. Foundation's parser does not move exponent digits into the significand: write `90e127`, not
/// `9e128`.
private func d(_ text: String) -> Decimal {
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
        fatalError("Foundation cannot read the test literal \(text)")
    }
    return value
}

@Suite struct DecimalMathTests {
    @Test func pointOnePlusPointTwoIsExact() throws {
        let result = try DecimalMath.add(d("0.1"), d("0.2"))
        #expect(result == .init(value: d("0.3"), exact: true))
    }

    @Test func roundingIsReported() throws {
        let result = try DecimalMath.divide(1, 3)
        #expect(result == .init(value: d("0.33333333333333333333333333333333333333"), exact: false))
    }

    // Foundation truncates here (0.666...666); DecimalMath rounds half away from zero.
    @Test func divisionRoundsTheLastDigit() throws {
        #expect(try DecimalMath.divide(2, 3) == .init(value: d("0.66666666666666666666666666666666666667"), exact: false))
        #expect(try DecimalMath.divide(-2, 3) == .init(value: d("-0.66666666666666666666666666666666666667"), exact: false))
    }

    @Test func divisionThatFitsIsExact() throws {
        let result = try DecimalMath.divide(36, 5)
        #expect(result == .init(value: d("7.2"), exact: true))
    }

    @Test func precisionLossInAdditionIsReported() throws {
        let result = try DecimalMath.add(d("1e37"), d("0.1"))
        #expect(result == .init(value: d("1e37"), exact: false))
    }

    @Test func halfRoundsAwayFromZero() throws {
        #expect(try DecimalMath.add(d("1e37"), d("0.5")) == .init(value: d("10000000000000000000000000000000000001"), exact: false))
        #expect(try DecimalMath.subtract(d("-1e37"), d("0.5")) == .init(value: d("-10000000000000000000000000000000000001"), exact: false))
        // Foundation truncates this to 38 nines.
        let nines = d("99999999999999999999999999999999999999")
        #expect(try DecimalMath.add(nines, d("0.5")) == .init(value: d("1e38"), exact: false))
        #expect(try DecimalMath.add(nines, d("0.4")) == .init(value: nines, exact: false))
    }

    @Test func thirtyEightDigitsAreExact() throws {
        let result = try DecimalMath.add(d("12345678901234567890123456789012345678"), 0)
        #expect(result == .init(value: d("12345678901234567890123456789012345678"), exact: true))
        #expect(try DecimalMath.multiply(d("1234567890123456789"), d("1234567890123456789")).exact == true)
        // 152415787532388367625361988887364731025 has 39 digits; the last one, a 5, rounds up.
        #expect(try DecimalMath.multiply(d("12345678901234567895"), d("12345678901234567895"))
            == .init(value: d("15241578753238836762536198888736473103e1"), exact: false))
    }

    @Test func divisionByZeroThrows() {
        #expect(throws: ToolError.self) { try DecimalMath.divide(1, 0) }
    }

    @Test func overflowThrows() {
        #expect(throws: ToolError.self) { try DecimalMath.multiply(d("1e100"), d("1e100")) }
        #expect(throws: ToolError.self) { try DecimalMath.add(d("99999999999999999999999999999999999999e127"), d("1e127")) }
    }

    @Test func largeExponentsWithinRangeAreExact() throws {
        #expect(try DecimalMath.multiply(d("1e127"), 10) == .init(value: d("10e127"), exact: true))
        #expect(try DecimalMath.multiply(d("1e-64"), d("1e-64")) == .init(value: d("1e-128"), exact: true))
    }

    // Foundation wraps the exponent around here and returns 1e56.
    @Test func underflowThrows() {
        #expect(throws: ToolError.self) { try DecimalMath.multiply(d("1e-100"), d("1e-100")) }
        #expect(throws: ToolError.self) { try DecimalMath.divide(d("1e-128"), 3) }
    }

    @Test func digitsBelowTheSmallestExponentAreRoundedOff() throws {
        #expect(try DecimalMath.multiply(d("15e-128"), d("0.1")) == .init(value: d("2e-128"), exact: false))
    }

    @Test func sumRoundsOnlyTheTotal() throws {
        let result = try DecimalMath.sum([d("1e37"), d("0.1"), 1])
        #expect(result == .init(value: d("10000000000000000000000000000000000001"), exact: false))
        #expect(try DecimalMath.sum([]) == .init(value: 0, exact: true))
        // Added step by step, 1e38 + 0.4 would round; the exact total does not need to.
        #expect(try DecimalMath.sum([d("1e38"), d("0.4"), d("-0.4")]) == .init(value: d("1e38"), exact: true))
        // No intermediate overflow either.
        let big = d("9" + String(repeating: "0", count: 37) + "e127") // 9e164
        #expect(try DecimalMath.sum([big, big, -big]) == .init(value: big, exact: true))
    }

    @Test(arguments: [
        // Exact when the quotient fits.
        ("1", "8", "0.125", true), ("1", "1024", "0.0009765625", true), ("36", "5", "7.2", true),
        // Otherwise 15 significant digits, half away from zero.
        ("1", "3", "0.333333333333333", false), ("2", "3", "0.666666666666667", false),
        ("-2", "3", "-0.666666666666667", false), ("6.5", "3", "2.16666666666667", false),
        // Small quotients keep their digits: never 0, never a lost sign.
        ("1", "30000000000", "0.0000000000333333333333333", false),
        ("1", "3000000", "0.000000333333333333333", false), ("-1", "3000000", "-0.000000333333333333333", false),
        // A longer integer part is kept in whole units, up to 38 digits.
        ("1e20", "3", "33333333333333333333", false), ("1e30", "7", "142857142857142857142857142857", false),
        ("1e40", "3", "33333333333333333333333333333333333333e2", false),
        // Below 10^-128 the digits run out, but a non-zero quotient still does not become 0.
        ("2e-128", "3", "1e-128", false),
    ])
    func readableQuotient(a: String, b: String, expected: String, exact: Bool) throws {
        #expect(try DecimalMath.readableQuotient(d(a), d(b)) == .init(value: d(expected), exact: exact), "\(a) / \(b)")
    }

    @Test func readableQuotientErrors() {
        #expect(throws: ToolError.self) { try DecimalMath.readableQuotient(1, 0) }
        // 1e-128 / 3 rounds to 0 at Decimal's smallest step: an underflow, not a silent 0.
        #expect(throws: ToolError.self) { try DecimalMath.readableQuotient(d("1e-128"), 3) }
    }

    @Test(arguments: [
        ("2.5", 0, DecimalMath.RoundingMode.down, "2", false), ("2.5", 0, .up, "3", false),
        ("2.5", 0, .towardZero, "2", false), ("2.5", 0, .halfAwayFromZero, "3", false),
        ("-2.5", 0, .down, "-3", false), ("-2.5", 0, .up, "-2", false),
        ("-2.5", 0, .towardZero, "-2", false), ("-2.5", 0, .halfAwayFromZero, "-3", false),
        ("2.49", 0, .halfAwayFromZero, "2", false), ("-2.49", 0, .halfAwayFromZero, "-2", false),
        ("7", 0, .down, "7", true), ("-7", 0, .up, "-7", true),
        ("1234.5678", 2, .halfAwayFromZero, "1234.57", false), ("1234.5678", 2, .down, "1234.56", false),
        ("1234.5678", -2, .halfAwayFromZero, "1200", false), ("1234.5678", -2, .up, "1300", false),
        ("-0.001", 2, .halfAwayFromZero, "0", false), ("-0.001", 2, .down, "-0.01", false),
        ("0.5", 0, .down, "0", false), ("1e100", 0, .down, "1e100", true), ("1e-128", 128, .down, "1e-128", true),
    ])
    func roundedToPlaces(value: String, places: Int, mode: DecimalMath.RoundingMode, expected: String, exact: Bool) throws {
        #expect(try DecimalMath.rounded(d(value), toPlaces: places, mode) == .init(value: d(expected), exact: exact),
                "\(value) to \(places) places, \(mode)")
    }

    @Test func divisionToPlacesIsExactNotRoundedTwice() throws {
        #expect(try DecimalMath.divide(7, 2, toPlaces: 0, .down) == .init(value: 3, exact: false))
        #expect(try DecimalMath.divide(-7, 2, toPlaces: 0, .down) == .init(value: -4, exact: false))
        #expect(try DecimalMath.divide(6, 2, toPlaces: 0, .down) == .init(value: 3, exact: true))
        // 19999999999999999999999999999999999999.5: to 38 digits that is 2e37, but its floor is one less.
        let nines = d("39999999999999999999999999999999999999")
        #expect(try DecimalMath.divide(nines, 2).value == d("2e37"))
        #expect(try DecimalMath.divide(nines, 2, toPlaces: 0, .down) == .init(value: d("19999999999999999999999999999999999999"), exact: false))
    }

    @Test func roundingToPlacesErrors() throws {
        #expect(throws: ToolError.self) { try DecimalMath.rounded(1, toPlaces: 129, .down) }
        #expect(throws: ToolError.self) { try DecimalMath.rounded(1, toPlaces: -166, .down) }
        #expect(try DecimalMath.rounded(1, toPlaces: -165, .down) == .init(value: 0, exact: false))
        #expect(throws: ToolError.self) { try DecimalMath.divide(1, 0, toPlaces: 0, .down) }
        // More than 38 digits at 0 places, and 10^165 after rounding up.
        #expect(throws: ToolError.self) { try DecimalMath.divide(d("1e100"), 3, toPlaces: 0, .down) }
        #expect(throws: ToolError.self) { try DecimalMath.rounded(d("99999999999999999999999999999999999999e127"), toPlaces: -164, .up) }
    }

    @Test func floorAndIsInteger() {
        #expect(DecimalMath.floor(d("2.7")) == 2)
        #expect(DecimalMath.floor(d("-2.7")) == -3)
        #expect(DecimalMath.floor(d("-0.5")) == -1)
        #expect(DecimalMath.floor(5) == 5)
        #expect(DecimalMath.floor(0) == 0)
        #expect(DecimalMath.floor(d("1e100")) == d("1e100"))
        #expect(DecimalMath.floor(d("-9999999999999999999999999999999999999.5")) == d("-1e37"))
        #expect(DecimalMath.floor(.nan).isNaN)

        #expect(DecimalMath.isInteger(5))
        #expect(DecimalMath.isInteger(-3))
        #expect(DecimalMath.isInteger(0))
        #expect(DecimalMath.isInteger(d("5.000")))
        #expect(DecimalMath.isInteger(d("1e100")))
        #expect(!DecimalMath.isInteger(d("0.5")))
        #expect(!DecimalMath.isInteger(d("-12.0001")))
        #expect(!DecimalMath.isInteger(d("1e-128")))
        #expect(!DecimalMath.isInteger(.nan))
    }
}

/// Checks DecimalMath against an independent oracle (digit arrays, schoolbook arithmetic) on random operands:
/// every result must be the exact result rounded once, half away from zero, to 38 significant digits, and
/// `exact` must be true exactly when nothing was rounded.
@Suite struct DecimalMathRandomizedTests {
    @Test func agreesWithDigitOracle() throws {
        var random = SplitMix64(seed: 0x00ab_a4c5)
        var outcomes: [String: Int] = [:]
        defer {
            // The operands must reach every outcome, or the check proves little.
            for outcome in ["exact", "rounded", "overflow", "underflow"] {
                #expect(outcomes[outcome, default: 0] >= 50, "only \(outcomes[outcome, default: 0]) \(outcome) results")
            }
        }
        for _ in 0..<1500 {
            let a = DigitNumber.random(using: &random)
            let b = DigitNumber.random(using: &random)
            let (x, y) = (a.decimal, b.decimal)
            // The generator only produces values a Decimal holds exactly.
            try #require(DigitNumber(x.description) == a, "operand \(a)")
            try #require(DigitNumber(y.description) == b, "operand \(b)")

            check("add", a, b, into: &outcomes, try? DecimalMath.add(x, y), expected: (a + b).roundedToDecimal())
            check("subtract", a, b, into: &outcomes, try? DecimalMath.subtract(x, y), expected: (a + -b).roundedToDecimal())
            check("multiply", a, b, into: &outcomes, try? DecimalMath.multiply(x, y), expected: (a * b).roundedToDecimal())
            if b.isZero {
                #expect(throws: ToolError.self) { try DecimalMath.divide(x, y) }
            } else {
                let quotient = DigitNumber.quotient(a, b)
                let result = try? DecimalMath.divide(x, y)
                check("divide", a, b, into: &outcomes, result, expected: quotient.roundedToDecimal())
                // exact means result × divisor == dividend, with nothing left over.
                if let result {
                    #expect((DigitNumber(result.value.description) * b == a) == result.exact, "divide \(a) / \(b)")
                }
                check("readableQuotient", a, b, into: &outcomes, try? DecimalMath.readableQuotient(x, y),
                      expected: quotient.roundedReadably())

                let places = Int.random(in: -5...20, using: &random)
                let mode = DecimalMath.RoundingMode.allCases.randomElement(using: &random)!
                check("divide to \(places) places \(mode)", a, b, into: &outcomes,
                      try? DecimalMath.divide(x, y, toPlaces: places, mode),
                      expected: DigitNumber.quotient(a, b, downTo: -places - 1).roundedToPlaces(places, mode))
            }
        }
    }

    private func check(
        _ operation: String, _ a: DigitNumber, _ b: DigitNumber, into outcomes: inout [String: Int],
        _ result: DecimalMath.Result?, expected: DigitNumber.Rounding
    ) {
        switch expected {
        case .overflow: outcomes["overflow", default: 0] += 1
        case .underflow: outcomes["underflow", default: 0] += 1
        case .value(_, let exact): outcomes[exact ? "exact" : "rounded", default: 0] += 1
        }
        switch expected {
        case .overflow, .underflow:
            #expect(result == nil, "\(operation) \(a), \(b) should throw (\(expected))")
        case .value(let value, let exact):
            guard let result else {
                Issue.record("\(operation) \(a), \(b) threw; expected \(value)")
                return
            }
            #expect(DigitNumber(result.value.description) == value, "\(operation) \(a), \(b)")
            #expect(result.exact == exact, "\(operation) \(a), \(b): exact")
        }
    }
}

// MARK: - Oracle

/// SplitMix64: a small, seedable generator, so a failure can be replayed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// An exact decimal as a digit array: `±digits × 10^exponent`. Deliberately simple, and independent of the big
/// integers in AbakusCore.
private struct DigitNumber: Equatable, CustomStringConvertible {
    var negative: Bool
    /// Most significant first, no leading or trailing zeros; empty for zero.
    var digits: [UInt8]
    var exponent: Int

    init(negative: Bool, digits: [UInt8], exponent: Int) {
        var digits = Array(digits.drop { $0 == 0 })
        var exponent = exponent
        while digits.last == 0 {
            digits.removeLast()
            exponent += 1
        }
        self.negative = negative && !digits.isEmpty
        self.digits = digits
        self.exponent = digits.isEmpty ? 0 : exponent
    }

    /// Reads plain notation, as `Decimal.description` writes it: `-123.45`, `0.001`, `1000`.
    init(_ text: String) {
        var text = Substring(text)
        let negative = text.first == "-"
        if negative { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let integer = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        let digits = (integer + fraction).map { UInt8($0.asciiValue! - 48) }
        self.init(negative: negative, digits: digits, exponent: -fraction.count)
    }

    var isZero: Bool { digits.isEmpty }

    var description: String {
        (negative ? "-" : "") + (digits.isEmpty ? "0" : digits.map(String.init).joined()) + "e\(exponent)"
    }

    /// Foundation's parser does not move exponent digits into the significand, so exponents above 127 are
    /// written as zeros.
    var decimal: Decimal {
        let shift = max(0, exponent - 127)
        let text = (negative ? "-" : "") + (digits.isEmpty ? "0" : digits.map(String.init).joined())
            + String(repeating: "0", count: shift) + "e\(exponent - shift)"
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            fatalError("Foundation cannot read the generated operand \(text)")
        }
        return value
    }

    static func random(using random: inout SplitMix64) -> DigitNumber {
        if Int.random(in: 0..<40, using: &random) == 0 { return DigitNumber(negative: false, digits: [], exponent: 0) }
        // Long operands often, so that results need rounding.
        let length = Bool.random(using: &random) ? 38 : Int.random(in: 1...38, using: &random)
        var digits = (0..<length).map { _ in UInt8.random(in: 0...9, using: &random) }
        if Int.random(in: 0..<8, using: &random) == 0 { digits = Array(repeating: 9, count: length) }
        digits[0] = max(digits[0], 1)
        let exponent: Int
        switch Int.random(in: 0..<10, using: &random) {
        case 0..<6: exponent = Int.random(in: -40...4, using: &random)
        case 6..<8: exponent = Int.random(in: -128...127, using: &random)
        case 8: exponent = Int.random(in: -128 ... -90, using: &random)
        default: exponent = Int.random(in: 90...127, using: &random)
        }
        return DigitNumber(negative: Bool.random(using: &random), digits: digits, exponent: exponent)
    }

    static prefix func - (value: DigitNumber) -> DigitNumber {
        DigitNumber(negative: !value.negative, digits: value.digits, exponent: value.exponent)
    }

    static func + (lhs: DigitNumber, rhs: DigitNumber) -> DigitNumber {
        if lhs.isZero { return rhs }
        if rhs.isZero { return lhs }
        let exponent = min(lhs.exponent, rhs.exponent)
        let a = lhs.digits + Array(repeating: 0, count: lhs.exponent - exponent)
        let b = rhs.digits + Array(repeating: 0, count: rhs.exponent - exponent)
        if lhs.negative == rhs.negative {
            return DigitNumber(negative: lhs.negative, digits: addDigits(a, b), exponent: exponent)
        }
        return compareDigits(a, b) >= 0
            ? DigitNumber(negative: lhs.negative, digits: subtractDigits(a, b), exponent: exponent)
            : DigitNumber(negative: rhs.negative, digits: subtractDigits(b, a), exponent: exponent)
    }

    static func * (lhs: DigitNumber, rhs: DigitNumber) -> DigitNumber {
        if lhs.isZero || rhs.isZero { return DigitNumber(negative: false, digits: [], exponent: 0) }
        var columns = [Int](repeating: 0, count: lhs.digits.count + rhs.digits.count)
        for (i, x) in lhs.digits.reversed().enumerated() {
            for (j, y) in rhs.digits.reversed().enumerated() {
                columns[i + j] += Int(x) * Int(y)
            }
        }
        var carry = 0
        for i in columns.indices {
            let total = columns[i] + carry
            columns[i] = total % 10
            carry = total / 10
        }
        precondition(carry == 0)
        return DigitNumber(
            negative: lhs.negative != rhs.negative,
            digits: columns.reversed().map { UInt8($0) },
            exponent: lhs.exponent + rhs.exponent
        )
    }

    /// `a / b` by long division, truncated after 42 significant digits, or after the digit at 10^downTo.
    static func quotient(_ a: DigitNumber, _ b: DigitNumber, downTo: Int? = nil) -> Truncated {
        var remainder: [UInt8] = []
        var quotient: [UInt8] = []
        var position = 0
        var appendedZeros = 0
        while true {
            if position < a.digits.count {
                remainder.append(a.digits[position])
                position += 1
            } else {
                remainder.append(0)
                appendedZeros += 1
            }
            remainder = Array(remainder.drop { $0 == 0 })
            var digit: UInt8 = 0
            while compareDigits(remainder, b.digits) >= 0 {
                remainder = subtractDigits(remainder, b.digits)
                digit += 1
            }
            quotient.append(digit)
            let enough = if let downTo {
                a.exponent - b.exponent - appendedZeros <= downTo
            } else {
                quotient.drop { $0 == 0 }.count >= 42
            }
            if position >= a.digits.count && (remainder.isEmpty || enough) { break }
        }
        return Truncated(
            negative: a.negative != b.negative,
            digits: Array(quotient.drop { $0 == 0 }),
            exponent: a.exponent - b.exponent - appendedZeros,
            moreDigitsFollow: !remainder.isEmpty
        )
    }

    enum Rounding: Equatable, CustomStringConvertible {
        case value(DigitNumber, exact: Bool)
        case overflow
        case underflow

        var description: String {
            switch self {
            case .value(let value, let exact): "\(value) exact: \(exact)"
            case .overflow: "overflow"
            case .underflow: "underflow"
            }
        }
    }

    /// Digits that may have a non-zero tail: the oracle's quotients.
    struct Truncated {
        var negative: Bool
        var digits: [UInt8]
        var exponent: Int
        var moreDigitsFollow: Bool

        /// The position of the leading digit.
        var lead: Int { exponent + digits.count - 1 }

        /// Rounds at 10^target in the given mode; `exact` is false when anything non-zero was dropped.
        func rounded(at target: Int, _ mode: DecimalMath.RoundingMode) -> (value: DigitNumber, exact: Bool) {
            let count = digits.count
            let dropCount = target - exponent
            precondition(dropCount > 0 || !moreDigitsFollow, "the oracle did not compute enough digits")
            var kept = digits + Array(repeating: 0, count: max(0, -dropCount))
            var firstDropped: UInt8 = 0
            var tailIsZero = !moreDigitsFollow
            if dropCount > 0 {
                kept = Array(digits.prefix(max(0, count - dropCount)))
                if dropCount <= count { firstDropped = digits[count - dropCount] }
                tailIsZero = tailIsZero && digits.suffix(min(dropCount, count)).allSatisfy { $0 == 0 }
            }
            let up = switch mode {
            case .towardZero: false
            case .halfAwayFromZero: firstDropped >= 5
            case .down: negative && !tailIsZero
            case .up: !negative && !tailIsZero
            }
            if up { kept = addDigits(kept, [1]) }
            return (DigitNumber(negative: negative, digits: kept, exponent: target), tailIsZero)
        }

        /// Range check: more than 38 significant digits, or more than fit below the largest exponent.
        private func checked(_ value: DigitNumber, exact: Bool) -> Rounding {
            if value.digits.count > 38 { return .overflow }
            if value.exponent > 127 && value.digits.count + (value.exponent - 127) > 38 { return .overflow }
            return .value(value, exact: exact)
        }

        /// Round half away from zero to 38 significant digits, at 10^-128 at the lowest; then check the range.
        func roundedToDecimal() -> Rounding {
            if digits.isEmpty && !moreDigitsFollow { return .value(DigitNumber(negative: false, digits: [], exponent: 0), exact: true) }
            let (value, exact) = rounded(at: max(exponent, lead - 37, -128), .halfAwayFromZero)
            if value.isZero { return .underflow }
            return checked(value, exact: exact)
        }

        /// DecimalMath's readable policy: exact when it fits; otherwise 15 significant digits, or whole units when the
        /// integer part is longer (38 digits at most), at 10^-128 at the lowest.
        func roundedReadably() -> Rounding {
            let full = roundedToDecimal()
            guard case .value(_, exact: false) = full else { return full }
            let (value, _) = rounded(at: max(-128, min(lead - 14, max(0, lead - 37))), .halfAwayFromZero)
            if value.isZero { return .underflow }
            return checked(value, exact: false)
        }

        /// Rounded to a number of decimal places; 0 is a valid result. "Too many digits" counts as overflow here:
        /// both must throw.
        func roundedToPlaces(_ places: Int, _ mode: DecimalMath.RoundingMode) -> Rounding {
            let (value, exact) = rounded(at: -places, mode)
            return checked(value, exact: exact)
        }
    }

    func roundedToDecimal() -> Rounding {
        Truncated(negative: negative, digits: digits, exponent: exponent, moreDigitsFollow: false).roundedToDecimal()
    }
}

private func compareDigits(_ a: [UInt8], _ b: [UInt8]) -> Int {
    let a = a.drop { $0 == 0 }, b = b.drop { $0 == 0 }
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
    return 0
}

private func addDigits(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    var carry: UInt8 = 0
    var i = a.count - 1, j = b.count - 1
    while i >= 0 || j >= 0 || carry > 0 {
        let total = (i >= 0 ? a[i] : 0) + (j >= 0 ? b[j] : 0) + carry
        result.append(total % 10)
        carry = total / 10
        i -= 1
        j -= 1
    }
    return result.reversed()
}

/// `a - b` for `a >= b`.
private func subtractDigits(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    var borrow: Int = 0
    var j = b.count - 1
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        var value = Int(a[i]) - borrow - (j >= 0 ? Int(b[j]) : 0)
        borrow = value < 0 ? 1 : 0
        if value < 0 { value += 10 }
        result.append(UInt8(value))
        j -= 1
    }
    precondition(borrow == 0)
    return Array(result.reversed().drop { $0 == 0 })
}
