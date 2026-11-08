import Foundation

/// Which character separates the integer part from the fraction in number strings (ADR-0005).
public enum DecimalMark: String, Sendable, CaseIterable {
    case point = "."
    case comma = ","

    /// The other mark, which may group thousands.
    public var groupingMark: String { self == .point ? "," : "." }

    /// Reads a tool's optional `decimal` argument: absent or null is `.point`.
    public static func argument(_ value: JSONValue?, name: String = "decimal") throws(ToolError) -> DecimalMark {
        guard let value, !value.isNull else { return .point }
        if let text = value.stringValue, let mark = DecimalMark(rawValue: text) { return mark }
        throw ToolError(
            "\(name) must be \".\" or \",\": the decimal mark used in number strings. Pass \",\" for numbers written "
                + "like 1.234,5; leave it out for 1,234.5."
        )
    }

    /// JSON Schema for a `decimal` argument, to put into a tool's `inputSchema`.
    public static let schema: JSONValue = [
        "type": "string",
        "enum": [".", ","],
        "default": ".",
        "description": .string(
            "The decimal mark in number strings: \".\" (default, 1,234.5) or \",\" (1.234,5). The other mark may "
                + "only group thousands. JSON numbers are not affected."
        ),
    ]
}

/// Reads number arguments by the rules of ADR-0005: a JSON number, from its literal text, or a string.
///
/// Strings: `.` is the decimal mark, or `,` with `decimal: .comma`; the other mark may group thousands, in groups of
/// three only. An optional sign (`+`, `-` or `−`), an optional exponent (`2.5e3`) or an optional suffix `k`/`K`,
/// `M`, `G`, `T`. Surrounding whitespace is ignored; anything else is an error that names the input. A value that
/// a `Decimal` cannot hold exactly (more than 38 significant digits, 10^165 or more, digits below 10^-128) is an
/// error too, never silently rounded.
public enum NumberReader {
    /// The rules in two sentences, for the description of `sum`, whose input is numbers.
    public static let rulesSummary = """
        Numbers can be JSON numbers or strings. In strings the decimal mark is "." (or "," when decimal is ","), \
        and the other mark may only group thousands in threes (1,234,567.5); a sign, an exponent (2.5e3) or one \
        suffix k/K, M, G, T (thousand, million, billion, trillion: 410k, 1.5M) are allowed, a lowercase m is \
        refused, and anything else (units, currency signs, %, spaces inside, more than 38 significant digits) is \
        an error.
        """

    /// The rules in one sentence, for tools that take a number or two besides other things (the tallies). The
    /// full rules are in `sum`'s description once. Every error says why a number cannot be used; those about a
    /// string also say what is accepted (JSON literals and wrong types have nothing to gain from the string rules).
    public static let rulesInBrief = """
        Numbers may be JSON numbers or strings like "410k" or "1,234.5" (decimal: "," for 1.234,5); an unreadable \
        one is an error that says why; sum's description has the full rules.
        """

    public static func read(_ value: JSONValue, decimal: DecimalMark = .point) throws(ToolError) -> Decimal {
        switch value {
        case .number(let literal):
            return try readLiteral(literal)
        case .string(let text):
            return try readString(text, decimal: decimal)
        case .null, .bool, .array, .object:
            throw ToolError("Expected a number or a number string, got \(value.kindForMessage).")
        }
    }

    // MARK: Strings

    /// Every error about a string says why it cannot be read and what is accepted, the range errors included.
    private static func readString(_ original: String, decimal: DecimalMark) throws(ToolError) -> Decimal {
        do {
            return try build(try scan(original, decimal: decimal))
        } catch {
            throw ToolError(
                "Cannot read \(original.quotedForMessage) as a number: \(error.text) \(accepted(decimal))",
                details: ["input": .string(original)]
            )
        }
    }

    private static func accepted(_ decimal: DecimalMark) -> String {
        let example = decimal == .point ? "1,234,567.5" : "1.234.567,5"
        return "Accepted: digits with \"\(decimal.rawValue)\" as the decimal mark, \"\(decimal.groupingMark)\" only "
            + "between groups of three digits (\(example)), an optional sign, and an exponent (2.5e3) or a suffix "
            + "k, M, G or T (410k)."
    }

    /// A number taken apart, before the range checks. Internal for calc's parser, which reads the form of its
    /// literals itself (no grouping, errors about expressions) and leaves the value and the range to `build`.
    struct Parts {
        var negative: Bool
        /// Integer and fraction digits together, most significant first.
        var digits: [UInt8]
        var exponent: Int
    }

