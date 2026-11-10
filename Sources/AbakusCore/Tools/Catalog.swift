/// Every tool abakus offers, in the order `tools/list` shows them. Each area keeps its own list in its own
/// file, so areas can change without touching each other.
public enum Catalog {
    public static let tools: [any Tool] = TallyTools.all + ArithmeticTools.all + DateTools.all

    public static func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }

    /// Tools that had another name in an earlier version, by the old name, with the new name and the version that
    /// renamed them. An agent or a script with the old habit gets the new name in the unknown-tool error, from the
    /// MCP server and from `abakus call` alike.
    public static let renamed: [String: (name: String, since: String)] = [
        "tally_list": ("tallies_info", "0.5.0"),
    ]

    /// The sentence an unknown-tool error adds for an old name, or nil: "It was renamed to tallies_info in abakus
    /// 0.5.0."
    public static func renameNote(for name: String) -> String? {
        renamed[name].map { "It was renamed to \($0.name) in abakus \($0.since)." }
    }
}
