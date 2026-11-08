@testable import AbakusCore
import Foundation
import Testing

/// A test number, read by abakus's own rules (`NumberReader`), never by Foundation's parser.
private func n(_ text: String) -> Decimal {
    do {
        return try NumberReader.read(.string(text))
    } catch {
        fatalError("NumberReader cannot read the test literal \(text): \(error.message)")
    }
}

/// A test fraction: `"-1/3"` from its parts, anything else as a number (`"0.1"`, `"2.5e3"`).
private func q(_ text: String) -> Fraction {
    let parts = text.split(separator: "/")
    do {
        guard parts.count == 2 else { return try Fraction(n(text)) }
        let negative = parts[0].hasPrefix("-")
        return try Fraction(
            negative: negative, numerator: big(String(parts[0].drop { $0 == "-" })), denominator: big(String(parts[1]))
        )
    } catch {
        fatalError("not a test fraction: \(text) (\(error))")
    }
}

private func big(_ digits: String) -> BigUInt {
    BigUInt(digits: digits.utf8.map { $0 - UInt8(ascii: "0") })
}

@Suite struct FractionTests {
    // MARK: Exactness

    @Test func aThirdTimesThreeIsOne() throws {
        let third = try Fraction(1) / Fraction(3)
        #expect(third.description == "1/3")
        #expect(try third * Fraction(3) == .one)
        #expect(try third + third + third == .one)
    }

    @Test func pointOnePlusPointTwoIsPointThree() throws {
        #expect(try q("0.1") + q("0.2") == q("0.3"))
        #expect(try (q("0.1") + q("0.2")).decimalResult() == .init(value: n("0.3"), exact: true, fraction: nil))
    }

