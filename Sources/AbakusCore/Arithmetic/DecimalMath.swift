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
        /// False when the result had to be rounded to fit 38 significant digits.
        public var exact: Bool

        public init(value: Decimal, exact: Bool) {
            self.value = value
            self.exact = exact
        }
    }

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
        try divide(a, b, maxPlaces: 128)
    }

    /// `a / b`, exact when the quotient fits a `Decimal`; otherwise rounded half away from zero to at most
    /// `places` decimal places (fewer only when 38 significant digits run out first). For values shown to
    /// people, such as a mean: `divide(1, 3, roundingInexactTo: 6)` is 0.333333 (inexact) rather than
    /// 0.33333333333333333333333333333333333333; `divide(1, 8, roundingInexactTo: 2)` is 0.125 (exact).
    public static func divide(_ a: Decimal, _ b: Decimal, roundingInexactTo places: Int) throws(ToolError) -> Result {
        let full = try divide(a, b, maxPlaces: 128)
        return full.exact ? full : try divide(a, b, maxPlaces: places)
    }

    /// The sum of all values, added exactly and rounded once: `exact` is false only if the total itself had to
    /// be rounded. No intermediate step can round or overflow.
    public static func sum(_ values: [Decimal]) throws(ToolError) -> Result {
        try round(try exactSum(values))
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

    /// Rounds an exact value (divided by `divisor`) into a `Decimal`, with the errors the tools report.
    static func round(_ value: ExactDecimal, dividingBy divisor: BigUInt = .one, maxPlaces: Int = 128) throws(ToolError) -> Result {
        let rounded: ExactDecimal.Rounded
        do {
            rounded = try value.rounded(dividingBy: divisor, maxPlaces: maxPlaces)
        } catch {
            throw overflow
        }
        if rounded.underflow { throw underflow }
        return Result(value: rounded.value, exact: rounded.exact)
    }

    private static func divide(_ a: Decimal, _ b: Decimal, maxPlaces: Int) throws(ToolError) -> Result {
        let dividend = try exact(a)
        let divisor = try exact(b)
        guard !divisor.isZero else { throw ToolError("Division by zero.") }
        let scaled = ExactDecimal(
            negative: dividend.negative != divisor.negative,
            magnitude: dividend.magnitude,
            exponent: dividend.exponent - divisor.exponent
        )
        return try round(scaled, dividingBy: divisor.magnitude, maxPlaces: maxPlaces)
    }

    static let overflow = ToolError("The result is too large for exact decimal arithmetic (about 10^165 or more).")
    static let underflow = ToolError("The result is too close to zero for exact decimal arithmetic (below 10^-128).")
}
