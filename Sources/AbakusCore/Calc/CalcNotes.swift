import Foundation

/// The notes calc adds to a result where conventions differ on how an expression reads (ADR-0007, amendment
/// 2026-11-10). Over MCP they take the place of `read`, which is a detail (ADR-0008):
///
/// - a leading minus before a power: `-2^2` is -(2^2) here and in mathematics, (-2)^2 in Excel and bc;
/// - a chain of powers: `2^3^2` is 2^(3^2) here and in mathematics, (2^3)^2 in Excel. A chain may run through a minus
///   in an exponent (`2^-3^2`, which Excel reads as (2^-3)^2) and may start with one (`-2^3^2`, ((-2)^3)^2 in Excel).
///
/// Parentheses the agent wrote settle the reading, so `-(2^2)`, `(-2)^2`, `2^(3^2)` and `(2^3)^2` get no note.
/// Neither does a mixed chain of `*` and `/` or of `+` and `-`: every convention reads those from the left, and a
/// note on every `x / y * 100` would teach agents to skip notes.
///
/// At most one note per kind, of a fixed size however many occurrences there are: how many, the first one in the
/// text with its position (cut in the middle when long), how it was read and how to write the other reading. Each
/// rewrite gives exactly the reading the note names. The minus note names Excel only where putting the minus with
/// the base is all Excel does differently; where the minus is part of a chain, Excel also groups from the left, and
/// the chain note, whose rewrite does both, names Excel instead.
enum CalcNotes {
    /// An occurrence up to `CalcParser.quotedPartLimit` Unicode scalars is quoted whole and its readings are written
    /// out; a longer one is cut in the middle, as calc's errors cut an operand, and its readings are described instead.
    /// A reading puts at most 6 parentheses into the occurrence (a chain of four operands with a leading minus), so it
    /// stays within this many scalars; the limit is checked anyway, so that no note can grow with its input.
    static let readingLimit = CalcParser.quotedPartLimit + 6
    /// A longer chain is described: its parentheses written out would be longer than the chain and hard to read.
    static let chainOperandLimit = 4

