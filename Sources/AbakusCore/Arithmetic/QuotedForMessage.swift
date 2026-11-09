extension String {
    /// At most this many Unicode scalars of an input go into a message or an error's details (ADR-0008). Tally names
    /// have at most 64 ASCII characters, so a valid name is never cut.
    static let messageLimit = 100

    /// The string as messages show an input: unchanged up to `messageLimit` Unicode scalars, otherwise its first 50
    /// and last 49 around a `…`, so that an error does not grow with its input (ADR-0008). Scalars, not characters:
    /// one character can hold any number of combining marks.
    var cutForMessage: String {
        let scalars = unicodeScalars
        guard scalars.count > Self.messageLimit else { return self }
        var cut = String.UnicodeScalarView(scalars.prefix(50))
        cut.append("…")
        cut.append(contentsOf: scalars.suffix(49))
        return String(cut)
    }

    /// The string in double quotes, with `\` and `"` escaped and cut as `cutForMessage` does: how error messages
    /// show an input, so that an empty or space-only input stays visible (`""`, `"  "`) and a long one stays short.
    var quotedForMessage: String {
        "\"" + cutForMessage.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
