/// Every tool abakus offers, in the order `tools/list` shows them. Each area keeps its own list in its own
/// file, so areas can change without touching each other.
public enum Catalog {
    public static let tools: [any Tool] = TallyTools.all + ArithmeticTools.all + DateTools.all

    public static func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }
}