    @Test func compoundGrowthIsExact() throws {
        // 1000 × 1.045^10 = 1000 × 209^10 / 200^10, a terminating decimal of 31 digits.
        let value = try Fraction(1000) * q("1.045").raised(to: 10)
        #expect(value == q("159024068785448665562401/102400000000000000000"))
        #expect(try value.decimalResult()
            == .init(value: n("1552.969421732897124632822265625"), exact: true, fraction: nil))
    }

    @Test func partsAreAlwaysReduced() throws {
        #expect(q("6/8").description == "3/4")
        #expect(q("5.000").description == "5")
        #expect(q("0.250").description == "1/4")
        #expect(q("2.5e3").description == "2500")
        #expect(q("-1.2e-5").description == "-3/250000")
        // A Decimal whose significand carries trailing zeros: 5000 × 10^-3.
        let unnormalized = Decimal(
            _exponent: -3, _length: 1, _isNegative: 1, _isCompact: 0, _reserved: 0, _mantissa: (5000, 0, 0, 0, 0, 0, 0, 0)
        )
        #expect(try Fraction(unnormalized).description == "-5")
        #expect(try (q("1/6") + q("1/3")).description == "1/2")
        #expect(try (q("5/6") - q("1/3")).description == "1/2")
        #expect(try (q("4/9") * q("3/8")).description == "1/6")
        #expect(try (q("4/9") / q("8/3")).description == "1/6")
        #expect(try (q("1/10") + q("1/15")).description == "1/6")
    }

    @Test func signs() throws {
        #expect(q("-1/3").negative)
        #expect((-q("1/3")).description == "-1/3")
        #expect(try (Fraction(1) / Fraction(-3)).description == "-1/3")
        #expect(try (Fraction(-1) / Fraction(-3)).description == "1/3")
        #expect(try Fraction(-2) * Fraction(-3) == Fraction(6))
        #expect(try Fraction(-2) * Fraction(3) == Fraction(-6))
        #expect(try q("1/3") - q("1/2") == q("-1/6"))
        #expect(try q("-1/3") + q("1/2") == q("1/6"))
        #expect(try q("-1/3") - q("1/2") == q("-5/6"))
        #expect(q("-2/3").magnitude == q("2/3"))
        #expect(q("2/3").magnitude == q("2/3"))
        #expect(Fraction(Int.min).description == "-9223372036854775808")
    }

    @Test func zeroHasOneRepresentation() throws {
        let zeros = [
            Fraction(0), Fraction.zero, q("0"), q("-0"), q("0.000"), q("0/7"), -Fraction.zero,
            try q("1/3") - q("1/3"), try q("-1/3") + q("1/3"), try q("-5") * Fraction(0), try Fraction(0) / q("-5"),
        ]
        for zero in zeros {
            #expect(zero == .zero)
            #expect(!zero.negative && zero.denominator == .one && zero.isZero, "\(zero)")
        }
        #expect(try Fraction.zero.decimalResult() == .init(value: 0, exact: true, fraction: nil))
    }

    @Test func divisionByZero() {
        #expect(throws: FractionError.divisionByZero) { try Fraction(1) / .zero }
        #expect(throws: FractionError.divisionByZero) { try Fraction.zero / .zero }
        #expect(throws: FractionError.divisionByZero) { try Fraction(numerator: .one, denominator: .zero) }
    }

    @Test func notANumber() {
        #expect(throws: FractionError.notANumber) { try Fraction(Decimal.nan) }
    }

    @Test func comparison() {
        let ordered = [q("-5/2"), q("-1/2"), q("-1/3"), .zero, q("1/1000"), q("1/3"), q("1/2"), Fraction(1), q("7/3")]
        for (i, a) in ordered.enumerated() {
            for (j, b) in ordered.enumerated() {
                #expect((a < b) == (i < j), "\(a) < \(b)")
                #expect((a == b) == (i == j), "\(a) == \(b)")
            }
        }
        #expect(ordered.shuffled().min() == q("-5/2"))
        #expect(ordered.shuffled().max() == q("7/3"))
    }

    @Test func wholeNumbersAndIntegers() {
        #expect(q("5").isWholeNumber && q("-5").isWholeNumber && Fraction.zero.isWholeNumber)
        #expect(!q("5/2").isWholeNumber && !q("0.1").isWholeNumber)
        #expect(q("5").integer(in: -9999...9999) == 5)
        #expect(q("-9999").integer(in: -9999...9999) == -9999)
        #expect(q("10000").integer(in: -9999...9999) == nil)
        #expect(q("-10000").integer(in: -9999...9999) == nil)
        #expect(q("5.000").integer(in: -9999...9999) == 5)
        #expect(q("5/2").integer(in: -9999...9999) == nil)
        #expect(Fraction.zero.integer(in: 0...0) == 0)
        #expect(q("1e30").integer(in: Int.min...Int.max) == nil)
        #expect(Fraction(Int.max).integer(in: Int.min...Int.max) == Int.max)
        #expect(Fraction(Int.min).integer(in: Int.min...Int.max) == nil, "-2^63 is out of the range the helper reads")
    }

    // MARK: Powers

    @Test(arguments: [
        ("2", 10, "1024"), ("2/3", 3, "8/27"), ("2/3", -3, "27/8"), ("-2", 3, "-8"), ("-2", 2, "4"),
        ("-1/2", -3, "-8"), ("-1/2", -2, "4"), ("0.1", 3, "1/1000"), ("0.1", -3, "1000"),
        ("5", 0, "1"), ("-5/7", 0, "1"), ("0", 0, "1"), ("0", 1, "0"), ("0", 9999, "0"),
        ("1", 9999, "1"), ("-1", 9999, "-1"), ("-1", -9998, "1"), ("1", -9999, "1"),
    ])
    func power(base: String, exponent: Int, expected: String) throws {
        #expect(try q(base).raised(to: exponent).description == expected, "\(base)^\(exponent)")
        #expect(try q(base).raised(to: Fraction(exponent)).description == expected, "\(base)^\(exponent)")
    }

    @Test func powerErrors() {
        #expect(throws: FractionError.divisionByZero) { try Fraction.zero.raised(to: -1) }
        #expect(throws: FractionError.divisionByZero) { try Fraction.zero.raised(to: -9999) }
        #expect(throws: FractionError.exponentOutOfRange) { try Fraction(1).raised(to: 10000) }
        #expect(throws: FractionError.exponentOutOfRange) { try Fraction(1).raised(to: -10000) }
        #expect(throws: FractionError.exponentOutOfRange) { try Fraction(2).raised(to: q("1e30")) }
        #expect(throws: FractionError.exponentNotWhole) { try Fraction(4).raised(to: q("1/2")) }
        #expect(throws: FractionError.exponentNotWhole) { try Fraction(4).raised(to: q("-0.5")) }
        #expect(throws: FractionError.exponentNotWhole) { try Fraction(4).raised(to: q("1e30") + q("0.5")) }
        #expect(throws: FractionError.exponentNotWhole) { try Fraction.zero.raised(to: q("-1/2")) }
    }

    @Test func powersAtTheDigitLimit() throws {
        // 2^6643 and 3^4191 have 2000 digits, 2^6644 and 3^4192 have 2001; the limit applies to the denominator too.
        #expect(try Fraction(2).raised(to: 6643).numerator == BigUInt.powerOfTwo(6643))
        #expect(throws: FractionError.tooManyDigits) { try Fraction(2).raised(to: 6644) }
        #expect(try q("1/2").raised(to: 6643).denominator == BigUInt.powerOfTwo(6643))
        #expect(throws: FractionError.tooManyDigits) { try q("1/2").raised(to: 6644) }
        #expect(throws: FractionError.tooManyDigits) { try Fraction(2).raised(to: -6644) }
        #expect(try Fraction(3).raised(to: 4191).numerator.decimalDigitCount == 2000)
        #expect(throws: FractionError.tooManyDigits) { try Fraction(3).raised(to: 4192) }
        #expect(try Fraction(10).raised(to: 1999).numerator == BigUInt.powerOfTen(1999))
        #expect(throws: FractionError.tooManyDigits) { try Fraction(10).raised(to: 2000) }
        #expect(throws: FractionError.tooManyDigits) { try q("-0.1").raised(to: 2000) }
    }

    @Test func hugePowersFailAtOnce() throws {
        let nearLimit = try Fraction(numerator: BigUInt.powerOfTen(1999) + .one, denominator: BigUInt(7))
        let elapsed = ContinuousClock().measure {
            #expect(throws: FractionError.tooManyDigits) { try Fraction(9).raised(to: 9999) }
            #expect(throws: FractionError.tooManyDigits) { try Fraction(9999).raised(to: 9999) }
            #expect(throws: FractionError.tooManyDigits) { try q("0.5").raised(to: 9999) }
            #expect(throws: FractionError.tooManyDigits) { try nearLimit.raised(to: 9999) }
            #expect(throws: FractionError.tooManyDigits) { try nearLimit.raised(to: -2) }
            #expect(throws: FractionError.tooManyDigits) { try Fraction(3).raised(to: 4192) }
            #expect(throws: FractionError.tooManyDigits) { try q("-7/3").raised(to: -2367) }
        }
        // Microseconds in a release build; the bound only catches a computation of the full power.
        #expect(elapsed < .seconds(1), "took \(elapsed)")
    }

    // MARK: The digit limit in the four operations

    @Test func everyResultIsCheckedAgainstTheDigitLimit() throws {
        let largest = try Fraction(numerator: BigUInt.powerOfTen(2000) - .one, denominator: .one) // 2000 nines
        let tiny = try Fraction(numerator: .one, denominator: BigUInt.powerOfTen(1999))
        #expect(largest.numerator.decimalDigitCount == 2000)
        #expect(throws: FractionError.tooManyDigits) { try Fraction(numerator: BigUInt.powerOfTen(2000), denominator: .one) }
        #expect(throws: FractionError.tooManyDigits) { try largest + .one }
        #expect(throws: FractionError.tooManyDigits) { try largest * Fraction(2) }
        #expect(throws: FractionError.tooManyDigits) { try largest / q("1/2") }
        #expect(throws: FractionError.tooManyDigits) { try tiny / Fraction(10) }
        // 1/10^1999 + 1/11 needs the denominator 11 × 10^1999; 1/7 would still fit.
        #expect(throws: FractionError.tooManyDigits) { try tiny + q("1/11") }
        #expect(try (tiny + q("1/7")).denominator == BigUInt(7) * BigUInt.powerOfTen(1999))
        // An intermediate result over the limit is an error even when the final value would be small.
        #expect(throws: FractionError.tooManyDigits) { try largest * Fraction(10) / Fraction(10) }
        // Values that stay within the limit, even with long intermediate products.
        #expect(try largest - .one + .one == largest)
        #expect(try (largest * tiny).denominator == BigUInt.powerOfTen(1999))
        #expect(try Fraction(numerator: BigUInt.powerOfTen(1999), denominator: .one) * tiny == .one)
        #expect(try tiny * Fraction(10) == (try Fraction(numerator: .one, denominator: BigUInt.powerOfTen(1998))))
        #expect(try largest / largest == .one)
    }

    // MARK: Rounding to places

    @Test(arguments: [
        ("1234.5678", 2, "1234.57"), ("1234.5678", 0, "1235"), ("1234.5678", -2, "1200"), ("1234.5678", 3, "1234.568"),
        ("-1234.5678", 2, "-1234.57"), ("-1234.5678", -2, "-1200"),
        // Ties go away from zero.
        ("2.5", 0, "3"), ("-2.5", 0, "-3"), ("0.125", 2, "0.13"), ("-0.125", 2, "-0.13"), ("1250", -2, "1300"),
        ("-1250", -2, "-1300"), ("2.49999", 0, "2"), ("-2.49999", 0, "-2"),
        // Nothing to round: whole numbers, and fewer digits than places; trailing zeros are not kept.
        ("12.5", 2, "12.5"), ("7", 5, "7"), ("1e100", 0, "1e100"), ("1e-128", 128, "1e-128"),
        // To zero: never a negative zero.
        ("0.4", 0, "0"), ("-0.4", 0, "0"), ("-0.001", 2, "0"), ("1", -165, "0"),
        // Up to the next power of ten.
        ("9.995", 2, "10"), ("-9.5", 0, "-10"),
    ])
    func roundedToPlaces(value: String, places: Int, expected: String) throws {
        let result = try q(value).rounded(toPlaces: places)
        #expect(result == q(expected), "\(value) to \(places) places: \(result)")
        #expect(!(result.isZero && result.negative))
        #expect(try q(value).rounded(toPlaces: Fraction(places)) == result)
    }

    @Test func roundingFractionsExactly() throws {
        #expect(try q("1/3").rounded(toPlaces: 2) == q("0.33"))
        #expect(try q("2/3").rounded(toPlaces: 2) == q("0.67"))
        #expect(try q("-2/3").rounded(toPlaces: 0) == Fraction(-1))
        #expect(try q("-1/3").rounded(toPlaces: 0) == .zero)
        #expect(try q("1/8").rounded(toPlaces: 2) == q("0.13"))
        #expect(try q("-1/8").rounded(toPlaces: 2) == q("-0.13"))
        #expect(try q("1/16").rounded(toPlaces: 3) == q("0.063"))
        #expect(try q("200/3").rounded(toPlaces: -1) == Fraction(70))
        // At the ends of the range of places.
        let tenTo165 = try Fraction(numerator: BigUInt.powerOfTen(165), denominator: .one)
        #expect(try q("5e164").rounded(toPlaces: -165) == tenTo165)
        #expect(try q("-5e164").rounded(toPlaces: -165) == -tenTo165)
        #expect(try q("4.9e164").rounded(toPlaces: -165) == .zero)
        let halfStep = try Fraction(numerator: BigUInt(5), denominator: BigUInt.powerOfTen(129))
        let lessThanHalfStep = try Fraction(negative: true, numerator: BigUInt(49), denominator: BigUInt.powerOfTen(130))
        #expect(try halfStep.rounded(toPlaces: 128) == q("1e-128"))
        #expect(try lessThanHalfStep.rounded(toPlaces: 128) == .zero)
        // 1/3 to 128 places: 128 threes, more than a Decimal holds, so the result is rounded again for the response.
        let thirds = try q("1/3").rounded(toPlaces: 128)
        #expect(thirds.denominator == BigUInt.powerOfTen(128))
        #expect(try thirds.decimalResult() == .init(value: n("0.333333333333333"), exact: false, fraction: nil))
    }

    @Test func roundingErrors() throws {
        #expect(throws: FractionError.placesOutOfRange) { try Fraction(1).rounded(toPlaces: 129) }
        #expect(throws: FractionError.placesOutOfRange) { try Fraction(1).rounded(toPlaces: -166) }
        #expect(throws: FractionError.placesOutOfRange) { try Fraction(1).rounded(toPlaces: q("1e30")) }
        #expect(throws: FractionError.placesNotWhole) { try Fraction(1).rounded(toPlaces: q("1/2")) }
        #expect(throws: FractionError.placesNotWhole) { try Fraction(1).rounded(toPlaces: q("-2.5")) }
        // 10^1999 + 1/3 to 128 places needs a numerator of 2128 digits.
        let long = try Fraction(numerator: BigUInt.powerOfTen(1999) * BigUInt(3) + .one, denominator: BigUInt(3))
        #expect(throws: FractionError.tooManyDigits) { try long.rounded(toPlaces: 128) }
        #expect(try long.rounded(toPlaces: 0) == Fraction(numerator: BigUInt.powerOfTen(1999), denominator: .one))
    }

    // MARK: The result

    @Test(arguments: [
        // Terminating decimals of up to 38 significant digits are exact.
        ("1/8", "0.125", true, nil), ("1/1024", "0.0009765625", true, nil), ("36/5", "7.2", true, nil),
        ("12345678901234567890123456789012345678", "12345678901234567890123456789012345678", true, nil),
        ("1e-128", "1e-128", true, nil), ("-1e164", "-1e164", true, nil),
        // Otherwise 15 significant digits, half away from zero, and the exact value as text.
        ("1/3", "0.333333333333333", false, "1/3"), ("-1/3", "-0.333333333333333", false, "-1/3"),
        ("2/3", "0.666666666666667", false, "2/3"), ("13/6", "2.16666666666667", false, "13/6"),
        ("1/3000000", "0.000000333333333333333", false, "1/3000000"),
        // A longer integer part is kept in whole units, up to 38 digits.
        ("100000000000000000000/3", "33333333333333333333", false, "100000000000000000000/3"),
        // 2^130: a whole number of 40 digits.
        ("1361129467683753853853498429727072845824/1", "13611294676837538538534984297270728458e2", false,
         "1361129467683753853853498429727072845824"),
        // A terminating decimal with more than 38 digits is rounded too: 1 + 10^-38.
        ("100000000000000000000000000000000000001/100000000000000000000000000000000000000", "1", false,
         "100000000000000000000000000000000000001/100000000000000000000000000000000000000"),
    ] as [(String, String, Bool, String?)])
    func decimalResult(value: String, expected: String, exact: Bool, fraction: String?) throws {
        #expect(try q(value).decimalResult() == .init(value: n(expected), exact: exact, fraction: fraction), "\(value)")
    }

    @Test func fractionTextUpToAHundredDigits() throws {
        let hundredNines = BigUInt.powerOfTen(100) - .one
        // (10^100 - 1)/7 and (10^100 + 1)/7 are reduced; the numerators have 100 and 101 digits.
        let short = try Fraction(numerator: hundredNines, denominator: BigUInt(7))
        let long = try Fraction(numerator: BigUInt.powerOfTen(100) + .one, denominator: BigUInt(7))
        #expect(try short.decimalResult().fraction == String(repeating: "9", count: 100) + "/7")
        #expect(try long.decimalResult().fraction == nil)
        #expect(try long.decimalResult().exact == false)
        // The same for denominators: 3 × 10^99 has 100 digits, 3 × 10^100 has 101.
        let shortDenominator = try Fraction(numerator: .one, denominator: BigUInt(3) * BigUInt.powerOfTen(99))
        let longDenominator = try Fraction(numerator: .one, denominator: BigUInt(3) * BigUInt.powerOfTen(100))
        #expect(try shortDenominator.decimalResult().fraction == "1/3" + String(repeating: "0", count: 99))
        #expect(try longDenominator.decimalResult().fraction == nil)
        #expect(try longDenominator.decimalResult().value == n("3.33333333333333e-101"))
    }

    @Test func wholeNumbersAsTextHaveNoDenominator() throws {
        let twoTo200 = "1606938044258990275541962092341162602522202993782792835301376"
        let power = try Fraction(2).raised(to: 200)
        #expect(try power.decimalResult()
            == .init(value: n("16069380442589902755419620923411626025e23"), exact: false, fraction: twoTo200))
        #expect(try (-power).decimalResult().fraction == "-" + twoTo200)
        // The 100-digit rule holds for whole numbers too: 10^100 - 1 has 100 digits, 10^100 + 1 has 101.
        let hundredNines = try Fraction(numerator: BigUInt.powerOfTen(100) - .one, denominator: .one)
        let longer = try Fraction(numerator: BigUInt.powerOfTen(100) + .one, denominator: .one)
        #expect(try hundredNines.decimalResult().fraction == String(repeating: "9", count: 100))
        #expect(try longer.decimalResult() == .init(value: n("1e100"), exact: false, fraction: nil))
        #expect(Fraction.zero.description == "0")
        #expect(Fraction(-7).description == "-7")
    }

    @Test func overflowAndUnderflow() throws {
        let tenTo165 = try Fraction(numerator: BigUInt.powerOfTen(165), denominator: .one)
        #expect(throws: FractionError.overflow) { try tenTo165.decimalResult() }
        #expect(throws: FractionError.overflow) { try (-tenTo165).decimalResult() }
        // 165 nines round up to 10^165 at 38 digits.
        #expect(throws: FractionError.overflow) { try (tenTo165 - .one).decimalResult() }
        let huge = try Fraction(numerator: BigUInt.powerOfTen(1999), denominator: BigUInt(3))
        #expect(throws: FractionError.overflow) { try huge.decimalResult() }
        let largest = try tenTo165 - Fraction(numerator: BigUInt.powerOfTen(127), denominator: .one)
        #expect(try largest.decimalResult()
            == .init(value: n("99999999999999999999999999999999999999e127"), exact: true, fraction: nil))
        // Intermediate values may go beyond the range of a Decimal.
        #expect(try (tenTo165 * tenTo165 / tenTo165 / Fraction(1000)).decimalResult().value == n("1e162"))

        let tenToMinus128 = try Fraction(numerator: .one, denominator: BigUInt.powerOfTen(128))
        #expect(try tenToMinus128.decimalResult() == .init(value: n("1e-128"), exact: true, fraction: nil))
        #expect(throws: FractionError.underflow) { try (tenToMinus128 / Fraction(10)).decimalResult() }
        #expect(throws: FractionError.underflow) { try (tenToMinus128 / Fraction(-3)).decimalResult() }
        let tiny = try Fraction(numerator: .one, denominator: BigUInt.powerOfTen(1999))
        #expect(throws: FractionError.underflow) { try tiny.decimalResult() }
        #expect(try (tenToMinus128 / Fraction(10) * Fraction(10)).decimalResult().value == n("1e-128"))
        // Below 10^-128 the digits run out; a value that still rounds to 10^-128 is not an underflow.
        #expect(try (tenToMinus128 * q("2/3")).decimalResult() == .init(value: n("1e-128"), exact: false, fraction: nil))
        #expect(try (tenToMinus128 * q("-1.5")).decimalResult() == .init(value: n("-2e-128"), exact: false, fraction: nil))
    }

    // MARK: BigUInt additions

    @Test func bigUIntDescription() {
        #expect(BigUInt.zero.description == "0")
        #expect(BigUInt(7).description == "7")
        #expect(BigUInt(UInt64.max).description == "18446744073709551615")
        #expect(BigUInt.powerOfTwo(130).description == "1361129467683753853853498429727072845824")
        #expect(BigUInt.powerOfTen(19).description == "1" + String(repeating: "0", count: 19))
        #expect(BigUInt.powerOfTen(57).description == "1" + String(repeating: "0", count: 57))
        var random = SplitMix64(seed: 0x0de5_c41b)
        for _ in 0..<200 {
            let count = Int.random(in: 1...300, using: &random)
            let digits = String((0..<count).map { index in
                Character(String(index == 0 ? Int.random(in: 1...9, using: &random) : Int.random(in: 0...9, using: &random)))
            })
            #expect(big(digits).description == digits)
        }
    }

    @Test func gcdSpecialCases() {
        #expect(BigUInt.gcd(.zero, .zero) == .zero)
        #expect(BigUInt.gcd(.zero, BigUInt(12)) == BigUInt(12))
        #expect(BigUInt.gcd(BigUInt(12), .zero) == BigUInt(12))
        #expect(BigUInt.gcd(BigUInt(12), BigUInt(18)) == BigUInt(6))
        #expect(BigUInt.gcd(.one, BigUInt.powerOfTen(100)) == .one)
        #expect(BigUInt.gcd(BigUInt.powerOfTwo(200), BigUInt.powerOfTwo(100) * BigUInt(3)) == BigUInt.powerOfTwo(100))
        #expect(BigUInt.gcd(BigUInt.powerOfTen(300), BigUInt.powerOfTen(128)) == BigUInt.powerOfTen(128))
        #expect(BigUInt.gcd(BigUInt.powerOfTen(300), BigUInt.powerOfTwo(500)) == BigUInt.powerOfTwo(300))
        let p = big("170141183460469231731687303715884105727") // 2^127 - 1, a prime
        #expect(BigUInt.gcd(p * p * BigUInt(6), p * BigUInt(10)) == p * BigUInt(2))
        #expect(BigUInt.gcd(p, p) == p)
    }

    @Test func gcdAgreesWithEuclid() {
        var random = SplitMix64(seed: 0x09cd_e0c1)
        for _ in 0..<300 {
            // A shared factor, sometimes with powers of two, and operands of very different lengths.
            let common = randomBig(maxDigits: 40, using: &random)
            let a = randomBig(maxDigits: 120, using: &random) * common * BigUInt.powerOfTwo(Int.random(in: 0...70, using: &random))
            let b = randomBig(maxDigits: Bool.random(using: &random) ? 120 : 10, using: &random) * common
            #expect(BigUInt.gcd(a, b) == euclid(a, b), "gcd(\(a), \(b))")
            #expect(BigUInt.gcd(b, a) == euclid(a, b), "gcd(\(b), \(a))")
        }
    }
}

