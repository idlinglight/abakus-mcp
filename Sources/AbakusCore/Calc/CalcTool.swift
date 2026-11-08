import Foundation

/// `calc`: works out one expression with exact fractions, over numbers and tallies by name (ADR-0007).
///
/// The expression is parsed (`CalcParser`), the tallies it names are read under one lock, and the tree is worked
/// out from the leaves up with `CalcExpression.fold`, never recursively: a 1000-character chain of one operator is
/// a tree about 500 levels deep. Nothing is rounded until `Fraction.decimalResult()` rounds the result, once.
public struct CalcTool: Tool {
    public init() {}

    public let name = "calc"

    public let description = """
        Work out one arithmetic expression exactly, such as a rate from two tallies or what is left of a budget. \
        Stateless: it reads tallies and never changes them.

        Argument: expression, the formula as a string.

        Numbers: 12, 0.5, .5, 2.5e3, or with one suffix: k or K (thousand), M (million), G (billion), T \
        (trillion); a lowercase m is refused. The decimal mark is "."; no thousands separators: write 1234567, not \
        1,234,567. Numbers may stand anywhere, inside parentheses and function calls too.

        Operators: + and -; * or × to multiply; / or ÷ to divide; ^ or ** for powers with a whole-number exponent \
        from -9999 to 9999 and any base (2^10, 1.045^10, 2^-1). Powers bind tighter than a leading minus and group \
        from the right: -2^2 is -(2^2) = -4, (-2)^2 is 4, 2^3^2 is 2^9. Parentheses group. No implicit \
        multiplication: write 2*(3+4), not 2(3+4).

        Functions: abs(x), round(x, places) (half away from zero; round(x, 0) for a whole number), min(a, b, ...), \
        max(a, b, ...). Separate arguments with a comma and a space: a comma between two digits is refused as a \
        thousands separator. There is no square root, no constants and no units.

        No % operator: for a percentage, multiply by 100 (37 / 1250 * 100); to add 10%, multiply by 1.1.

        Tallies: a tally's full name in braces stands for its value: {errors-k3f9}. Add :count for its count, the \
        number of additions: {effort-a1b2:count}. Any tally works, shared ones (which have no suffix) too; for your \
        own, use the name tally_create returned, suffix included. All are read at the same moment. An unknown name \
        is an error, and nothing is computed. Example: {"expression": "{errors-k3f9} / {requests-p2x7} * 100"}.

        Nothing is rounded before the result: the arithmetic is exact across the whole expression (1/3*3 is 1), so \
        put the whole formula into one call instead of feeding a rounded result into the next. The result is a \
        JSON number, exact when it fits in 38 significant digits; otherwise it is rounded half away from zero to 15 \
        significant digits (to whole units when the integer part is longer), exact: false is added, and fraction \
        gives the exact value as a string ("1/3"), left out when its numerator or denominator has more than 100 \
        digits. Trailing zeros are dropped: round(12.5, 2) gives 12.5. A tally whose value was rounded before \
        (exact: false in its state) makes the result exact: false too.

        Response: {"result", "read", "tallies"}. read is the expression as it was understood, numbers written out \
        (410k as 410000) and parentheses around every operation but the outermost; check it when the expression \
        could be read two ways. tallies (left out when there are none) lists each tally used with the number taken \
        from it, as {"name", "of": "value" or "count", "value"}, plus "exact": false for a rounded one. exact: false \
        appears only when the result was rounded or uses a rounded tally, fraction only when the result itself was \
        rounded.
        """

    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "expression": [
                "type": "string",
                "description": "The formula, such as \"{errors-k3f9} / {requests-p2x7} * 100\" or \"round(1000 * 1.045^10, 2)\".",
            ],
        ],
        "required": ["expression"],
        "additionalProperties": false,
    ]

    public let annotations = ToolAnnotations(
        title: "Exact calculation", readOnly: true, destructive: false, idempotent: true
    )

    public func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        try UnknownArguments.refuse(arguments, for: self)
        let text = try Self.expressionArgument(arguments["expression"])
        let expression = try CalcParser.parse(text)

        // Without references the state folder is never touched.
        let references = Self.references(in: expression)
        let tallies = references.isEmpty ? [:] : try Self.read(references.map(\.name), in: context)
        let used = references.map { reference in
            // read(_:in:) returns every name asked for or throws.
            UsedTally(reference: reference, tally: tallies[reference.name]!)
        }

        let value = try Self.evaluate(expression, text: text, tallies: tallies, used: used)
        let rounded: Fraction.DecimalResult
        do throws(FractionError) {
            rounded = try value.decimalResult()
        } catch {
            throw Self.resultError(error, used: used)
        }

        var result: JSONObject = ["result": .decimal(rounded.value)]
        // A tally's rounded value makes the result inexact even when the result itself needed no rounding; the
        // fraction is only for a rounding done here, which it undoes.
        if !rounded.exact || used.contains(where: \.isInexact) { result["exact"] = false }
        if let fraction = rounded.fraction { result["fraction"] = .string(fraction) }
        result["read"] = .string(expression.rendered)
        if !used.isEmpty { result["tallies"] = .array(used.map { .object($0.entry) }) }
        return result
    }

    // MARK: Arguments

    private static func expressionArgument(_ value: JSONValue?) throws(ToolError) -> String {
        let example = #"{"expression": "{errors-k3f9} / {requests-p2x7} * 100"}"#
        guard let value, !value.isNull else {
            throw ToolError("Missing argument \"expression\": pass the formula as a string, e.g. \(example).")
        }
        guard let text = value.stringValue else {
            throw ToolError(
                "expression must be a string with the formula, not \(Self.kind(of: value)); e.g. \(example) or "
                    + #"{"expression": "1250 * 1.19"}."#
            )
        }
        return text
    }

    private static func kind(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "true or false"
        case .number: "a JSON number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }

    // MARK: Tallies

    /// A tally reference as the response lists it: a name and what is taken from the tally.
    struct Reference: Hashable {
        var name: String
        var of: CalcTallyField
    }

    /// One distinct reference with the tally it was read from.
    struct UsedTally {
        var reference: Reference
        var tally: Tally

        /// A rounded value went into the result. A count is always exact.
        var isInexact: Bool { reference.of == .value && !tally.exact }

        /// `{"name", "of", "value"}`, plus `"exact": false` for a rounded value.
        var entry: JSONObject {
            var object: JSONObject = ["name": .string(reference.name), "of": .string(reference.of.rawValue)]
            switch reference.of {
            case .value: object["value"] = .decimal(tally.value)
            case .count: object["value"] = .number(String(tally.count))
            }
            if isInexact { object["exact"] = false }
            return object
        }
    }

    /// Each distinct reference once, in the order of first appearance in the text. `fold` combines the leaves
    /// left to right.
    static func references(in expression: CalcExpression) -> [Reference] {
        var references: [Reference] = []
        var seen: Set<Reference> = []
        expression.fold { (node: CalcExpression, _: [Void]) in
            if case .tally(let name, let of) = node.node, seen.insert(Reference(name: name, of: of)).inserted {
                references.append(Reference(name: name, of: of))
            }
        }
        return references
    }

    /// The named tallies, all under one shared lock, so their values come from one moment. The first name without
    /// a tally, in the order given, is the tally tools' unknown-name error.
    private static func read(_ names: [String], in context: ToolContext) throws(ToolError) -> [String: Tally] {
        try TallyStore(context).read { files throws(ToolError) in
            var tallies: [String: Tally] = [:]
            for name in names where tallies[name] == nil {
                switch try files.inspect(name) {
                case .tally(let tally):
                    tallies[name] = tally
                case .missing:
                    throw try files.unknown(name, use: .read)
                case .unreadable(let problem):
                    let error = TallyErrors.unreadable(name, path: files.path(name), problem: problem)
                    throw ToolError(error.message + " Nothing was computed.", details: error.details)
                }
            }
            return tallies
        }
    }

    // MARK: Evaluation

    /// The exact value of the expression, from the leaves up. A failure names the operation and where it is.
    private static func evaluate(
        _ expression: CalcExpression, text: String, tallies: [String: Tally], used: [UsedTally]
    ) throws(ToolError) -> Fraction {
        try expression.fold { (node: CalcExpression, operands: [Fraction]) throws(ToolError) -> Fraction in
            do throws(FractionError) {
                return try combine(node, operands, tallies: tallies)
            } catch {
                throw evaluationError(error, at: node, operands: operands, text: text, used: used)
            }
        }
    }

    /// One node, given the values of its children. The parser has checked the number of a call's arguments.
    private static func combine(
        _ node: CalcExpression, _ operands: [Fraction], tallies: [String: Tally]
    ) throws(FractionError) -> Fraction {
        switch node.node {
        case .number(let value, _):
            return try Fraction(value)
        case .tally(let name, let field):
            guard let tally = tallies[name] else { preconditionFailure("calc: the tally \(name) was not read") }
            return field == .count ? Fraction(tally.count) : try Fraction(tally.value)
        case .negation:
            return -operands[0]
        case .binary(let op, _, _):
            let (lhs, rhs) = (operands[0], operands[1])
            switch op {
            case .add: return try lhs + rhs
            case .subtract: return try lhs - rhs
            case .multiply: return try lhs * rhs
            case .divide: return try lhs / rhs
            case .power: return try lhs.raised(to: rhs)
            }
        case .call(let function, _):
            switch function {
            case .abs: return operands[0].magnitude
            case .round: return try operands[0].rounded(toPlaces: operands[1])
            case .min: return operands.dropFirst().reduce(operands[0], Swift.min)
            case .max: return operands.dropFirst().reduce(operands[0], Swift.max)
            }
        }
    }

    // MARK: Errors

    /// An error while working out `node`: what happened, where (as the parser says it), and what to do instead.
    private static func evaluationError(
        _ error: FractionError, at node: CalcExpression, operands: [Fraction], text: String, used: [UsedTally]
    ) -> ToolError {
        let at = CalcParser.at(node.position, of: text)
        let message: String
        switch (error, node.node) {
        case (.divisionByZero, .binary(.power, let base, _)):
            message = "0 raised to a negative power \(at): the base\(named(base)) is 0, and 0 ^ -n is 1 / 0^n, a "
                + "division by zero, which has no result. Check the base, or use an exponent of 0 or more."
        case (.divisionByZero, .binary(_, _, let divisor)):
            message = "Division by zero \(at): the divisor\(named(divisor)) is 0, and dividing by 0 has no result. "
                + "Check the divisor; if it can be 0 (a tally nothing was added to yet, say), handle that case without "
                + "the division."
        case (.tooManyDigits, _):
            message = "\(operation(node)) \(at) gives a value with more than \(Fraction.digitLimit) digits in its "
                + "numerator or denominator: calc keeps every value as an exact fraction and stops at "
                + "\(Fraction.digitLimit) digits. Use a smaller exponent, or round an inner part with round(x, places) "
                + "first."
        case (.exponentNotWhole, .binary(.power, _, let exponent)):
            message = "The power \(at) has the exponent \(value(exponent, operands[1])), which is not a whole number: "
                + "calc has no roots and no fractional powers. ^ takes whole-number exponents from "
                + "\(Fraction.exponentRange.lowerBound) to \(Fraction.exponentRange.upperBound)."
        case (.exponentOutOfRange, .binary(.power, _, let exponent)):
            message = "The power \(at) has the exponent \(value(exponent, operands[1])), outside "
                + "\(Fraction.exponentRange.lowerBound) to \(Fraction.exponentRange.upperBound), the exponents ^ "
                + "takes. Use an exponent in that range."
        case (.placesNotWhole, .call(_, let arguments)):
            message = "round \(at) has the places \(value(arguments[1], operands[1])), which is not a whole number. "
                + "Write a whole number from \(Fraction.placesRange.lowerBound) to \(Fraction.placesRange.upperBound): "
                + "round(x, 2) for two decimal places, round(x, 0) for a whole number, round(x, -3) for thousands."
        case (.placesOutOfRange, .call(_, let arguments)):
            message = "round \(at) has the places \(value(arguments[1], operands[1])), outside "
                + "\(Fraction.placesRange.lowerBound) to \(Fraction.placesRange.upperBound), the places round takes: "
                + "round(x, 2) for two decimal places, round(x, 0) for a whole number, round(x, -3) for thousands."
        default:
            // Not reached: each error comes from the operation it is paired with above, and overflow and underflow
            // only from the result.
            message = "\(operation(node)) \(at) cannot be worked out (\(error)). Nothing was computed."
        }
        return ToolError(message, details: details(used))
    }

    /// The result does not fit a `Decimal`: the range errors of ADR-0005, with what to do.
    private static func resultError(_ error: FractionError, used: [UsedTally]) -> ToolError {
        let message = switch error {
        case .overflow:
            DecimalMath.overflow.message
                + " Divide the expression by a power of ten (1e100, say) to see its leading digits."
        case .underflow:
            DecimalMath.underflow.message
                + " Multiply the expression by a power of ten (1e100, say) to see its leading digits."
        default:
            "The result cannot be worked out (\(error)). Nothing was computed."
        }
        return ToolError(message, details: details(used))
    }

    /// The tallies an expression used, for errors that come after reading them: a division by zero is often a
    /// tally at 0.
    private static func details(_ used: [UsedTally]) -> JSONObject? {
        used.isEmpty ? nil : ["tallies": .array(used.map { .object($0.entry) })]
    }

    /// What `node` does, to start a message.
    private static func operation(_ node: CalcExpression) -> String {
        switch node.node {
        case .binary(.add, _, _): "The addition"
        case .binary(.subtract, _, _): "The subtraction"
        case .binary(.multiply, _, _): "The multiplication"
        case .binary(.divide, _, _): "The division"
        case .binary(.power, _, _): "The power"
        case .call(let function, _): function.rawValue
        case .negation: "The minus sign"
        case .number: "The number"
        case .tally: "The tally"
        }
    }

    /// An operand as written (in `read`'s notation, in parentheses when it is an operation), after `separator`;
    /// nothing when it is too long to repeat.
    private static func shown(_ operand: CalcExpression, _ separator: String) -> String {
        let text = operand.rendered
        guard text.count <= 40 else { return "" }
        if case .binary = operand.node { return separator + "(" + text + ")" }
        return separator + text
    }

    /// An operand that came to 0, after a space: nothing for a plain number, which is 0 as written.
    private static func named(_ operand: CalcExpression) -> String {
        if case .number = operand.node { return "" }
        return shown(operand, " ")
    }

    /// An operand as written and, unless that is its value already, the value it came to: `0.5`, `{rate} = 5/2`.
    private static func value(_ operand: CalcExpression, _ value: Fraction) -> String {
        let written = shown(operand, "")
        if case .number = operand.node, !written.isEmpty { return written }
        let exact = value.description
        if written == exact { return written }
        let valueText = exact.count <= 40 ? exact : "a number with \(value.numerator.description.count) digits"
        return written.isEmpty ? valueText : "\(written) = \(valueText)"
    }
}
