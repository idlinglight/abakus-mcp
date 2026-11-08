import Foundation

/// A decimal number of any precision: `±magnitude × 10^exponent`. DecimalMath does its arithmetic here and rounds
/// once, when the result goes back into a `Decimal` (ADR-0005).
struct ExactDecimal: Sendable {
    var negative: Bool
    var magnitude: BigUInt
    var exponent: Int

    static let zero = ExactDecimal(negative: false, magnitude: .zero, exponent: 0)

    init(negative: Bool, magnitude: BigUInt, exponent: Int) {
        self.negative = negative && !magnitude.isZero
        self.magnitude = magnitude
        self.exponent = exponent
    }

    /// The exact value of a finite `Decimal`, read from its significand and exponent.
    init(_ value: Decimal) {
        precondition(!value.isNaN, "ExactDecimal from NaN")
        let m = value._mantissa
        let words = [m.0, m.1, m.2, m.3, m.4, m.5, m.6, m.7].prefix(Int(value._length))
        var low: UInt64 = 0
        var high: UInt64 = 0
        for (index, word) in words.enumerated() {
            if index < 4 {
                low |= UInt64(word) << UInt64(16 * index)
            } else {
                high |= UInt64(word) << UInt64(16 * (index - 4))
            }
        }
        self.init(negative: value._isNegative != 0, magnitude: BigUInt(limbs: [low, high]), exponent: Int(value._exponent))
    }

    var isZero: Bool { magnitude.isZero }

    /// Decimal places after removing trailing zeros: 0 for integers, 2 for 1.25.
    var fractionDigits: Int {
        let zeros = magnitude.strippingTrailingDecimalZeros().zeros
        return max(0, -(exponent + zeros))
    }

    static prefix func - (value: ExactDecimal) -> ExactDecimal {
        ExactDecimal(negative: !value.negative, magnitude: value.magnitude, exponent: value.exponent)
    }

    static func + (lhs: ExactDecimal, rhs: ExactDecimal) -> ExactDecimal {
        if lhs.isZero { return rhs }
        if rhs.isZero { return lhs }
        let exponent = min(lhs.exponent, rhs.exponent)
        let a = lhs.magnitude.timesPowerOfTen(lhs.exponent - exponent)
        let b = rhs.magnitude.timesPowerOfTen(rhs.exponent - exponent)
        if lhs.negative == rhs.negative {
            return ExactDecimal(negative: lhs.negative, magnitude: a + b, exponent: exponent)
        }
        return a >= b
            ? ExactDecimal(negative: lhs.negative, magnitude: a - b, exponent: exponent)
            : ExactDecimal(negative: rhs.negative, magnitude: b - a, exponent: exponent)
    }

    static func * (lhs: ExactDecimal, rhs: ExactDecimal) -> ExactDecimal {
        ExactDecimal(
            negative: lhs.negative != rhs.negative,
            magnitude: lhs.magnitude * rhs.magnitude,
            exponent: lhs.exponent + rhs.exponent
        )
    }

    // MARK: Back to Decimal

    /// A value rounded into a `Decimal`.
    struct Rounded {
        var value: Decimal
        /// False when digits were dropped.
        var exact: Bool
        /// True when a non-zero value rounded to zero.
        var underflow: Bool
    }

    struct Overflow: Error {}

    /// The precision abakus uses: 38 significant digits, which always fit Decimal's 128-bit significand (39 digits
    /// sometimes do, but a precision that depends on the digits would be hard to state).
    static let precision = 38
    static let significandLimit = BigUInt.powerOfTen(precision)
    /// Decimal's exponent range.
    static let minimumExponent = -128
    static let maximumExponent = 127

    /// Rounds `self / divisor` into a `Decimal`, half away from zero (what Foundation calls `.plain`), to at most
    /// 38 significant digits and at most `maxPlaces` decimal places. Digits below 10^-128 are rounded off.
    /// Throws `Overflow` above Decimal's range (10^165 and more).
    func rounded(dividingBy divisor: BigUInt = .one, maxPlaces: Int = 128) throws(Overflow) -> Rounded {
        precondition(!divisor.isZero, "ExactDecimal division by zero")
        if isZero { return Rounded(value: 0, exact: true, underflow: false) }

        let lowestExponent = max(Self.minimumExponent, -maxPlaces)
        // Start at an exponent where the quotient has more digits than fit, or where no digit is lost; the loop
        // only ever moves up to the first exponent at which the rounded quotient fits.
        var target: Int
        if divisor == .one {
            target = max(lowestExponent, exponent)
        } else {
            // A lower bound for the position of the quotient's leading digit.
            let bits = magnitude.bitWidth - 1 - divisor.bitWidth
            let leading = Int((Double(bits) * 0.30102999566).rounded(.down)) + exponent - 1
            target = max(lowestExponent, leading - 40)
        }

        var quotient: BigUInt
        var remainder: BigUInt
        while true {
            let numerator = magnitude.timesPowerOfTen(max(exponent - target, 0))
            let denominator = divisor.timesPowerOfTen(max(target - exponent, 0))
            (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
            if remainder + remainder >= denominator {
                quotient = quotient + .one
            }
            if quotient < Self.significandLimit { break }
            // With D digits, the quotient cannot fit before D - 38 more places are dropped.
            target += max(1, quotient.decimalDigitCount - Self.precision)
        }

        if target > Self.maximumExponent {
            quotient = quotient.timesPowerOfTen(target - Self.maximumExponent)
            target = Self.maximumExponent
            if quotient >= Self.significandLimit { throw Overflow() }
        }
        let exact = remainder.isZero
        if quotient.isZero {
            return Rounded(value: 0, exact: false, underflow: true)
        }
        return Rounded(value: Self.decimal(negative: negative, significand: quotient, exponent: target), exact: exact, underflow: false)
    }

    /// Builds a `Decimal` from parts that fit: `significand < 10^38`, exponent within -128...127.
    private static func decimal(negative: Bool, significand: BigUInt, exponent: Int) -> Decimal {
        let low = significand.limbs.count > 0 ? significand.limbs[0] : 0
        let high = significand.limbs.count > 1 ? significand.limbs[1] : 0
        let words: [UInt16] = (0..<8).map { index in
            let limb = index < 4 ? low : high
            return UInt16(truncatingIfNeeded: limb >> UInt64(16 * (index % 4)))
        }
        let length = (words.lastIndex { $0 != 0 } ?? -1) + 1
        var value = Decimal(
            _exponent: Int32(exponent),
            _length: UInt32(length),
            _isNegative: negative ? 1 : 0,
            _isCompact: 0,
            _reserved: 0,
            _mantissa: (words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7])
        )
        NSDecimalCompact(&value)
        return value
    }
}