/// The four operations on random fractions against an independent oracle: fractions over Int128, reduced with
/// Euclid's algorithm.
@Suite struct FractionRandomizedTests {
    @Test func agreesWithInt128Oracle() throws {
        var random = SplitMix64(seed: 0x0f4a_c710)
        for _ in 0..<3000 {
            let (a, x) = randomSmall(using: &random)
            let (b, y) = randomSmall(using: &random)
            try #require(oracle(a) == x, "operand \(a)")
            try #require(oracle(b) == y, "operand \(b)")
            #expect(oracle(try a + b) == x + y, "\(a) + \(b)")
            #expect(oracle(try a - b) == x - y, "\(a) - \(b)")
            #expect(oracle(try a * b) == x * y, "\(a) * \(b)")
            if y.isZero {
                #expect(throws: FractionError.divisionByZero) { try a / b }
            } else {
                #expect(oracle(try a / b) == x / y, "\(a) / \(b)")
            }
            #expect((a < b) == (x < y), "\(a) < \(b)")
            #expect((a == b) == (x == y), "\(a) == \(b)")
        }
    }

    /// Identities on fractions of hundreds of digits, where no fixed-width oracle reaches. Results must also be
    /// reduced, or the comparisons with the reduced operands would fail.
    @Test func identitiesOnLongFractions() throws {
        var random = SplitMix64(seed: 0x01de_0717)
        for _ in 0..<40 {
            let x = try randomLong(using: &random)
            let y = try randomLong(using: &random)
            let z = try randomLong(using: &random)
            #expect(try x + y - y == x)
            #expect(try x + y == y + x)
            #expect(try x * y == y * x)
            #expect(try x * y / y == x)
            #expect(try x / y * y == x)
            #expect(try x - x == .zero)
            #expect(try x / x == .one)
            #expect(try (x + y) * z == x * z + y * z)
            #expect((x < y) == (try x - y).negative)
            #expect(try x.raised(to: 2) == x * x)
            #expect(try x.raised(to: -2) == Fraction.one / (x * x))
        }
    }

