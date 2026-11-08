extension String {
    /// The string in double quotes, with `\` and `"` escaped: how error messages show an input, so that an empty
    /// or space-only input stays visible (`""`, `"  "`).
    var quotedForMessage: String {
        "\"" + replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
