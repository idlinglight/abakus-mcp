import Foundation

/// `calc`: works out one expression with exact fractions, over numbers and tallies by name (ADR-0007).
///
/// The expression is parsed (`CalcParser`), the tallies it names are read under one lock, and the tree is worked
/// out from the leaves up with `CalcExpression.fold`, never recursively: a 1000-character chain of one operator is
/// a tree about 500 levels deep. Nothing is rounded until `Fraction.decimalResult()` rounds the result, once. Every
/// error says where in the expression it happened, and what to do instead.
public struct CalcTool: Tool {
    public init() {}

    public let name = "calc"

    /// `read` repeats the whole expression, so it grows with it: the command line prints it, an MCP result leaves it
    /// out and has notes for the readings where conventions differ instead (ADR-0008, ADR-0007 amendment 2026-11-10).
    public let detailKeys = ["read"]

    /// Over MCP and in errors, `tallies` lists at most this many references, then `tallies_total` (ADR-0008).
    static let shownTallies = 5

    public let description = """
        Work out one arithmetic expression exactly, such as a rate from two tallies or what is left of a budget. \
        Stateless: it reads tallies and never changes them.

        Argument: expression, the formula as a string.

        Numbers: 12, 0.5, .5, 2.5e3, or with one suffix: k or K (thousand), M (million), G (billion), T \
        (trillion); a lowercase m is refused. The decimal mark is "."; no thousands separators: write 1234567, not \
        1,234,567. Numbers may stand anywhere, inside parentheses and function calls too.

        Operators: + and -; * or × to multiply; / or ÷ to divide; ^ or ** for powers with a whole-number exponent \
        from -9999 to 9999 and any base (2^10, 1.045^10, 2^-1). Powers bind tighter than a leading minus and group \
        from the right: -2^2 is -(2^2) = -4, (-2)^2 is 4, 2^3^2 is 2^9. * and / come before + and -, each pair \
        from the left: a / b * c is (a / b) * c, so 1 / 2*{n} is (1 / 2) * {n}. Parentheses group. No implicit \
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
        JSON number, exact when it fits in 38 significant digits and has no digits below 10^-128; otherwise it is \
        rounded half away from zero to 15 significant digits (to whole units when the integer part is longer), \
        exact: false is added, and fraction \
        gives the exact value as a string ("1/3"), left out when its numerator or denominator has more than 100 \
        digits. Trailing zeros are dropped: round(12.5, 2) gives 12.5. A tally whose value was rounded before \
        (exact: false in its state) makes the result exact: false too.

        Response: {"result", "notes", "tallies"}. notes appears only for a reading on which conventions differ, a \
        leading minus before a power (-2^2) or a chain of powers (2^3^2), unless you wrote the parentheses \
        yourself; it says how it was read and how to write the other reading. tallies (left out when there are \
        none) lists each reference with the number taken from it ({t} and {t:count} are two), as {"name", "of": \
        "value" or "count", "value"}, plus "exact": false for a rounded one: at most 5, in the order they first \
        appear, then tallies_total, the number of all, when there are more than 5. exact: false appears only when \
        the result was rounded or uses a rounded tally, fraction only when the result itself was rounded.

        The abakus command line (abakus calc, or abakus call calc; the same program as this server) prints the \
        same JSON with every tally, plus read: the expression as calc understood it, with parentheses that show \
        the grouping.
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
        let (references, positions) = Self.references(in: expression)
        let used = references.isEmpty ? [] : try Self.read(references, positions: positions, text: text, in: context)
        let details = Self.details(used)
        var values: [Reference: Fraction] = [:]
        for item in used {
            values[item.reference] = try item.number()
        }

        let value = try Self.evaluate(expression, text: text, values: values, used: used)
        let rounded: Fraction.DecimalResult
        do throws(FractionError) {
            rounded = try value.decimalResult()
        } catch {
            throw Self.resultError(error, value: value, details: details)
        }

        var result: JSONObject = ["result": .decimal(rounded.value)]
        // A tally's rounded value makes the result inexact even when the result itself needed no rounding; the
        // fraction is only for a rounding done here, which it undoes.
        if !rounded.exact || used.contains(where: \.isInexact) { result["exact"] = false }
        if let fraction = rounded.fraction { result["fraction"] = .string(fraction) }
        let notes = CalcNotes.notes(for: expression, in: text)
        if !notes.isEmpty { result["notes"] = .array(notes.map(JSONValue.string)) }
        result["read"] = .string(expression.rendered)
        // Every reference: the command line prints them all, and `withoutDetails` shortens the list for MCP.
        if !used.isEmpty { result["tallies"] = .array(used.map { .object($0.entry) }) }
        return result
    }

    /// The result as an MCP client gets it: without `read`, and with at most `shownTallies` tallies, then
    /// `tallies_total` (ADR-0008).
    public func withoutDetails(_ result: JSONObject) -> JSONObject {
        var answer = JSONObject()
        for (key, value) in result.entries where !detailKeys.contains(key) {
            if key == "tallies", let entries = value.arrayValue {
                Self.addTallies(entries, to: &answer)
            } else {
                answer[key] = value
            }
        }
        return answer
    }

    /// `tallies` with at most `shownTallies` entries, in the order of first appearance, and `tallies_total`, the
    /// number of all, when there are more.
    private static func addTallies(_ entries: [JSONValue], to object: inout JSONObject) {
        object["tallies"] = .array(Array(entries.prefix(shownTallies)))
        if entries.count > shownTallies { object["tallies_total"] = .number(String(entries.count)) }
    }

    // MARK: Arguments

    private static func expressionArgument(_ value: JSONValue?) throws(ToolError) -> String {
        let example = #"{"expression": "{errors-k3f9} / {requests-p2x7} * 100"}"#
        guard let value, !value.isNull else {
            throw ToolError("Missing argument \"expression\": pass the formula as a string, e.g. \(example).")
        }
        guard let text = value.stringValue else {
            throw ToolError(
                "expression must be a string with the formula, not \(value.kindForMessage); e.g. \(example) or "
                    + #"{"expression": "1250 * 1.19"}."#
            )
        }
        return text
    }

    // MARK: Tallies

    /// A tally reference as the response lists it: a name and what is taken from the tally.
    struct Reference: Hashable {
        var name: String
        var of: CalcTallyField

        /// As `read` writes it: `{name}` or `{name:count}`.
        var written: String { of == .count ? "{\(name):count}" : "{\(name)}" }
    }

    /// One distinct reference with the tally it was read from.
    struct UsedTally {
        var reference: Reference
        var tally: Tally

        /// A rounded value went into the result. A count is always exact.
        var isInexact: Bool { reference.of == .value && !tally.exact }

        /// The number taken from the tally, exactly.
        func number() throws(ToolError) -> Fraction {
            switch reference.of {
            case .count:
                return Fraction(tally.count)
            case .value:
                do throws(FractionError) {
                    return try Fraction(tally.value)
                } catch {
                    // Not reached: tally files are read by NumberReader, which never gives NaN.
                    throw ToolError("The tally \"\(tally.name)\" holds a value that is not a number. Nothing was computed.")
                }
            }
        }

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

    /// Each distinct reference once, in the order of first appearance in the text (`fold` combines the leaves left
    /// to right), and where each name first appears.
    static func references(in expression: CalcExpression) -> (references: [Reference], positions: [String: Int]) {
        var references: [Reference] = []
        var seen: Set<Reference> = []
        var positions: [String: Int] = [:]
        expression.fold { (node: CalcExpression, _: [Void]) in
            guard case .tally(let name, let of) = node.node else { return }
            if positions[name] == nil { positions[name] = node.position }
            let reference = Reference(name: name, of: of)
            if seen.insert(reference).inserted { references.append(reference) }
        }
        return (references, positions)
    }

    /// What reading the tallies under the lock came to.
    private enum TallyRead {
        case found([String: Tally])
        /// The first name without a tally, with the tally tools' error for it.
        case unknown(name: String, ToolError)
    }

    /// The tallies the references name, all under one shared lock, so their values come from one moment. The first
    /// name without a tally, in the order of the text, is the tally tools' unknown-name error, after where it is.
    private static func read(
        _ references: [Reference], positions: [String: Int], text: String, in context: ToolContext
    ) throws(ToolError) -> [UsedTally] {
        var names: [String] = []
        for reference in references where !names.contains(reference.name) {
            names.append(reference.name)
        }
        let outcome: TallyRead
        do throws(ToolError) {
            outcome = try TallyStore(context).read { files throws(ToolError) -> TallyRead in
                var tallies: [String: Tally] = [:]
                for name in names {
                    switch try files.inspect(name) {
                    case .tally(let tally):
                        tallies[name] = tally
                    case .missing:
                        return .unknown(name: name, try files.unknown(name, use: .read))
                    case .unreadable(let problem):
                        throw TallyErrors.unreadable(name, path: files.path(name), problem: problem)
                    }
                }
                return .found(tallies)
            }
        } catch {
            // Whatever failed here (a damaged file, a folder that cannot be read or locked), no tally was used.
            throw ToolError(error.message + " Nothing was computed.", details: error.details)
        }
        switch outcome {
        case .unknown(let name, let error):
            // The tally tools' text and details unchanged, after where the reference is, as calc's other errors say it.
            let written = references.first { $0.name == name }?.written ?? "{\(name)}"
            let at = positions[name].map { CalcParser.at($0, of: text) } ?? "in \(text.quotedForMessage)"
            throw ToolError(
                "\(written) \(at): " + error.message.prefix(1).lowercased() + error.message.dropFirst(),
                details: error.details
            )
        case .found(let tallies):
            return references.compactMap { reference in
                tallies[reference.name].map { UsedTally(reference: reference, tally: $0) }
            }
        }
    }

    // MARK: Evaluation

    /// The exact value of the expression, from the leaves up, with each reference's number from `values`. A failure
    /// names the operation and where it is.
    private static func evaluate(
        _ expression: CalcExpression, text: String, values: [Reference: Fraction], used: [UsedTally]
    ) throws(ToolError) -> Fraction {
        try expression.fold { (node: CalcExpression, operands: [Fraction]) throws(ToolError) -> Fraction in
            let result: Fraction?
            do throws(FractionError) {
                result = try combine(node, operands, values: values)
            } catch {
                throw evaluationError(error, at: node, operands: operands, text: text, used: used)
            }
            guard let result else {
                // Not reached: every reference is read before evaluating, and the parser checks the arguments.
                throw ToolError(
                    "calc has no value for \(node.rendered) \(CalcParser.at(node.position, of: text)), which is a bug "
                        + "in abakus. Nothing was computed.",
                    details: Self.details(used)
                )
            }
            return result
        }
    }

    /// One node, given the values of its children; nil when something it needs is missing.
    private static func combine(
        _ node: CalcExpression, _ operands: [Fraction], values: [Reference: Fraction]
    ) throws(FractionError) -> Fraction? {
        switch node.node {
        case .number(let value, _):
            return try Fraction(value)
        case .tally(let name, let field):
            return values[Reference(name: name, of: field)]
        case .negation:
            return operands.first.map { -$0 }
        case .binary(let op, _, _):
            guard operands.count == 2 else { return nil }
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
            case .abs:
                return operands.first?.magnitude
            case .round:
                guard operands.count == 2 else { return nil }
                return try operands[0].rounded(toPlaces: operands[1])
            case .min:
                return operands.min()
            case .max:
                return operands.max()
            }
        }
    }

    // MARK: Errors

    /// An error while working out `node`: what happened, where (as the parser says it), and what to do instead.
    /// `details.tallies` lists the tallies used; for a division by zero, those of the divisor first, so that the
    /// tallies the message names come with their values.
    private static func evaluationError(
        _ error: FractionError, at node: CalcExpression, operands: [Fraction], text: String, used: [UsedTally]
    ) -> ToolError {
        var details = Self.details(used)
        let at = CalcParser.at(node.position, of: text)
        let exponents = "\(Fraction.exponentRange.lowerBound) to \(Fraction.exponentRange.upperBound)"
        let places = "\(Fraction.placesRange.lowerBound) to \(Fraction.placesRange.upperBound)"
        let placesExamples = "round(x, 2) for two decimal places, round(x, 0) for a whole number, round(x, -3) for thousands."
        let message: String
        switch (error, node.node) {
        case (.divisionByZero, .binary(.power, let base, _)):
            details = Self.details(used, first: base)
            message = "0 raised to a negative power \(at): the base\(named(base)) is 0, and 0 ^ -n is 1 / 0^n, a "
                + "division by zero. " + whileZero(base, "base", details: details)
        case (.divisionByZero, .binary(_, _, let divisor)):
            details = Self.details(used, first: divisor)
            message = "Division by zero \(at): the divisor\(named(divisor)) is 0. "
                + whileZero(divisor, "divisor", details: details)
        case (.tooManyDigits, _):
            message = "\(operation(node)) \(at) gives a value with more than \(Fraction.digitLimit) digits in its "
                + "numerator or denominator: calc keeps every value as an exact fraction and stops at "
                + "\(Fraction.digitLimit) digits. " + fewerDigits(node)
        case (.exponentNotWhole, .binary(.power, _, let exponent)) where operands.count == 2:
            message = "The power \(at) has the exponent \(value(exponent, operands[1])), which is not a whole number: "
                + "calc has no roots and no fractional powers. ^ takes whole-number exponents from \(exponents)."
        case (.exponentOutOfRange, .binary(.power, _, let exponent)) where operands.count == 2:
            message = "The power \(at) has the exponent \(value(exponent, operands[1])), outside \(exponents), the "
                + "exponents ^ takes. Use an exponent in that range."
        case (.placesNotWhole, .call(_, let arguments)) where operands.count == 2 && arguments.count == 2:
            message = "round \(at) has the places \(value(arguments[1], operands[1])), which is not a whole number. "
                + "Write a whole number from \(places): \(placesExamples)"
        case (.placesOutOfRange, .call(_, let arguments)) where operands.count == 2 && arguments.count == 2:
            message = "round \(at) has the places \(value(arguments[1], operands[1])), outside \(places), the places "
                + "round takes: \(placesExamples)"
        default:
            // Not reached: each error comes from the operation it is paired with above, and overflow and underflow
            // only from the result.
            message = "\(operation(node)) \(at) cannot be worked out (\(error)). Nothing was computed."
        }
        return ToolError(message, details: details)
    }

    /// What to do about a divisor (or the base of a negative power) that is 0, by the tallies it uses.
    private static func whileZero(_ operand: CalcExpression, _ role: String, details: JSONObject?) -> String {
        let names = tallyNames(in: operand).map(\.quotedForMessage)
        let start = "While the \(role) is 0, the result has no value: report that, or "
        switch names.count {
        case 0: return start + "change the \(role)."
        case 1: return start + "calculate again once something has been added to the tally \(names[0])."
        default:
            // At most as many names as details.tallies lists, so that the message stays bounded too (ADR-0008).
            let listed = names.count > shownTallies
                ? names.prefix(shownTallies).joined(separator: ", ") + " and \(names.count - shownTallies) more"
                : names.listedInProse
            let again = start + "calculate again once the tallies \(listed) have changed"
            return again + (shows(operand, in: details) ? " (details.tallies has their values)." : ".")
        }
    }

    /// Whether `details.tallies` lists every reference in `operand`: with more than `shownTallies` references in the
    /// expression, it may not.
    private static func shows(_ operand: CalcExpression, in details: JSONObject?) -> Bool {
        let shown = Set((details?["tallies"]?.arrayValue ?? []).compactMap { entry -> Reference? in
            guard let object = entry.objectValue, let name = object["name"]?.stringValue,
                let of = object["of"]?.stringValue.flatMap(CalcTallyField.init(rawValue:))
            else { return nil }
            return Reference(name: name, of: of)
        })
        return references(in: operand).references.allSatisfy(shown.contains)
    }

    /// How to stay within the digit limit, by the operation that went past it.
    private static func fewerDigits(_ node: CalcExpression) -> String {
        switch node.node {
        case .binary(.power, _, _): "Use a smaller exponent, or a base with fewer digits."
        case .call(.round, _): "Round to fewer decimal places, or round a smaller value."
        default: "Use smaller operands, or round an inner part first with round(x, places)."
        }
    }

    /// The result does not fit a `Decimal`: how far out of range it is, and the power of ten that brings it back.
    private static func resultError(_ error: FractionError, value: Fraction, details: JSONObject?) -> ToolError {
        // 10^e <= |value| < 10^(e + 1)
        let e = decimalExponent(of: value.magnitude)
        let lies = value.negative ? "between -10^\(e + 1) and -10^\(e)" : "between 10^\(e) and 10^\(e + 1)"
        let message: String
        switch error {
        case .overflow:
            message = "The result is too large for exact decimal arithmetic, which ends below "
                + "10^\(ExactDecimal.overflowExponent): it lies \(lies). Values on the way may be larger, up to "
                + "\(Fraction.digitLimit) digits; only the result has to fit. "
                + scaled(by: e, verb: "divide", op: "/", negative: value.negative)
        case .underflow:
            message = "The result is not 0, but it lies \(lies) and rounds to 0 at 10^\(ExactDecimal.minimumExponent), "
                + "the finest step of exact decimal arithmetic. Values on the way may be smaller, with up to "
                + "\(Fraction.digitLimit) digits in a denominator; only the result has to fit. "
                + scaled(by: -e, verb: "multiply", op: "*", negative: value.negative)
        default:
            message = "The result cannot be worked out (\(error)). Nothing was computed."
        }
        return ToolError(message, details: details)
    }

    /// The advice to bring a result back into range with 10^k.
    private static func scaled(by k: Int, verb: String, op: String, negative: Bool) -> String {
        // 10^k has k + 1 digits.
        guard k < Fraction.digitLimit else {
            return "It cannot be brought into range: that takes a factor of 10^\(k), which has more than "
                + "\(Fraction.digitLimit) digits."
        }
        return "To see its leading digits, \(verb) the whole expression by 10^\(k), as in (…) \(op) 10^\(k); that "
            + "result lies between \(negative ? "-10 and -1" : "1 and 10")."
    }

    /// floor(log10(value)) for a value above 0, exactly.
    private static func decimalExponent(of value: Fraction) -> Int {
        let estimate = value.numerator.description.count - value.denominator.description.count
        // value lies between 10^(estimate - 1) and 10^(estimate + 1); which side of 10^estimate decides.
        let below = estimate >= 0
            ? value.numerator < value.denominator * BigUInt.powerOfTen(estimate)
            : value.numerator * BigUInt.powerOfTen(-estimate) < value.denominator
        return below ? estimate - 1 : estimate
    }

    /// The tallies an expression used, for errors that come after reading them: a division by zero is often a
    /// tally at 0. At most `shownTallies`, then `tallies_total`, as over MCP: errors are bounded too (ADR-0008). In
    /// the order of first appearance, except that the references in `operand` (a divisor that is 0) come first.
    private static func details(_ used: [UsedTally], first operand: CalcExpression? = nil) -> JSONObject? {
        guard !used.isEmpty else { return nil }
        var ordered = used
        if let operand {
            let first = references(in: operand).references
            ordered = first.compactMap { reference in used.first { $0.reference == reference } }
                + used.filter { !first.contains($0.reference) }
        }
        var details = JSONObject()
        addTallies(ordered.map { .object($0.entry) }, to: &details)
        return details
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

    /// The names of the tallies in an expression, each once, in order.
    private static func tallyNames(in expression: CalcExpression) -> [String] {
        var names: [String] = []
        expression.fold { (node: CalcExpression, _: [Void]) in
            if case .tally(let name, _) = node.node, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// An operand as the agent can find it in what it wrote: a number as written (`1e-50`), anything else as `read`
    /// writes it, in parentheses when it is an operation; a long one is cut in the middle, to `operandLimit` scalars.
    private static func written(_ operand: CalcExpression) -> String {
        let text = switch operand.node {
        case .number(_, let literal): literal
        case .binary: "(" + operand.rendered + ")"
        default: operand.rendered
        }
        return text.cutForMessage(limit: operandLimit)
    }

    /// How long an operand or a note's occurrence may be in a message before it is cut in the middle (ADR-0008).
    static let operandLimit = 40

    /// An operand that came to 0, after a space: nothing for a plain number, which is 0 as written.
    private static func named(_ operand: CalcExpression) -> String {
        if case .number = operand.node { return "" }
        return " " + written(operand)
    }

    /// An operand as written and, unless that shows its value already, the value it came to: `1e-50`,
    /// `(1 / 2) = 1/2`, `(10 ^ 1999) = a whole number of 2000 digits`.
    private static func value(_ operand: CalcExpression, _ value: Fraction) -> String {
        let written = written(operand)
        if case .number = operand.node { return written }
        let exact = value.description
        if written == exact { return written }
        return written + " = " + (exact.count <= 40 ? exact : size(of: value))
    }

    /// A value too long to write out, by its size: `a whole number of 2000 digits`, `a fraction of 1 digit over
    /// 51 digits`.
    private static func size(of value: Fraction) -> String {
        func digits(_ number: BigUInt) -> String {
            let count = number.description.count
            return count == 1 ? "1 digit" : "\(count) digits"
        }
        let sign = value.negative ? "negative " : ""
        if value.isWholeNumber { return "a \(sign)whole number of \(digits(value.numerator))" }
        return "a \(sign)fraction of \(digits(value.numerator)) over \(digits(value.denominator))"
    }
}