    enum Problem: Error {
        case format(String)
        case tooLarge
        case tooManyDigits(Int)
        case tooSmall

        var text: String {
            switch self {
            case .format(let problem): problem
            case .tooLarge:
                "it is too large for exact decimal arithmetic, which holds magnitudes below "
                    + "10^\(ExactDecimal.overflowExponent)."
            case .tooManyDigits(let count):
                "it has \(count) significant digits; exact decimal arithmetic holds \(ExactDecimal.precision), and "
                    + "abakus does not round input."
            case .tooSmall:
                "it has digits below 10^\(ExactDecimal.minimumExponent), the smallest step exact decimal arithmetic "
                    + "holds; abakus does not round input."
            }
        }
    }

    private static func scan(_ original: String, decimal: DecimalMark) throws(Problem) -> Parts {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw .format(original.isEmpty ? "the string is empty." : "the string holds only whitespace.")
        }
        let s = Array(text.unicodeScalars)
        let mark = Unicode.Scalar(decimal.rawValue)!
        let group = Unicode.Scalar(decimal.groupingMark)!
        let markName = "\"\(decimal.rawValue)\""
        let groupName = "\"\(decimal.groupingMark)\""
        let otherMode = decimal == .point ? "pass decimal: \",\"" : "leave out decimal or pass \".\""
        var i = 0

        var negative = false
        if isSign(s[i]) {
            negative = s[i] != "+"
            i += 1
        }

        var integer: [UInt8] = []
        var grouped = false
        var groupLength = 0
        while i < s.count {
            if let digit = digitValue(s[i]) {
                integer.append(digit)
                groupLength += 1
            } else if s[i] == group {
                if integer.isEmpty {
                    throw .format(
                        "\(groupName) groups thousands and cannot stand before the first digit. If \(groupName) is the "
                            + "decimal mark here, \(otherMode)."
                    )
                }
                if !grouped && integer.first == 0 {
                    throw .format(
                        "a number grouped with \(groupName) cannot start with 0. If \(groupName) is the decimal mark here, \(otherMode)."
                    )
                }
                if grouped ? groupLength != 3 : groupLength > 3 {
                    throw .format(
                        "\(groupName) groups thousands, so the groups between \(groupName) must have exactly three digits. "
                            + "If \(groupName) is the decimal mark here, \(otherMode)."
                    )
                }
                grouped = true
                groupLength = 0
            } else {
                break
            }
            i += 1
        }
        if grouped && groupLength != 3 {
            throw .format(
                "\(groupName) groups thousands, so it must be followed by exactly three digits. If \(groupName) is the "
                    + "decimal mark here, \(otherMode)."
            )
        }

        var fraction: [UInt8] = []
        if i < s.count && s[i] == mark {
            i += 1
            while i < s.count, let digit = digitValue(s[i]) {
                fraction.append(digit)
                i += 1
            }
            if fraction.isEmpty {
                throw .format("the decimal mark \(markName) must be followed by digits.")
            }
        }
        if integer.isEmpty && fraction.isEmpty {
            throw .format(i < s.count ? unexpected(s[i]) : "there are no digits.")
        }

        var exponent = 0
        var hasExponent = false
        if i < s.count && (s[i] == "e" || s[i] == "E") {
            hasExponent = true
            i += 1
            var exponentNegative = false
            if i < s.count && isSign(s[i]) {
                exponentNegative = s[i] != "+"
                i += 1
            }
            var exponentDigits = 0
            while i < s.count, let digit = digitValue(s[i]) {
                // Beyond a million the value is out of range anyway (unless it is zero); this keeps Int safe.
                exponent = min(exponent * 10 + Int(digit), 1_000_000)
                exponentDigits += 1
                i += 1
            }
            if exponentDigits == 0 {
                throw .format("the exponent after \"e\" needs digits, as in 2.5e3.")
            }
            if exponentNegative { exponent = -exponent }
        }

        if i < s.count, let power = suffixPower(s[i]) {
            if hasExponent {
                throw .format("a suffix (k, M, G, T) cannot be combined with an exponent; use one or the other.")
            }
            exponent += power
            i += 1
        } else if i < s.count && s[i] == "m" {
            throw .format("a lowercase \"m\" could mean milli or million; write \"M\" for million.")
        }

