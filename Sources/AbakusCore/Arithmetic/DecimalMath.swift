import Foundation

/// Decimal arithmetic that says when a result had to be rounded, and turns overflow, underflow and division by
/// zero into errors (ADR-0005).
///
/// Foundation's `NSDecimalAdd` & co. are not used: they truncate instead of rounding, rarely report the loss, and
/// wrap the exponent around on underflow (`1e-100 × 1e-100` comes back as `1e56`). Every operation here is done
/// exactly on big integers and rounded once at the end, half away from zero, to 38 significant digits.
public enum DecimalMath {
    public struct Result: Sendable, Equatable {
        public var value: Decimal
        /// False when the result had to be rounded.
        public var exact: Bool

        public init(value: Decimal, exact: Bool) {
            self.value = value
            self.exact = exact
        }
    }

    /// How `rounded(_:toPlaces:_:)` and `divide(_:_:toPlaces:_:)` round.
    public enum RoundingMode: Sendable, CaseIterable {
        /// Toward negative infinity: floor. -2.5 becomes -3.
        case down
        /// Toward positive infinity: ceiling. -2.5 becomes -2.
        case up
        /// Drop the digits: truncation. -2.5 becomes -2.
        case towardZero
        /// To the nearest; a tie goes away from zero (commercial rounding). -2.5 becomes -3.
        case halfAwayFromZero
    }

    /// The significant digits a readable result keeps when it is not exact (`readableQuotient`, the mean of `sum`,
    /// the totals of `date_diff`).
    public static let readableSignificantDigits = ExactDecimal.readableDigits

    /// The decimal places `rounded(_:toPlaces:_:)` and `divide(_:_:toPlaces:_:)` accept, -165 to 128: from where a
    /// `Decimal` ends (10^165) down to its smallest step (10^-128).
    static let placesRange = -ExactDecimal.overflowExponent ... -ExactDecimal.minimumExponent

    public static func add(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try round(try exact(a) + exact(b))
    }

    public static func subtract(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try round(try exact(a) + -exact(b))
    }

    public static func multiply(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try round(try exact(a) * exact(b))
    }

    public static func divide(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        let (dividend, divisor) = try quotientParts(a, b)
        return try round(dividend, dividingBy: divisor)
    }

    /// `a / b` for showing to people, such as an average: exact when the quotient fits 38 significant digits;
    /// otherwise rounded half away from zero to 15 significant digits, or to whole units when the integer part has
    /// more than 15 digits. 1/3 is 0.333333333333333, 1/8 is 0.125 (exact). A non-zero quotient never comes back
    /// as 0: below 10^-128 it is an underflow error, as in `divide`.
    public static func readableQuotient(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        let (dividend, divisor) = try quotientParts(a, b)
        return try round(dividend, dividingBy: divisor, .readable)
    }

    /// The sum of all values, added exactly and rounded once: `exact` is false only if the total itself had to
    /// be rounded. No intermediate step can round or overflow.
    public static func sum(_ values: [Decimal]) throws(ToolError) -> Result {
        try round(try exactSum(values))
    }

    // MARK: Rounding to decimal places

    /// `value` rounded to `places` decimal places (0: a whole number; negative: tens, hundreds, ...), from -165 to
    /// 128. `exact` is true when nothing was dropped.
    public static func rounded(_ value: Decimal, toPlaces places: Int, _ mode: RoundingMode) throws(ToolError) -> Result {
        try divide(value, 1, toPlaces: places, mode)
    }

    /// `a / b` rounded to `places` decimal places in the given mode, computed exactly: the quotient is never rounded
    /// to 38 digits first. `divide(value, period, toPlaces: 0, .down)` is floor(value / period); `exact` says
    /// whether the quotient was a whole number. A result with more than 38 significant digits is an error.
    public static func divide(_ a: Decimal, _ b: Decimal, toPlaces places: Int, _ mode: RoundingMode) throws(ToolError) -> Result {
        guard placesRange.contains(places) else {
            throw ToolError(
                "Cannot round to \(places) decimal places: abakus rounds to between \(placesRange.lowerBound) and "
                    + "\(placesRange.upperBound) places."
            )
        }
        let (dividend, divisor) = try quotientParts(a, b)
        do {
            let (value, exact) = try dividend.rounded(dividingBy: divisor, toPlaces: places, mode)
            return Result(value: value, exact: exact)
        } catch .overflow {
            throw overflow
        } catch {
            throw ToolError(
                "The result rounded to \(places) decimal places has more than 38 significant digits, more than exact "
                    + "decimal arithmetic holds."
            )
        }
    }