    /// Every Decimal converts exactly and comes back unchanged; quotients follow the same readable policy as
    /// `DecimalMath.readableQuotient`; where DecimalMath's sums and products are exact, they agree.
    @Test func agreesWithDecimalMath() throws {
        var random = SplitMix64(seed: 0x0dec_1a7e)
        var outcomes: [String: Int] = [:]
        defer {
            for outcome in ["exact", "rounded", "overflow", "underflow"] {
                #expect(outcomes[outcome, default: 0] >= 50, "only \(outcomes[outcome, default: 0]) \(outcome) quotients")
            }
        }
        for _ in 0..<2000 {
            let a = randomDecimal(using: &random)
            let b = randomDecimal(using: &random)
            let x = try Fraction(a)
            let y = try Fraction(b)
            #expect(try x.decimalResult() == .init(value: a, exact: true, fraction: nil), "\(a)")

            let operations: [(String, DecimalMath.Result?, Fraction)] = [
                ("add", try? DecimalMath.add(a, b), try x + y),
                ("subtract", try? DecimalMath.subtract(a, b), try x - y),
                ("multiply", try? DecimalMath.multiply(a, b), try x * y),
            ]
            for (name, decimalResult, fraction) in operations {
                guard let decimalResult, decimalResult.exact else { continue }
                #expect(try fraction.decimalResult() == .init(value: decimalResult.value, exact: true, fraction: nil),
                        "\(name) \(a), \(b)")
            }

            if b.isZero {
                #expect(throws: FractionError.divisionByZero) { try x / y }
                continue
            }
            let quotient = try x / y
            let expected: DecimalMath.Result
            do {
                expected = try DecimalMath.readableQuotient(a, b)
            } catch {
                let kind: FractionError = error == DecimalMath.overflow ? .overflow : .underflow
                #expect(error == DecimalMath.overflow || error == DecimalMath.underflow)
                outcomes[kind == .overflow ? "overflow" : "underflow", default: 0] += 1
                #expect(throws: kind, "\(a) / \(b)") { try quotient.decimalResult() }
                continue
            }
            outcomes[expected.exact ? "exact" : "rounded", default: 0] += 1
            let result = try quotient.decimalResult()
            #expect(result.value == expected.value && result.exact == expected.exact, "\(a) / \(b): \(result)")
            let short = quotient.numerator.decimalDigitCount <= 100 && quotient.denominator.decimalDigitCount <= 100
            #expect(result.fraction == (expected.exact || !short ? nil : quotient.description), "\(a) / \(b)")
        }
    }
}