    /// The notes for `expression`, parsed from `text`: none, one or two strings.
    static func notes(for expression: CalcExpression, in text: String) -> [String] {
        let source = Array(text)
        // The negations whose operand is a power without parentheses, and the top of each chain of powers: its first
        // power, or the minus before it.
        var minusBeforePower: [CalcExpression] = []
        var chains: [CalcExpression] = []
        // Where the minus signs that are part of a chain start.
        var chainedMinus: Set<Int> = []
        // For each node, the index in `chains` of the chain it is the top of so far. Its parent may extend the chain
        // to the left: 2^3^2^2 is one chain, and so are 2^-3^2^2 and -2^3^2.
        _ = expression.fold { (node: CalcExpression, children: [Int?]) -> Int? in
            switch node.node {
            case .negation(let operand):
                guard isPower(operand) else { return nil }
                minusBeforePower.append(node)
                guard let index = children[0] else { return nil }
                chains[index] = node
                chainedMinus.insert(node.span.lowerBound)
                return index
            case .binary(.power, _, let exponent):
                guard continuesChain(exponent) else { return nil }
                if case .negation = exponent.node { chainedMinus.insert(exponent.span.lowerBound) }
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
            let inChain = chainedMinus.contains(first.span.lowerBound)
            notes.append(minusNote(first, count: minusBeforePower.count, inChain: inChain, source: source))
        }
        if let first = chains.min(by: { $0.span.lowerBound < $1.span.lowerBound }) {
            notes.append(chainNote(first, count: chains.count, source: source))
        }
        return notes
    }

    /// A power without parentheses around it.
    private static func isPower(_ expression: CalcExpression) -> Bool {
        if case .binary(.power, _, _) = expression.node { return !expression.isParenthesized }
        return false
    }

    /// An exponent that continues a chain of powers: a power, or a minus before one, without parentheses.
    private static func continuesChain(_ exponent: CalcExpression) -> Bool {
        if isPower(exponent) { return true }
        if case .negation(let operand) = exponent.node { return !exponent.isParenthesized && isPower(operand) }
        return false
    }

    /// `-2^2`: read as -(2^2); the other reading is (-2)^2, Excel's and bc's. In a chain (`-2^3^2`, `2^-3^2`), the
    /// same rewrite gives bc's reading only: Excel also groups from the left, which the chain note covers.
    private static func minusNote(_ negation: CalcExpression, count: Int, inChain: Bool, source: [Character]) -> String {
        guard case .negation(let power) = negation.node, case .binary(.power, let base, _) = power.node else {
            return ""  // Not reached: only such negations are collected.
        }
        let occurrence = String(source[negation.span])
        // Parentheses put into what the agent wrote, so its spelling and spacing stay: −2 ** 2 → (−2) ** 2.
        let readings = writtenOut(occurrence) {
            (
                inserting([(power.span.lowerBound, "("), (power.span.upperBound, ")")], into: source, negation.span),
                inserting([(negation.span.lowerBound, "("), (base.outerSpan.upperBound, ")")], into: source, negation.span)
            )
        }
        return note(
            count: count, several: "\(count) powers with a leading minus", occurrence: occurrence,
            position: negation.span.lowerBound + 1, readings: readings,
            rule: "the power comes first, then the minus, as in mathematics",
            otherConvention: inChain ? "bc applies the minus first" : "Excel and bc apply the minus first",
            advice: "put the minus and the base in parentheses", example: "(-2)^2"
        )
    }

    /// `2^3^2`: read as 2^(3^2); Excel's reading is (2^3)^2. A longer chain the same way: 2^3^2^2 is 2^(3^(2^2)), or
    /// ((2^3)^2)^2. A minus in the chain applies to what follows it here, to the next operand alone in Excel:
    /// `2^-3^2` is 2^-(3^2), or (2^-3)^2; `-2^3^2` is -(2^(3^2)), or ((-2)^3)^2.
    private static func chainNote(_ top: CalcExpression, count: Int, source: [Character]) -> String {
        var leadingMinus: CalcExpression?
        var link = top
        if case .negation(let operand) = top.node {
            leadingMinus = top
            link = operand
        }
        // The operands along the chain, left to right: the base of each power, then the last exponent. A minus before
        // an inner operand stays outside it, between the operand and the ^ before it.
        var operands: [CalcExpression] = []
        var hasMinus = leadingMinus != nil
        while case .binary(.power, let base, let exponent) = link.node {
            operands.append(base)
            if isPower(exponent) {
                link = exponent
            } else if continuesChain(exponent), case .negation(let operand) = exponent.node {
                hasMinus = true
                link = operand
            } else {
                operands.append(exponent)
                break
            }
        }
        let occurrence = String(source[top.span])
        let inner = operands.dropFirst().dropLast()
        let readings = operands.count > chainOperandLimit ? nil : writtenOut(occurrence) {
            // As read: each inner operand opens a group that runs to the end; a leading minus applies to all of it.
            var asRead = inner.map { ($0.outerSpan.lowerBound, "(") } + inner.map { _ in (top.span.upperBound, ")") }
            // Excel: groups from the left, and a leading minus belongs to the first base. A minus before an inner
            // operand needs nothing: that operand ends its group, as in (2^-3)^2.
            var excel = inner.map { _ in (top.span.lowerBound, "(") } + inner.map { ($0.outerSpan.upperBound, ")") }
            if let leadingMinus {
                asRead = [(operands[0].outerSpan.lowerBound, "("), (top.span.upperBound, ")")] + asRead
                excel += [(leadingMinus.span.lowerBound, "("), (operands[0].outerSpan.upperBound, ")")]
            }
            return (inserting(asRead, into: source, top.span), inserting(excel, into: source, top.span))
        }
        return note(
            count: count, several: "\(count) chains of powers", occurrence: occurrence,
            position: top.span.lowerBound + 1, readings: readings,
            rule: hasMinus
                ? "powers group from the right, and a minus comes after the power, as in mathematics"
                : "powers group from the right, as in mathematics",
            otherConvention: hasMinus
                ? "Excel applies the minus first and groups powers from the left"
                : "Excel groups them from the left",
            advice: "write the parentheses yourself", example: "(2^3)^2"
        )
    }

    /// Both readings, as read and the other one, when the occurrence and both readings are short; otherwise nil, and
    /// the note describes them. The occurrence is measured first, so that a long one is never copied.
    private static func writtenOut(
        _ occurrence: String, _ readings: () -> (String, String)
    ) -> (asRead: String, other: String)? {
        guard occurrence.unicodeScalars.count <= CalcParser.quotedPartLimit else { return nil }
        let (asRead, other) = readings()
        guard asRead.unicodeScalars.count <= readingLimit, other.unicodeScalars.count <= readingLimit else { return nil }
        return (asRead, other)
    }

    /// One note: how many (when more than one), the first occurrence with its position, how it was read and why,
    /// and how to write the other reading. `example` stands in for the first occurrence's own rewrite when that is
    /// not written out.
    private static func note(
        count: Int, several: String, occurrence: String, position: Int, readings: (asRead: String, other: String)?,
        rule: String, otherConvention: String, advice: String, example: String
    ) -> String {
        let quoted = occurrence.quotedForMessage(limit: CalcParser.quotedPartLimit)
        let intro = count == 1 ? "" : "The expression has \(several). "
        let read = switch (readings?.asRead, count) {
        case (let asRead?, 1): "\(quoted) at character \(position) was read as \(asRead): \(rule)."
        case (let asRead?, _): "The first, \(quoted) at character \(position), was read as \(asRead): \(rule)."
        case (nil, 1): "In \(quoted) at character \(position), \(rule)."
        case (nil, _): "In the first, \(quoted) at character \(position), \(rule)."
        }
        let then = switch (readings?.other, count) {
        case (let other?, 1): "for that reading, write \(other)."
        case (let other?, _): "for that reading, \(advice), as in \(other)."
        case (nil, _): "for that reading, \(advice), as in \(example)."
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
