import AbakusCore
import ArgumentParser

struct TallyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tally",
        abstract: "Named tallies: an exact value and a count, shared by all sessions of the user.",
        discussion: """
            Tallies live in the per-user temporary folder (or ABAKUS_STATE_DIR) and disappear after about three \
            days untouched. Names: lowercase letters, digits, '.', '_' and '-', at most 64 characters.
            """,
        subcommands: [Create.self, Add.self, Set.self, List.self, Drop.self]
    )

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a tally (tally_create).")

        @Argument(help: "The name. Refused if it exists, unless --unique is given.") var name: String
        @Flag(help: "Append a random suffix (items → items-k3f9) and print the name to use.") var unique = false
        @OptionGroup var thresholds: ThresholdOptions
        @OptionGroup var decimal: DecimalOption

        func run() throws {
            var arguments: JSONObject = ["name": .string(name)]
            if unique {
                arguments["unique"] = true
            }
            if let list = thresholds.list() {
                arguments["thresholds"] = list
            }
            decimal.apply(to: &arguments)
            try ToolRunner.run("tally_create", arguments)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an amount to a tally (tally_add).")

        @Argument(help: "The name of an existing tally.") var name: String
        // Captures negative amounts too, which would otherwise be taken for options.
        @Argument(parsing: .allUnrecognized, help: ArgumentHelp("The amount (default 1): 3, -1, 0.5, 410k.", valueName: "amount"))
        var amount: [String] = []
        @OptionGroup var decimal: DecimalOption

        func validate() throws {
            let amounts = try ToolRunner.numberWords(amount)
            if amounts.count > 1 {
                throw ValidationError("Give one amount, not \(amounts.count). Add them up first with `abakus sum`.")
            }
        }

        func run() throws {
            var arguments: JSONObject = ["name": .string(name)]
            if let first = try ToolRunner.numberWords(amount).first {
                arguments["amount"] = .string(first)
            }
            decimal.apply(to: &arguments)
            try ToolRunner.run("tally_add", arguments)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a tally's value, count or thresholds (tally_set).",
            discussion: "Threshold options replace all thresholds; --clear-thresholds removes them."
        )

        @Argument(help: "The name of an existing tally.") var name: String
        @Option(parsing: .unconditional, help: "The new value (negative values too: --value -5).") var value: String?
        @Option(parsing: .unconditional, help: "The new count (a whole number).") var count: String?
        @Flag(help: "Remove all thresholds.") var clearThresholds = false
        @OptionGroup var thresholds: ThresholdOptions
        @OptionGroup var decimal: DecimalOption

        func validate() throws {
            if clearThresholds, thresholds.list() != nil {
                throw ValidationError("Give either --clear-thresholds or threshold options, not both.")
            }
        }

        func run() throws {
            var arguments: JSONObject = ["name": .string(name)]
            if let value {
                arguments["value"] = .string(value)
            }
            if let count {
                arguments["count"] = .string(count)
            }
            if clearThresholds {
                arguments["thresholds"] = []
            } else if let list = thresholds.list() {
                arguments["thresholds"] = list
            }
            decimal.apply(to: &arguments)
            try ToolRunner.run("tally_set", arguments)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show tallies with their state (tally_list).")

        @Argument(help: "Show only tallies whose name starts with this.") var prefix: String?

        func run() throws {
            var arguments = JSONObject()
            if let prefix {
                arguments["prefix"] = .string(prefix)
            }
            try ToolRunner.run("tally_list", arguments)
        }
    }

    struct Drop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a tally and print its final state (tally_drop).")

        @Argument(help: "The name of an existing tally.") var name: String

        func run() throws {
            try ToolRunner.run("tally_drop", ["name": .string(name)])
        }
    }
}

/// Threshold options, turned into tally_create's and tally_set's `thresholds` list. Each watches the value,
/// or the count with the `-count` variant.
struct ThresholdOptions: ParsableArguments {
    // `.unconditional`: the next word is the value even when it starts with "-" (a negative mark).
    @Option(parsing: .unconditional, help: ArgumentHelp("A ceiling on the value.", valueName: "n"))
    var limit: String?
    @Option(parsing: .unconditional, help: ArgumentHelp("A ceiling on the count.", valueName: "n"))
    var limitCount: String?
    @Option(parsing: .unconditionalSingleValue, help: ArgumentHelp("A mark on the value; repeat for several.", valueName: "n"))
    var at: [String] = []
    @Option(parsing: .unconditionalSingleValue, help: ArgumentHelp("A mark on the count; repeat for several.", valueName: "n"))
    var atCount: [String] = []
    @Option(parsing: .unconditional, help: ArgumentHelp("A period on the value: report every n.", valueName: "n"))
    var every: String?
    @Option(parsing: .unconditional, help: ArgumentHelp("A period on the count: report every n additions.", valueName: "n"))
    var everyCount: String?

    /// The `thresholds` argument, or nil when no threshold option was given.
    func list() -> JSONValue? {
        var items: [JSONValue] = []
        func add(_ kind: String, _ value: JSONValue, onCount: Bool) {
            var item: JSONObject = [kind: value]
            if onCount {
                item["of"] = "count"
            }
            items.append(.object(item))
        }
        if let limit { add("limit", .string(limit), onCount: false) }
        if let limitCount { add("limit", .string(limitCount), onCount: true) }
        if !at.isEmpty { add("at", .array(at.map { .string($0) }), onCount: false) }
        if !atCount.isEmpty { add("at", .array(atCount.map { .string($0) }), onCount: true) }
        if let every { add("every", .string(every), onCount: false) }
        if let everyCount { add("every", .string(everyCount), onCount: true) }
        return items.isEmpty ? nil : .array(items)
    }
}