// MARK: - Oracle and generators

/// A fraction over Int128, reduced with Euclid's algorithm: the oracle for small operands.
private struct SmallFraction: Equatable, CustomStringConvertible {
    var numerator: Int128
    var denominator: Int128

    init(_ numerator: Int128, _ denominator: Int128) {
        precondition(denominator != 0)
        let sign: Int128 = denominator < 0 ? -1 : 1
        var (a, b) = (numerator.magnitude, denominator.magnitude)
        while b != 0 { (a, b) = (b, a % b) }
        let common = Int128(a == 0 ? 1 : a)
        self.numerator = sign * numerator / common
        self.denominator = sign * denominator / common
    }

    /// The parts as they are, not reduced: what a Fraction holds, compared field by field with the oracle's.
    init(unreduced numerator: Int128, _ denominator: Int128) {
        self.numerator = numerator
        self.denominator = denominator
    }

    var isZero: Bool { numerator == 0 }
    var description: String { "\(numerator)/\(denominator)" }

    static func + (l: Self, r: Self) -> Self {
        Self(l.numerator * r.denominator + r.numerator * l.denominator, l.denominator * r.denominator)
    }
    static func - (l: Self, r: Self) -> Self {
        Self(l.numerator * r.denominator - r.numerator * l.denominator, l.denominator * r.denominator)
    }
    static func * (l: Self, r: Self) -> Self { Self(l.numerator * r.numerator, l.denominator * r.denominator) }
    static func / (l: Self, r: Self) -> Self { Self(l.numerator * r.denominator, l.denominator * r.numerator) }
    static func < (l: Self, r: Self) -> Bool { l.numerator * r.denominator < r.numerator * l.denominator }
}