        if i < s.count {
            let c = s[i]
            if c.properties.isWhitespace {
                let next = s[i...].first { !$0.properties.isWhitespace }!
                if suffixPower(next) != nil || next == "m" {
                    throw .format(
                        "no space is allowed before a suffix (write 410k, not 410 k); a letter after a space reads like a unit."
                    )
                }
                if digitValue(next) != nil {
                    throw .format("spaces inside a number are not allowed; only \(groupName) may group thousands.")
                }
                throw .format(unexpected(next))
            }
            if c == mark {
                throw .format(
                    "there is more than one decimal mark \(markName). If \(markName) groups thousands here, "
                        + (decimal == .point ? "pass decimal: \",\"." : "leave out decimal or pass \".\".")
                )
            }
            if c == group {
                throw .format(
                    "\(groupName) groups thousands and cannot come after the decimal mark \(markName). If "
                        + "\(groupName) is the decimal mark here, \(otherMode)."
                )
            }
            if suffixPower(c) != nil {
                throw .format("only one suffix (k, M, G, T) is allowed.")
            }
            throw .format(unexpected(c))
        }

        return Parts(negative: negative, digits: integer + fraction, exponent: exponent - fraction.count)
    }

    // The three helpers below are internal so that calc's parser accepts the same signs, digits and suffixes.

    /// `+`, `-` or `−` (U+2212).
    static func isSign(_ c: Unicode.Scalar) -> Bool {
        c == "+" || c == "-" || c == "\u{2212}"
    }

    /// The value of an ASCII digit; other digits (`١`, `²`) are not digits here.
    static func digitValue(_ c: Unicode.Scalar) -> UInt8? {
        ("0"..."9").contains(c) ? UInt8(c.value - 48) : nil
    }

    /// The power of ten of a suffix: `k`/`K` 3, `M` 6, `G` 9, `T` 12.
    static func suffixPower(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "k", "K": 3
        case "M": 6
        case "G": 9
        case "T": 12
        default: nil
        }
    }

    private static func unexpected(_ c: Unicode.Scalar) -> String {
        "\(String(c).quotedForMessage) is not part of a number (units, currency signs and % are not accepted; pass the bare number)."
    }

    // MARK: JSON number literals

    /// The JSON grammar for numbers (RFC 8259, section 6): `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. By hand,
    /// because a Swift `Regex` match costs tens of microseconds, which adds up over long lists.
    static func isJSONNumber(_ literal: String) -> Bool {
        let s = Array(literal.utf8)
        var i = 0
        func skipDigits() -> Int {
            let start = i
            while i < s.count, s[i] >= UInt8(ascii: "0"), s[i] <= UInt8(ascii: "9") { i += 1 }
            return i - start
        }
        if i < s.count, s[i] == UInt8(ascii: "-") { i += 1 }
        guard i < s.count else { return false }
        if s[i] == UInt8(ascii: "0") {
            i += 1
        } else if skipDigits() == 0 {
            return false
        }
        if i < s.count, s[i] == UInt8(ascii: ".") {
            i += 1
            if skipDigits() == 0 { return false }
        }
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1
            if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
            if skipDigits() == 0 { return false }
        }
        return i == s.count
    }

    private static func readLiteral(_ literal: String) throws(ToolError) -> Decimal {
        guard isJSONNumber(literal) else {
            throw ToolError(
                "\(literal) is not a valid JSON number. Pass it as a string to have it read by the string rules.",
                details: ["input": .string(literal)]
            )
        }
        do {
            // A valid JSON literal reads the same under the string rules with "." as the decimal mark.
            return try build(try scan(literal, decimal: .point))
        } catch {
            throw ToolError("Cannot use the number \(literal): \(error.text)", details: ["input": .string(literal)])
        }
    }

    // MARK: Building the value

    /// The value of `parts`, or `.tooLarge`, `.tooManyDigits` or `.tooSmall` when a `Decimal` cannot hold it exactly.
    static func build(_ parts: Parts) throws(Problem) -> Decimal {
        var digits = Array(parts.digits.drop { $0 == 0 })
        if digits.isEmpty { return 0 }
        var exponent = parts.exponent
        while digits.last == 0 {
            digits.removeLast()
            exponent += 1
        }
        // The leading digit stands for 10^(count + exponent - 1).
        if digits.count + exponent - 1 >= ExactDecimal.overflowExponent { throw .tooLarge }
        if digits.count > ExactDecimal.precision { throw .tooManyDigits(digits.count) }
        if exponent < ExactDecimal.minimumExponent { throw .tooSmall }
        let value = ExactDecimal(negative: parts.negative, magnitude: BigUInt(digits: digits), exponent: exponent)
        guard let rounded = try? value.rounded(), rounded.exact, !rounded.underflow else {
            preconditionFailure("NumberReader let through a value Decimal cannot hold: \(parts)")
        }
        return rounded.value
    }
}
