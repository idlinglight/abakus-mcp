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

    /// How a value goes back into a `Decimal`.
    enum Precision {
        /// 38 significant digits: the results of DecimalMath's arithmetic.
        case full
        /// Exact when the value fits 38 significant digits; otherwise 15 significant digits, or whole units when
        /// the integer part is longer: values shown to people, such as a mean or a total in days.
        case readable
    }

    /// A value rounded into a `Decimal`.
    struct Rounded {
        var value: Decimal
        /// False when digits were dropped.
        var exact: Bool
        /// True when a non-zero value rounded to zero.
        var underflow: Bool
    }

    enum RangeError: Error {
        /// 10^165 or more.
        case overflow
        /// More than 38 significant digits at the requested decimal places.
        case tooManyDigits
    }

    /// The precision abakus uses: 38 significant digits, which always fit Decimal's 128-bit significand (39 digits
    /// sometimes do, but a precision that depends on the digits would be hard to state).
    static let precision = 38
    /// The significant digits a readable result keeps when it is not exact.
    static let readableDigits = 15
    static let significandLimit = BigUInt.powerOfTen(precision)
    /// Decimal's exponent range.
    static let minimumExponent = -128
    static let maximumExponent = 127
    /// 165: 38 digits with the largest exponent stay below 10^165; a value from there on is an overflow.
    static let overflowExponent = maximumExponent + precision
    static let overflowLimit = BigUInt.powerOfTen(overflowExponent)

    /// Rounds `self / divisor` into a `Decimal`, half away from zero (what Foundation calls `.plain`), with the
    /// given precision. Digits below 10^-128 are rounded off; a non-zero value that rounds to zero comes back as
    /// 0 with `underflow` set. Throws `.overflow` from 10^165 on.
    func rounded(dividingBy divisor: BigUInt = .one, _ precision: Precision = .full) throws(RangeError) -> Rounded {
        precondition(!divisor.isZero, "ExactDecimal division by zero")
        if isZero { return Rounded(value: 0, exact: true, underflow: false) }

        // Divide once, at an exponent fine enough for every rounding below.
        let base: Int
        if divisor == .one {
            // Below its own exponent the value has only zeros.
            base = max(Self.minimumExponent, exponent)
        } else {
            // 40 places below a lower bound for the quotient's leading digit: more digits than 38.
            let bits = magnitude.bitWidth - 1 - divisor.bitWidth
            let leading = Int((Double(bits) * 0.30102999566).rounded(.down)) + exponent - 1
            base = max(Self.minimumExponent, leading - 40)
        }
        let division = Division(self, dividingBy: divisor, at: base)

        // `lead` is nil when the value is below 10^base, and base is then 10^-128.
        let lead = division.leadingExponent
        var target = lead.map { max(base, $0 - (Self.precision - 1)) } ?? base
        var (significand, exact) = division.rounded(at: target, .halfAwayFromZero)
        if !exact, precision == .readable, let lead {
            let wholeUnits = max(0, lead - (Self.precision - 1))
            target = max(base, min(lead - (Self.readableDigits - 1), wholeUnits))
            significand = division.rounded(at: target, .halfAwayFromZero).significand
        }
        if significand.isZero { return Rounded(value: 0, exact: false, underflow: true) }
        let value = try Self.decimal(negative: negative, significand: significand, exponent: target)
        return Rounded(value: value, exact: exact, underflow: false)
    }

    /// Rounds `self / divisor` to `places` decimal places (negative: to tens, hundreds, ...) in the given mode.
    /// A result of 0 is a result here, not an underflow. Throws when the result does not fit a `Decimal`.
    func rounded(
        dividingBy divisor: BigUInt = .one, toPlaces places: Int, _ mode: DecimalMath.RoundingMode
    ) throws(RangeError) -> (value: Decimal, exact: Bool) {
        precondition(!divisor.isZero, "ExactDecimal division by zero")
        precondition(-places >= Self.minimumExponent, "rounding below 10^-128")
        if isZero { return (0, true) }
        let division = Division(self, dividingBy: divisor, at: -places)
        let (significand, exact) = division.rounded(at: -places, mode)
        if significand.isZero { return (0, exact) }
        return (try Self.decimal(negative: negative, significand: significand, exponent: -places), exact)
    }

    /// `|value| / divisor` cut off at 10^base: one long division, from which every coarser rounding follows
    /// without dividing again.
    private struct Division {
        let negative: Bool
        let base: Int
        /// floor(|value| / divisor / 10^base)
        let truncated: BigUInt
        let remainderIsZero: Bool
        /// Whether the remainder is at least half a unit at 10^base.
        let remainderIsHalfOrMore: Bool

        init(_ value: ExactDecimal, dividingBy divisor: BigUInt, at base: Int) {
            let numerator = value.magnitude.timesPowerOfTen(max(value.exponent - base, 0))
            let denominator = divisor.timesPowerOfTen(max(base - value.exponent, 0))
            let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
            negative = value.negative
            self.base = base
            truncated = quotient
            remainderIsZero = remainder.isZero
            remainderIsHalfOrMore = remainder + remainder >= denominator
        }

        /// The exponent of the leading digit, or nil when the value is below 10^base.
        var leadingExponent: Int? {
            truncated.isZero ? nil : base + truncated.decimalDigitCount - 1
        }

        /// The value rounded at 10^target (`target >= base`), as the significand for that exponent.
        func rounded(at target: Int, _ mode: DecimalMath.RoundingMode) -> (significand: BigUInt, exact: Bool) {
            precondition(target >= base, "rounding finer than the division")
            var quotient = truncated
            var halfOrMore = remainderIsHalfOrMore
            var tailIsZero = remainderIsZero
            if target > base {
                let (cut, dropped) = truncated.quotientAndRemainder(dividingBy: BigUInt.powerOfTen(target - base))
                quotient = cut
                // Half a unit at 10^target is a whole number of units at 10^base, so the remainder below 10^base
                // cannot tip the comparison.
                halfOrMore = dropped >= BigUInt.powerOfTen(target - base - 1) * BigUInt(5)
                tailIsZero = dropped.isZero && remainderIsZero
            }
            let up = switch mode {
            case .towardZero: false
            case .halfAwayFromZero: halfOrMore
            case .down: negative && !tailIsZero
            case .up: !negative && !tailIsZero
            }
            return (up ? quotient + .one : quotient, tailIsZero)
        }
    }

    /// Builds a `Decimal` from a significand and an exponent of -128 or more, moving trailing zeros into the
    /// exponent, or exponent digits into the significand, where needed.
    private static func decimal(negative: Bool, significand: BigUInt, exponent: Int) throws(RangeError) -> Decimal {
        precondition(exponent >= minimumExponent)
        var significand = significand
        var exponent = exponent
        if significand >= significandLimit || exponent > maximumExponent {
            let (stripped, zeros) = significand.strippingTrailingDecimalZeros()
            significand = stripped
            exponent += zeros
            if significand >= significandLimit { throw .tooManyDigits }
            if exponent > maximumExponent {
                significand = significand.timesPowerOfTen(exponent - maximumExponent)
                exponent = maximumExponent
                if significand >= significandLimit { throw .overflow }
            }
        }
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
