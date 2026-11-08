import Foundation

/// An exact rational number, the arithmetic of `calc` (ADR-0007): a sign, and a numerator over a denominator that
/// is always reduced (their gcd is 1) and positive. Zero has one representation, `0/1`, and is never negative, so
/// two equal values are always equal field by field.
///
/// Nothing is rounded on the way. Every value an operation produces, the intermediate results of an expression
/// included, has at most `digitLimit` decimal digits in its numerator and in its denominator; more is an error
/// (`FractionError.tooManyDigits`). Only `decimalResult()` rounds, once, to a `Decimal`.
///
/// Built on `BigUInt` and `ExactDecimal`; Foundation's `Decimal` arithmetic is never used (ADR-0005).
struct Fraction: Sendable, Equatable, Comparable, CustomStringConvertible {
    /// True below zero; zero is never negative.
    let negative: Bool
    let numerator: BigUInt
    /// 1 or more; 1 for whole numbers and for zero.
    let denominator: BigUInt

    // MARK: Limits

    /// The most decimal digits a numerator or denominator may have, in every value an operation produces.
    static let digitLimit = 2000
    /// The exponents `raised(to:)` accepts.
    static let exponentRange = -9999...9999
    /// The places `rounded(toPlaces:)` accepts, as in `DecimalMath.rounded(_:toPlaces:_:)`.
    static let placesRange = -165...128
    /// `decimalResult()` gives the exact value as text only while numerator and denominator have at most this many
    /// digits each.
    static let fractionTextDigitLimit = 100

    /// 10^digitLimit, the smallest number with too many digits.
    private static let smallestTooLong = BigUInt.powerOfTen(digitLimit)
    private static let fractionTextLimit = BigUInt.powerOfTen(fractionTextDigitLimit)
    /// 10^165: a result this large or larger is an overflow (ADR-0005).
    private static let overflowLimit = BigUInt.powerOfTen(165)

    static let zero = Fraction(reduced: false, .zero, .one)
    static let one = Fraction(1)

    // MARK: Construction

    /// Takes the parts as they are: reduced, denominator positive, within the limits.
    private init(reduced negative: Bool, _ numerator: BigUInt, _ denominator: BigUInt) {
        self.negative = negative && !numerator.isZero
        self.numerator = numerator
        self.denominator = numerator.isZero ? .one : denominator
    }

    init(_ value: Int) {
        self.init(reduced: value < 0, BigUInt(UInt64(value.magnitude)), .one)
    }

    /// The exact value of a `Decimal`. Every finite `Decimal` converts exactly and stays far within the limits: at
    /// most 39 significant digits, exponents from -128 to 127.
    init(_ value: Decimal) throws(FractionError) {
        guard !value.isNaN else { throw .notANumber }
        let exact = ExactDecimal(value)
        if exact.exponent >= 0 {
            self.init(reduced: exact.negative, exact.magnitude.timesPowerOfTen(exact.exponent), .one)
        } else {
            try self.init(
                negative: exact.negative, numerator: exact.magnitude, denominator: .powerOfTen(-exact.exponent)
            )
        }
    }

    /// `±numerator / denominator`, reduced. A zero denominator is a division by zero.
    init(negative: Bool = false, numerator: BigUInt, denominator: BigUInt) throws(FractionError) {
        guard !denominator.isZero else { throw .divisionByZero }
        let common = BigUInt.gcd(numerator, denominator)
        self = try Self.checked(
            negative: negative, numerator.dividedExactly(by: common), denominator.dividedExactly(by: common)
        )
    }

    /// Reduced parts, checked against the digit limit.
    private static func checked(
        negative: Bool, _ numerator: BigUInt, _ denominator: BigUInt
    ) throws(FractionError) -> Fraction {
        guard numerator < smallestTooLong, denominator < smallestTooLong else { throw .tooManyDigits }
        return Fraction(reduced: negative, numerator, denominator)
    }

    // MARK: Properties

    var isZero: Bool { numerator.isZero }

    var isWholeNumber: Bool { denominator == .one }

    /// The value as an `Int` when it is a whole number within `range`; nil otherwise. For exponents and places.
    func integer(in range: ClosedRange<Int>) -> Int? {
        guard isWholeNumber, numerator.limbs.count <= 1 else { return nil }
        let magnitude = numerator.limbs.first ?? 0
        guard magnitude <= UInt64(Int.max) else { return nil }
        let value = negative ? -Int(magnitude) : Int(magnitude)
        return range.contains(value) ? value : nil
    }

    /// `numerator/denominator` with a leading `-` below zero: `-1/3`, `5/1`, `0/1`.
    var description: String {
        (negative ? "-" : "") + numerator.description + "/" + denominator.description
    }

    // MARK: Arithmetic

    static prefix func - (value: Fraction) -> Fraction {
        Fraction(reduced: !value.negative, value.numerator, value.denominator)
    }

    /// The absolute value.
    var magnitude: Fraction {
        Fraction(reduced: false, numerator, denominator)
    }