    /// The largest whole number not above `value`, exactly. NaN stays NaN.
    public static func floor(_ value: Decimal) -> Decimal {
        guard !value.isNaN else { return value }
        do {
            return try rounded(value, toPlaces: 0, .down).value
        } catch {
            // The floor of a Decimal has no more digits than the Decimal and is never larger in magnitude by more
            // than 1, so it always fits.
            preconditionFailure("floor(\(value)) did not fit: \(error.message)")
        }
    }

    /// Whether `value` is a whole number, exactly. False for NaN.
    public static func isInteger(_ value: Decimal) -> Bool {
        guard !value.isNaN else { return false }
        return (try? rounded(value, toPlaces: 0, .towardZero).exact) ?? false
    }

    // MARK: Internals shared with the tools

    static func exact(_ value: Decimal) throws(ToolError) -> ExactDecimal {
        guard !value.isNaN else { throw ToolError("A value is not a number (NaN); decimal arithmetic needs numbers.") }
        return ExactDecimal(value)
    }

    static func exactSum(_ values: [Decimal]) throws(ToolError) -> ExactDecimal {
        var total = ExactDecimal.zero
        for value in values {
            total = total + (try exact(value))
        }
        return total
    }

    /// `roundedResult`, with the errors the tools report.
    static func round(
        _ value: ExactDecimal, dividingBy divisor: BigUInt = .one, _ precision: ExactDecimal.Precision = .full
    ) throws(ToolError) -> Result {
        do {
            return try roundedResult(value, dividingBy: divisor, precision)
        } catch {
            switch error {
            case .overflow: throw overflow
            case .underflow: throw underflow
            }
        }
    }

    /// Why an exact value does not fit a `Decimal` result.
    enum ResultRangeError: Error, Equatable {
        /// 10^165 or more.
        case overflow
        /// Not zero, but 0 when rounded at 10^-128, the smallest step a `Decimal` holds.
        case underflow
    }

    /// Rounds an exact value (divided by `divisor`) into a `Decimal`: the one place where results are rounded, for
    /// `round` above and for `calc`'s fractions, which each turn the range errors into their own. `.readable` is the
    /// policy for values shown to people (ADR-0005).
    static func roundedResult(
        _ value: ExactDecimal, dividingBy divisor: BigUInt = .one, _ precision: ExactDecimal.Precision = .full
    ) throws(ResultRangeError) -> Result {
        let rounded: ExactDecimal.Rounded
        do {
            rounded = try value.rounded(dividingBy: divisor, precision)
        } catch {
            switch error {
            case .overflow:
                throw .overflow
            case .tooManyDigits:
                // Both precisions round to 38 significant digits or fewer; a carry to 10^38 leaves a single digit
                // once its zeros move into the exponent. Only rounding to fixed places can have more.
                preconditionFailure("Rounding to \(ExactDecimal.precision) significant digits left more digits.")
            }
        }
        if rounded.underflow { throw .underflow }
        return Result(value: rounded.value, exact: rounded.exact)
    }

    /// `a / b` as an exact value over an integer divisor.
    private static func quotientParts(_ a: Decimal, _ b: Decimal) throws(ToolError) -> (ExactDecimal, BigUInt) {
        let dividend = try exact(a)
        let divisor = try exact(b)
        guard !divisor.isZero else { throw ToolError("Division by zero.") }
        let scaled = ExactDecimal(
            negative: dividend.negative != divisor.negative,
            magnitude: dividend.magnitude,
            exponent: dividend.exponent - divisor.exponent
        )
        return (scaled, divisor.magnitude)
    }

    static let overflow = ToolError(
        "The result is too large for exact decimal arithmetic (about 10^\(ExactDecimal.overflowExponent) or more)."
    )
    static let underflow = ToolError(
        "The result is too close to zero for exact decimal arithmetic (below 10^\(ExactDecimal.minimumExponent))."
    )
}
