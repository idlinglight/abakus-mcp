import Foundation

/// Which character separates the integer part from the fraction in number strings (ADR-0005).
public enum DecimalMark: String, Sendable, CaseIterable {
    case point = "."
    case comma = ","
}

/// Reads number arguments by the rules of ADR-0005: a JSON number (from its literal text) or a string.
///
/// Placeholder: reads plain literals only (`-12`, `0.5`, `2.5e3`). The full string rules (grouping, suffixes,
/// decimal comma) replace this implementation; the signature stays.
public enum NumberReader {
    public static func read(_ value: JSONValue, decimal: DecimalMark = .point) throws(ToolError) -> Decimal {
        switch value {
        case .number(let literal):
            return try plain(literal, original: literal)
        case .string(let text):
            return try plain(text.trimmingCharacters(in: .whitespaces), original: text)
        default:
            throw ToolError("Expected a number or a number string.")
        }
    }

    private static func plain(_ text: String, original: String) throws(ToolError) -> Decimal {
        let pattern = /-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/
        guard text.wholeMatch(of: pattern) != nil, let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw ToolError("Cannot read \"\(original)\" as a number.")
        }
        return decimal
    }
}