/// A Fraction's parts as Int128, unchanged, so that a result that is not reduced differs from the oracle's: nil when
/// they do not fit.
private func oracle(_ value: Fraction) -> SmallFraction? {
    func int128(_ value: BigUInt) -> Int128? {
        guard value.limbs.count <= 2 else { return nil }
        let low = value.limbs.count > 0 ? value.limbs[0] : 0
        let high = value.limbs.count > 1 ? value.limbs[1] : 0
        return Int128(exactly: UInt128(high) << 64 | UInt128(low))
    }
    guard let numerator = int128(value.numerator), let denominator = int128(value.denominator) else { return nil }
    return SmallFraction(unreduced: value.negative ? -numerator : numerator, denominator)
}

/// Numerators and denominators below 2^40, unreduced on input (a shared factor), zero now and then.
private func randomSmall(using random: inout SplitMix64) -> (Fraction, SmallFraction) {
    func part(_ random: inout SplitMix64) -> UInt64 {
        switch Int.random(in: 0..<4, using: &random) {
        case 0: UInt64.random(in: 1...12, using: &random)
        case 1: UInt64.random(in: 1...1000, using: &random)
        default: UInt64.random(in: 1..<(1 << 32), using: &random)
        }
    }
    let shared = UInt64.random(in: 1...255, using: &random)
    let numerator = Int.random(in: 0..<15, using: &random) == 0 ? 0 : part(&random) * shared
    let denominator = part(&random) * shared
    let negative = Bool.random(using: &random)
    let fraction = try! Fraction(negative: negative, numerator: BigUInt(numerator), denominator: BigUInt(denominator))
    let small = SmallFraction(Int128(numerator) * (negative ? -1 : 1), Int128(denominator))
    return (fraction, small)
}