    static func + (lhs: Fraction, rhs: Fraction) throws(FractionError) -> Fraction {
        if lhs.isZero { return rhs }
        if rhs.isZero { return lhs }
        // a/b + c/d with g = gcd(b, d): (a·(d/g) + c·(b/g)) / ((b/g)·d). A common factor of that numerator and
        // denominator can only lie in g (Knuth, TAOCP 4.5.1), so the second gcd is taken with g alone, and not at
        // all when g is 1.
        let g = BigUInt.gcd(lhs.denominator, rhs.denominator)
        let lhsDenominatorPart = lhs.denominator.dividedExactly(by: g)
        let rhsDenominatorPart = rhs.denominator.dividedExactly(by: g)
        let x = lhs.numerator * rhsDenominatorPart
        let y = rhs.numerator * lhsDenominatorPart
        let negative: Bool
        let sum: BigUInt
        if lhs.negative == rhs.negative {
            (negative, sum) = (lhs.negative, x + y)
        } else if x >= y {
            (negative, sum) = (lhs.negative, x - y)
        } else {
            (negative, sum) = (rhs.negative, y - x)
        }
        if sum.isZero { return .zero }
        let common = g == .one ? .one : BigUInt.gcd(sum, g)
        return try checked(
            negative: negative,
            sum.dividedExactly(by: common),
            lhsDenominatorPart * rhs.denominator.dividedExactly(by: common)
        )
    }

    static func - (lhs: Fraction, rhs: Fraction) throws(FractionError) -> Fraction {
        try lhs + -rhs
    }

    static func * (lhs: Fraction, rhs: Fraction) throws(FractionError) -> Fraction {
        if lhs.isZero || rhs.isZero { return .zero }
        // Cancel crosswise first: (a/b)·(c/d) = ((a/g1)·(c/g2)) / ((b/g2)·(d/g1)), already reduced.
        let g1 = BigUInt.gcd(lhs.numerator, rhs.denominator)
        let g2 = BigUInt.gcd(rhs.numerator, lhs.denominator)
        return try checked(
            negative: lhs.negative != rhs.negative,
            lhs.numerator.dividedExactly(by: g1) * rhs.numerator.dividedExactly(by: g2),
            lhs.denominator.dividedExactly(by: g2) * rhs.denominator.dividedExactly(by: g1)
        )
    }

    static func / (lhs: Fraction, rhs: Fraction) throws(FractionError) -> Fraction {
        guard !rhs.isZero else { throw .divisionByZero }
        return try lhs * Fraction(reduced: rhs.negative, rhs.denominator, rhs.numerator)
    }

    static func < (lhs: Fraction, rhs: Fraction) -> Bool {
        if lhs.negative != rhs.negative { return lhs.negative }
        let left = lhs.numerator * rhs.denominator
        let right = rhs.numerator * lhs.denominator
        return lhs.negative ? right < left : left < right
    }

    // MARK: Powers

    /// `self ^ exponent` for a whole-number exponent in `exponentRange`; a fractional exponent would be a root.
    func raised(to exponent: Fraction) throws(FractionError) -> Fraction {
        guard exponent.isWholeNumber else { throw .exponentNotWhole }
        guard let exponent = exponent.integer(in: Self.exponentRange) else { throw .exponentOutOfRange }
        return try raised(to: exponent)
    }

    /// `self ^ exponent` for an exponent in `exponentRange`. `0^0` is 1, the empty product; 0 to a negative power
    /// is a division by zero. A result beyond the digit limit is refused before it is computed when its size
    /// alone shows that, so `9^9999` fails at once.
    func raised(to exponent: Int) throws(FractionError) -> Fraction {
        guard Self.exponentRange.contains(exponent) else { throw .exponentOutOfRange }
        if exponent == 0 { return .one }
        if isZero {
            guard exponent > 0 else { throw .divisionByZero }
            return .zero
        }
        let count = exponent.magnitude
        // Powers of coprime numbers stay coprime: no gcd needed.
        let (top, bottom) = exponent > 0 ? (numerator, denominator) : (denominator, numerator)
        return try Self.checked(
            negative: negative && count % 2 == 1,
            try Self.power(top, Int(count)),
            try Self.power(bottom, Int(count))
        )
    }

    /// `base ^ count` for `count >= 1`, or `.tooManyDigits` as soon as that is certain.
    private static func power(_ base: BigUInt, _ count: Int) throws(FractionError) -> BigUInt {
        if base == .one { return .one }
        // base >= 2^(bitWidth - 1), so the power is at least 2^((bitWidth - 1) · count): too large when that
        // reaches the limit's bit width.
        guard (base.bitWidth - 1) * count < smallestTooLong.bitWidth else { throw .tooManyDigits }
        // Square and multiply from the top bit down: every partial result is base^k with k <= count, never larger
        // than the result, so stopping at the first one over the limit is right. After the estimate, base^count is
        // below 2^(bitWidth · count) <= 2^(2 · (bitWidth - 1) · count), so nothing computed has much more than twice
        // the limit's digits.
        var result = BigUInt.one
        for bit in stride(from: Int.bitWidth - count.leadingZeroBitCount - 1, through: 0, by: -1) {
            result = result * result
            if (count >> bit) & 1 == 1 { result = result * base }
            guard result < smallestTooLong else { throw .tooManyDigits }
        }
        return result
    }

