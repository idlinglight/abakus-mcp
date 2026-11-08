import Foundation

/// Decimal arithmetic that reports what Swift's `+`, `-`, `*` and `/` on `Decimal` hide (ADR-0005): whether
/// the result had to be rounded, and overflow, underflow and division by zero, which become errors.
///
/// Known gap: Foundation's `NSDecimalAdd` & co. never return `.lossOfPrecision`, so `exact` is currently always
/// true. Rounding has to be detected here, by an exact check of the result; the API stays as it is.
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
        try run(a, b, NSDecimalAdd)
    }

    public static func subtract(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try run(a, b, NSDecimalSubtract)
    }

    public static func multiply(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try run(a, b, NSDecimalMultiply)
    }

    public static func divide(_ a: Decimal, _ b: Decimal) throws(ToolError) -> Result {
        try run(a, b, NSDecimalDivide)
    }

    /// Adds all values; `exact` is false if any step rounded.
    public static func sum(_ values: [Decimal]) throws(ToolError) -> Result {
        var total = Result(value: 0, exact: true)
        for value in values {
            let step = try add(total.value, value)
            total = Result(value: step.value, exact: total.exact && step.exact)
        }
        return total
    }

    private typealias Operation = (
        UnsafeMutablePointer<Decimal>, UnsafePointer<Decimal>, UnsafePointer<Decimal>, NSDecimalNumber.RoundingMode
    ) -> NSDecimalNumber.CalculationError

    private static func run(_ a: Decimal, _ b: Decimal, _ operation: Operation) throws(ToolError) -> Result {
        var left = a, right = b, result = Decimal()
        let status = operation(&result, &left, &right, .plain)
        switch status {
        case .noError:
            return Result(value: result, exact: true)
        case .lossOfPrecision:
            return Result(value: result, exact: false)
        case .overflow:
            throw ToolError("The result is too large for exact decimal arithmetic (more than about 10^165).")
        case .underflow:
            throw ToolError("The result is too close to zero for exact decimal arithmetic (below about 10^-128).")
        case .divideByZero:
            throw ToolError("Division by zero.")
        @unknown default:
            throw ToolError("Decimal arithmetic failed.")
        }
    }
}
