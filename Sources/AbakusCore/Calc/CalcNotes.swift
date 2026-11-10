import Foundation

/// The notes calc adds to a result where conventions differ on how an expression reads (ADR-0007, amendment
/// 2026-11-10). Over MCP they take the place of `read`, which is a detail (ADR-0008):
///
/// - a leading minus before a power: `-2^2` is -(2^2) here and in mathematics, (-2)^2 in Excel and bc;
/// - a chain of powers: `2^3^2` is 2^(3^2) here and in mathematics, (2^3)^2 in Excel.
///
/// Parentheses the agent wrote settle the reading, so `-(2^2)`, `(-2)^2`, `2^(3^2)` and `(2^3)^2` get no note.
/// Neither does a mixed chain of `*` and `/` or of `+` and `-`: every convention reads those from the left, and a
/// note on every `x / y * 100` would teach agents to skip notes.
///
/// At most one note per kind, of a fixed size however many occurrences there are: how many, the first one in the
/// text with its position (cut in the middle when long), how it was read and how to write the other reading.
enum CalcNotes {
    /// An occurrence up to this many characters is quoted whole, with both readings written out; a longer one is
    /// cut in the middle, as calc's errors cut an operand, and the readings are described instead.
    static let writtenOutLimit = 40

    /// The notes for `expression`, parsed from `text`: none, one or two strings.
    static func notes(for expression: CalcExpression, in text: String) -> [String] {
        let source = Array(text)
        // The negations whose operand is a power without parentheses, and the top power of each chain of powers.
        var minusBeforePower: [CalcExpression] = []
        var chains: [CalcExpression] = []
        // For each node, the index in `chains` of the chain it is the top of so far: a power whose exponent is a
        // power without parentheses. Its parent may extend the chain to the left (2^3^2^2 is one chain).
        _ = expression.fold { (node: CalcExpression, children: [Int?]) -> Int? in
            switch node.node {
            case .negation(let operand):
                if case .binary(.power, _, _) = operand.node, !operand.isParenthesized {
                    minusBeforePower.append(node)
                }
                return nil
            case .binary(.power, _, let exponent):
                guard case .binary(.power, _, _) = exponent.node, !exponent.isParenthesized else { return nil }
                if let index = children[1] {
                    chains[index] = node
                    return index
                }
                chains.append(node)
                return chains.count - 1
            default:
                return nil
            }
        }

        var notes: [String] = []
        if let first = minusBeforePower.min(by: { $0.span.lowerBound < $1.span.lowerBound }) {
            notes.append(minusNote(first, count: minusBeforePower.count, source: source))
        }
        if let first = chains.min(by: { $0.span.lowerBound < $1.span.lowerBound }) {
            notes.append(chainNote(first, count: chains.count, source: source))
        }
        return notes
    }

    /// `-2^2`: read as -(2^2); the other reading is (-2)^2.
    private static func minusNote(_ negation: CalcExpression, count: Int, source: [Character]) -> String {
        guard case .negation(let power) = negation.node, case .binary(.power, let base, _) = power.node else {
            return ""  // Not reached: only such negations are collected.
        }
        let text = String(source[negation.span])
        var reading: String?
        var other: String?
        if text.count <= writtenOutLimit {
            // Parentheses put into what the agent wrote, so its spelling and spacing stay: −2 ** 2 → (−2) ** 2.
            reading = inserting([(power.span.lowerBound, "("), (power.span.upperBound, ")")], into: source, negation.span)
            other = inserting([(negation.span.lowerBound, "("), (base.outerSpan.upperBound, ")")], into: source, negation.span)
        }
        return note(
            count: count, several: "\(count) powers with a leading minus", occurrence: text,
            position: negation.span.lowerBound + 1, reading: reading,
            rule: "the power comes first, then the minus, as in mathematics",
            otherConvention: "Excel and bc apply the minus first",
            advice: "put the minus and the base in parentheses", example: other ?? "(-2)^2", rewrite: other
        )
    }

    /// `2^3^2`: read as 2^(3^2); the other reading is (2^3)^2. A longer chain the same way: 2^3^2^2 is 2^(3^(2^2)),
    /// or ((2^3)^2)^2.
    private static func chainNote(_ top: CalcExpression, count: Int, source: [Character]) -> String {
        // The operands along the chain, left to right: the base of each power, then the last exponent.
        var operands: [CalcExpression] = []
        var link = top
        while case .binary(.power, let base, let exponent) = link.node {
            operands.append(base)
            if case .binary(.power, _, _) = exponent.node, !exponent.isParenthesized {
                link = exponent
            } else {
                operands.append(exponent)
                break
            }
        }
        let text = String(source[top.span])
        var reading: String?
        var other: String?
        // Beyond four operands, the parentheses written out would be longer than the chain and hard to read.
        if text.count <= writtenOutLimit && operands.count <= 4 {
            let inner = operands.dropFirst().dropLast()
            reading = inserting(
                inner.map { ($0.outerSpan.lowerBound, "(") } + inner.map { _ in (top.span.upperBound, ")") },
                into: source, top.span
            )
            other = inserting(
                inner.map { _ in (top.span.lowerBound, "(") } + inner.map { ($0.outerSpan.upperBound, ")") },
                into: source, top.span
            )
        }
        return note(
            count: count, several: "\(count) chains of powers", occurrence: text,
            position: top.span.lowerBound + 1, reading: reading,
            rule: "powers group from the right, as in mathematics",
            otherConvention: "Excel groups them from the left",
            advice: "write the parentheses yourself", example: other ?? "(2^3)^2", rewrite: other
        )
    }

    /// One note: how many (when more than one), the first occurrence with its position, how it was read and why,
    /// and how to write the other reading.
    private static func note(
        count: Int, several: String, occurrence: String, position: Int, reading: String?, rule: String,
        otherConvention: String, advice: String, example: String, rewrite: String?
    ) -> String {
        let quoted = occurrence.count <= writtenOutLimit
            ? occurrence.quotedForMessage
            : (String(occurrence.prefix(20)) + "…" + String(occurrence.suffix(19))).quotedForMessage
        let intro = count == 1 ? "" : "The expression has \(several). "
        let read = switch (reading, count) {
        case (let reading?, 1): "\(quoted) at character \(position) was read as \(reading): \(rule)."
        case (let reading?, _): "The first, \(quoted) at character \(position), was read as \(reading): \(rule)."
        case (nil, 1): "In \(quoted) at character \(position), \(rule)."
        case (nil, _): "In the first, \(quoted) at character \(position), \(rule)."
        }
        let then = if count == 1, let rewrite {
            "for that reading, write \(rewrite)."
        } else {
            "for that reading, \(advice), as in \(example)."
        }
        return intro + read + " \(otherConvention); " + then
    }

    /// The characters of `span` with `insertions` put in before the character at each index (an index at the end
    /// of `span` appends). Several insertions at one index keep their order.
    private static func inserting(_ insertions: [(Int, String)], into source: [Character], _ span: Range<Int>) -> String {
        var text = ""
        for index in span.lowerBound...span.upperBound {
            for (at, insertion) in insertions where at == index {
                text += insertion
            }
            if index < span.upperBound { text.append(source[index]) }
        }
        return text
    }
}