    // MARK: Rounding

    /// Rounded to `places` decimal places (negative: to tens, hundreds, ...), half away from zero. `places` must be
    /// a whole number in `placesRange`.
    func rounded(toPlaces places: Fraction) throws(FractionError) -> Fraction {
        guard places.isWholeNumber else { throw .placesNotWhole }
        guard let places = places.integer(in: Self.placesRange) else { throw .placesOutOfRange }
        return try rounded(toPlaces: places)
    }

    /// Rounded to `places` decimal places (negative: to tens, hundreds, ...), half away from zero, exactly: 2.5 to
    /// 0 places is 3, -2.5 is -3, 1/3 to 2 places is 33/100.
    func rounded(toPlaces places: Int) throws(FractionError) -> Fraction {
        guard Self.placesRange.contains(places) else { throw .placesOutOfRange }
        if isZero || (isWholeNumber && places >= 0) { return self }
        let scale = BigUInt.powerOfTen(abs(places))
        let (dividend, divisor) = places >= 0 ? (numerator * scale, denominator) : (numerator, denominator * scale)
        var (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
        if remainder + remainder >= divisor { quotient = quotient + .one }
        if places < 0 { return try Self.checked(negative: negative, quotient * scale, .one) }
        let common = BigUInt.gcd(quotient, scale)
        return try Self.checked(
            negative: negative, quotient.dividedExactly(by: common), scale.dividedExactly(by: common)
        )
    }

    // MARK: The result

    /// The value rounded once into a `Decimal` for the response of `calc`.
    struct DecimalResult: Sendable, Equatable {
        var value: Decimal
        /// False when `value` had to be rounded.
        var exact: Bool
        /// The exact value as `numerator/denominator` (`"-1/3"`), when `value` was rounded and both parts have at
        /// most `fractionTextDigitLimit` digits; nil otherwise.
        var fraction: String?
    }

    /// Rounds once by the readable policy of ADR-0005, as `DecimalMath.readableQuotient` does: exact when the value
    /// is a terminating decimal that fits 38 significant digits (and 10^-128 as the smallest step); otherwise 15
    /// significant digits, or whole units when the integer part is longer (38 digits at most), half away from
    /// zero. 10^165 or more is an overflow; a non-zero value that rounds to 0 at 10^-128 an underflow.
    func decimalResult() throws(FractionError) -> DecimalResult {
        if isZero { return DecimalResult(value: 0, exact: true, fraction: nil) }
        // Settled without dividing: the rounding below would come to the same, after a long division.
        guard numerator < denominator * Self.overflowLimit else { throw .overflow }
        let rounded: ExactDecimal.Rounded
        do {
            rounded = try ExactDecimal(negative: negative, magnitude: numerator, exponent: 0)
                .rounded(dividingBy: denominator, .readable)
        } catch {
            // `.readable` keeps at most 38 digits, so overflow is the only range error left.
            throw .overflow
        }
        if rounded.underflow { throw .underflow }
        let short = numerator < Self.fractionTextLimit && denominator < Self.fractionTextLimit
        return DecimalResult(
            value: rounded.value, exact: rounded.exact, fraction: rounded.exact || !short ? nil : description
        )
    }
}

/// Why an exact computation failed. No message text: `calc` turns these into messages that say where in the
/// expression it happened and what to do instead.
enum FractionError: Error, Sendable, Equatable {
    /// A division by zero, or 0 raised to a negative power.
    case divisionByZero
    /// A numerator or denominator would have more than `Fraction.digitLimit` digits.
    case tooManyDigits
    /// A power's exponent is not a whole number: that would be a root.
    case exponentNotWhole
    /// A power's exponent is a whole number outside `Fraction.exponentRange`.
    case exponentOutOfRange
    /// Rounding places that are not a whole number.
    case placesNotWhole
    /// Rounding places outside `Fraction.placesRange`.
    case placesOutOfRange
    /// The result is 10^165 or more.
    case overflow
    /// The result is not zero, but rounds to 0 at 10^-128, the smallest step a `Decimal` holds.
    case underflow
    /// A `Decimal` operand is NaN.
    case notANumber
}

extension BigUInt {
    /// `self / divisor` when the division leaves no remainder (a gcd or a factor of `self`).
    fileprivate func dividedExactly(by divisor: BigUInt) -> BigUInt {
        if divisor == .one { return self }
        let (quotient, remainder) = quotientAndRemainder(dividingBy: divisor)
        assert(remainder.isZero, "dividedExactly(by:) left a remainder")
        return quotient
    }
}