/// Fractions with up to 600 digits in each part, so that products of three stay below the digit limit.
private func randomLong(using random: inout SplitMix64) throws -> Fraction {
    let numerator = randomBig(maxDigits: 600, using: &random)
    let denominator = randomBig(maxDigits: 600, using: &random)
    return try Fraction(negative: Bool.random(using: &random), numerator: numerator, denominator: denominator)
}

/// A positive number with 1 to `maxDigits` digits, often short.
private func randomBig(maxDigits: Int, using random: inout SplitMix64) -> BigUInt {
    let count = Int.random(in: 1...(Bool.random(using: &random) ? maxDigits : min(maxDigits, 20)), using: &random)
    var digits = (0..<count).map { _ in UInt8.random(in: 0...9, using: &random) }
    digits[0] = max(digits[0], 1)
    return BigUInt(digits: digits)
}

/// A Decimal of up to 38 significant digits across the whole exponent range, read by NumberReader; long and
/// all-nines significands often, so that results need rounding, and now and then a short one (2, 25, 3, ...), so
/// that quotients come out exact as well.
private func randomDecimal(using random: inout SplitMix64) -> Decimal {
    if Int.random(in: 0..<40, using: &random) == 0 { return 0 }
    let length = Bool.random(using: &random) ? 38 : Int.random(in: 1...38, using: &random)
    var digits = (0..<length).map { _ in Int.random(in: 0...9, using: &random) }
    switch Int.random(in: 0..<8, using: &random) {
    case 0: digits = Array(repeating: 9, count: length)
    case 1: digits = [[2], [4], [5], [8], [1, 6], [2, 5], [3], [7], [1, 2]].randomElement(using: &random)!
    default: break
    }
    digits[0] = max(digits[0], 1)
    let exponent = switch Int.random(in: 0..<10, using: &random) {
    case 0..<6: Int.random(in: -40...4, using: &random)
    case 6..<8: Int.random(in: -128...127, using: &random)
    case 8: Int.random(in: -128 ... -90, using: &random)
    default: Int.random(in: 90...127, using: &random)
    }
    let sign = Bool.random(using: &random) ? "-" : ""
    return n(sign + digits.map(String.init).joined() + "e\(exponent)")
}

/// Euclid's algorithm on BigUInt's long division: independent of the binary gcd under test.
private func euclid(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
    var (a, b) = (a, b)
    while !b.isZero { (a, b) = (b, a.quotientAndRemainder(dividingBy: b).remainder) }
    return a
}

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
