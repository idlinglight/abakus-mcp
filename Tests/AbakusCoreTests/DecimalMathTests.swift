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

    @Test func divisionRoundedToPlaces() throws {
        #expect(try DecimalMath.divide(1, 3, roundingInexactTo: 6) == .init(value: d("0.333333"), exact: false))
        #expect(try DecimalMath.divide(2, 3, roundingInexactTo: 2) == .init(value: d("0.67"), exact: false))
        #expect(try DecimalMath.divide(1, 8, roundingInexactTo: 2) == .init(value: d("0.125"), exact: true))
        #expect(try DecimalMath.divide(d("1e30"), 7, roundingInexactTo: 2) == .init(value: d("142857142857142857142857142857.14"), exact: false))
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
                let result = try? DecimalMath.divide(x, y)
                check("divide", a, b, into: &outcomes, result, expected: DigitNumber.quotient(a, b).roundedToDecimal())
                // exact means result × divisor == dividend, with nothing left over.
                if let result {
                    #expect((DigitNumber(result.value.description) * b == a) == result.exact, "divide \(a) / \(b)")
                }
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

    /// `a / b` by long division, truncated after 42 significant digits.
    static func quotient(_ a: DigitNumber, _ b: DigitNumber) -> Truncated {
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
            let significant = quotient.drop { $0 == 0 }.count
            if position >= a.digits.count && (remainder.isEmpty || significant >= 42) { break }
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

        /// Round half away from zero to 38 significant digits, at 10^-128 at the lowest; then check the range.
        func roundedToDecimal() -> Rounding {
            if digits.isEmpty && !moreDigitsFollow { return .value(DigitNumber(negative: false, digits: [], exponent: 0), exact: true) }
            let count = digits.count
            let dropped = max(0, count - 38, -128 - exponent)
            var kept = Array(digits.prefix(max(0, count - dropped)))
            let roundUp = dropped >= 1 && dropped <= count && digits[count - dropped] >= 5
            let exact = !moreDigitsFollow && digits.suffix(min(dropped, count)).allSatisfy { $0 == 0 }
            if roundUp { kept = addDigits(kept, [1]) }
            let result = DigitNumber(negative: negative, digits: kept, exponent: exponent + dropped)
            if result.isZero { return .underflow }
            if result.exponent > 127 && result.digits.count + (result.exponent - 127) > 38 { return .overflow }
            return .value(result, exact: exact)
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
