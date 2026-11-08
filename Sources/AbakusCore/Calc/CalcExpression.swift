import Foundation

/// An expression as calc understood it (ADR-0007): the syntax tree `CalcParser` builds and the tool evaluates.
///
/// Every node carries the position of the token it starts at, or of its operator for a binary operation, counted
/// in characters from 1 into the expression, so that an evaluation error (division by zero, a fractional exponent,
/// an unknown tally) can say where it happened. Parentheses leave no node of their own: `(1 + 2)` is the addition.
struct CalcExpression: Sendable, Equatable {
    /// The character index, from 1, of the token this node starts at, or of the operator of a binary operation.
    var position: Int
    var node: Node

    indirect enum Node: Sendable, Equatable {
        /// A literal: its value, never negative (a leading minus is a negation), and the literal as written
        /// (`410k`, `.5`, `2.5e3`).
        case number(Decimal, literal: String)
        /// `{name}` (the tally's value) or `{name:count}` (its count). The name follows the tally name rules.
        case tally(name: String, of: CalcTallyField)
        /// A leading `-`. A leading `+` leaves no node.
        case negation(CalcExpression)
        case binary(CalcOperator, CalcExpression, CalcExpression)
        /// A function call with its arguments; the parser has checked their number.
        case call(CalcFunction, [CalcExpression])
    }
}

/// What a tally reference stands for. The raw values are the response's `of`.
enum CalcTallyField: String, Sendable, Equatable {
    case value
    case count
}

/// The binary operators, as `read` writes them.
enum CalcOperator: String, Sendable, Equatable, CaseIterable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "^"
}

/// The functions calc knows. Names are lowercase.
enum CalcFunction: String, Sendable, Equatable, CaseIterable {
    case abs
    case round
    case min
    case max

    /// How many arguments the function takes: `abs` one, `round` two (value and places), `min` and `max` one or more.
    var arity: ClosedRange<Int> {
        switch self {
        case .abs: 1...1
        case .round: 2...2
        case .min, .max: 1...Int.max
        }
    }

    /// The call as messages show it.
    var usage: String {
        switch self {
        case .abs: "abs(x)"
        case .round: "round(x, places)"
        case .min: "min(a, b, …)"
        case .max: "max(a, b, …)"
        }
    }
}

extension CalcExpression {
    /// The operands of this node, left to right: none for a number or a tally reference.
    var children: [CalcExpression] {
        switch node {
        case .number, .tally: []
        case .negation(let operand): [operand]
        case .binary(_, let left, let right): [left, right]
        case .call(_, let arguments): arguments
        }
    }

    /// Works the tree out from the leaves up, without recursion: `combine` gets each node together with the results
    /// for its `children`, in order, and the result for the root comes back.
    ///
    /// Without recursion because nesting is limited to 64 levels, but a chain of one operator is not: the 1000
    /// characters of `1+1+…+1` make a tree about 500 levels deep on the left, and a recursive walk over it can
    /// exhaust a thread's stack (512 KB off the main thread; a recursive `rendered` did so in a debug build).
    func fold<Result, Failure: Error>(
        _ combine: (CalcExpression, [Result]) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        // A node is visited once: it goes back on the stack to be combined after its children, which go on top in
        // reverse, so they are worked out first and in order.
        var steps: [FoldStep] = [.visit(self)]
        var results: [Result] = []
        while let step = steps.popLast() {
            switch step {
            case .visit(let expression):
                let children = expression.children
                steps.append(.combine(expression, childCount: children.count))
                steps.append(contentsOf: children.reversed().map(FoldStep.visit))
            case .combine(let expression, let childCount):
                let operands = Array(results.suffix(childCount))
                results.removeLast(childCount)
                results.append(try combine(expression, operands))
            }
        }
        return results[0]
    }

    /// The expression as it was understood, the response's `read`: numbers in plain notation (`410k` as 410000),
    /// operators in ASCII with a space on either side, parentheses around every binary operation except the
    /// outermost one (and the outermost one of each function argument), `-x` or `-(…)` for a negation. Parsing
    /// it again gives the same tree, positions and literals aside, as long as it stays within the parser's limits:
    /// the parentheses of a long chain of one operator can nest deeper than 64 and make it longer than 1000.
    var rendered: String {
        fold { (expression, parts: [String]) -> String in
            switch expression.node {
            case .number(let value, _):
                // Plain notation, as JSONValue.decimal writes numbers.
                return value.description
            case .tally(let name, let field):
                return field == .count ? "{\(name):count}" : "{\(name)}"
            case .negation(let operand):
                return "-" + Self.asOperand(parts[0], operand)
            case .binary(let op, let left, let right):
                var lhs = Self.asOperand(parts[0], left)
                // `-2 ^ 2` reads as -(2 ^ 2), so a negated base of a power keeps its parentheses.
                if op == .power, case .negation = left.node {
                    lhs = "(" + lhs + ")"
                }
                return lhs + " " + op.rawValue + " " + Self.asOperand(parts[1], right)
            case .call(let function, _):
                return function.rawValue + "(" + parts.joined(separator: ", ") + ")"
            }
        }
    }

    /// One step of `fold`: visit a node (push its children), or combine it with the results of its children.
    private enum FoldStep {
        case visit(CalcExpression)
        case combine(CalcExpression, childCount: Int)
    }

    /// An operand's text, in parentheses when the operand is a binary operation.
    private static func asOperand(_ text: String, _ operand: CalcExpression) -> String {
        if case .binary = operand.node { return "(" + text + ")" }
        return text
    }
}
