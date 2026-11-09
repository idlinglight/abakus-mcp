extension String {
    /// At most this many characters of an input go into a message or an error's details (ADR-0008). Tally names
    /// have at most 64, so a valid name is never cut.
    static let messageLimit = 100

    /// The string as messages show an input: unchanged up to `messageLimit` characters, otherwise its first 50 and
    /// last 49 characters around a `…`, so that an error does not grow with its input (ADR-0008).
    var cutForMessage: String {
        guard count > Self.messageLimit else { return self }
        return String(prefix(50)) + "…" + String(suffix(49))
    }

    /// The string in double quotes, with `\` and `"` escaped and cut as `cutForMessage` does: how error messages
    /// show an input, so that an empty or space-only input stays visible (`""`, `"  "`) and a long one stays short.
    var quotedForMessage: String {
        "\"" + cutForMessage.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
