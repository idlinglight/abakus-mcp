extension String {
    /// At most this many Unicode scalars of an input go into a message or an error's details (ADR-0008). Tally names
    /// have at most 64 ASCII characters, so a valid name is never cut.
    static let messageLimit = 100

    /// The string as messages show an input: unchanged up to `limit` Unicode scalars, otherwise its first half and
    /// its last half around a `…`, `limit` scalars in all (50, `…`, 49 for the default of 100), so that a message does
    /// not grow with its input (ADR-0008). Scalars, not characters: one character can hold any number of combining
    /// marks. The one place that cuts an input in the middle: errors, calc's operands and calc's notes all use it.
    func cutForMessage(limit: Int = String.messageLimit) -> String {
        let scalars = unicodeScalars
        guard scalars.count > limit else { return self }
        let head = limit / 2
        var cut = String.UnicodeScalarView(scalars.prefix(head))
        cut.append("…")
        cut.append(contentsOf: scalars.suffix(Swift.max(limit - head - 1, 0)))
        return String(cut)
    }

    /// `cutForMessage()` with the default limit.
    var cutForMessage: String { cutForMessage() }

    /// The string in double quotes, with `\` and `"` escaped and cut as `cutForMessage(limit:)` does: how error
    /// messages show an input, so that an empty or space-only input stays visible (`""`, `"  "`) and a long one stays
    /// short.
    func quotedForMessage(limit: Int = String.messageLimit) -> String {
        "\"" + cutForMessage(limit: limit).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `quotedForMessage()` with the default limit.
    var quotedForMessage: String { quotedForMessage() }
}
