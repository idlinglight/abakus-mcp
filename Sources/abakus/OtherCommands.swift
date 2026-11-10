import AbakusCore
import ArgumentParser
import Foundation

struct Sum: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add numbers exactly (sum).",
        discussion: "Without numbers, reads them from stdin, separated by whitespace or line breaks: grep -oE '[0-9][0-9.]*k' build.log | abakus sum"
    )

    // Captures negative numbers too, which would otherwise be taken for options.
    @Argument(parsing: .allUnrecognized, help: ArgumentHelp("Numbers: 12, -3, 0.1, 410k, 1,234.5.", valueName: "number"))
    var numbers: [String] = []
    @OptionGroup var decimal: DecimalOption

    // Usage mistakes in validate() rather than run(), so that the usage shown is sum's.
    func validate() throws {
        if try ToolRunner.numberWords(numbers).isEmpty {
            try ToolRunner.requireStandardInputNotTerminal(command: "sum")
        }
    }

    func run() throws {
        let given = try ToolRunner.numberWords(numbers)
        let words = given.isEmpty ? ToolRunner.wordsFromStandardInput() : given
        var arguments: JSONObject = ["numbers": .array(words.map { .string($0) })]
        decimal.apply(to: &arguments)
        try ToolRunner.run("sum", arguments)
    }
}

struct Calc: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Work out one expression exactly, also over tallies (calc).",
        discussion: """
            Quote the expression: *, (, {, ^ and spaces mean something to the shell. Several arguments are joined \
            with spaces. Examples: abakus calc '{errors-k3f9} / {requests-p2x7} * 100', abakus calc \
            'round(1000 * 1.045^10, 2)', abakus calc -2^2
            """
    )

    // Captures a leading minus too (-2^2, -{a}), which would otherwise be taken for an option.
    @Argument(
        parsing: .allUnrecognized,
        help: ArgumentHelp("The expression, quoted: '(410k - {tokens-m4q8}) / 410k * 100'.", valueName: "expression")
    )
    var words: [String] = []

    /// The words without a leading `--` terminator, which belongs to the command line, not to the expression.
    private var expressionWords: ArraySlice<String> {
        words.first == "--" ? words.dropFirst() : words[...]
    }

    // In validate() rather than run(), so that the usage shown is calc's.
    func validate() throws {
        if expressionWords.isEmpty {
            throw ValidationError("Give the expression, quoted: abakus calc '{errors-k3f9} / {requests-p2x7} * 100'")
        }
    }

    func run() throws {
        try ToolRunner.run("calc", ["expression": .string(expressionWords.joined(separator: " "))])
    }
}

struct DateDiff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "date-diff",
        abstract: "Time between two dates or times, in calendar units and in totals (date_diff)."
    )

    @Argument(help: "From: 2026-11-08, 2026-11-08T14:30:00Z, 2026-11-08T14:30+01:00, or now.") var from: String
    @Argument(help: "To, in the same forms (default: now).") var to: String?

    func run() throws {
        var arguments: JSONObject = ["from": .string(from)]
        if let to {
            arguments["to"] = .string(to)
        }
        try ToolRunner.run("date_diff", arguments)
    }
}

struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the tools, with the first line of each description.")

    @Option(help: ArgumentHelp("Print one tool's full description and input schema instead.", valueName: "name"))
    var show: String?

    func run() throws {
        if let show {
            let tool = try ToolRunner.tool(named: show)
            print(tool.description)
            print()
            print(JSONWriter.write(tool.inputSchema))
            return
        }
        let width = Catalog.tools.map(\.name.count).max() ?? 0
        for tool in Catalog.tools {
            let firstLine = tool.description.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            print(tool.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + firstLine)
        }
    }
}

struct Call: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Call a tool with JSON arguments, as an MCP client sends them; prints the full result as JSON.",
        discussion: #"""
            The result includes the detail keys an MCP result leaves out, such as sum's read; with \#
            --without-details, a successful result is exactly the text an MCP client gets. Example: abakus call sum \#
            '{"numbers": ["410k", 0.5]}'
            """#
    )

    @Argument(help: "The tool's name, e.g. tally_add (see `abakus tools`).") var tool: String
    @Argument(help: "The arguments as a JSON object, or - to read them from stdin (default: {}).") var arguments: String?
    @Flag(help: "Leave out the result's detail keys, as the MCP server does, so a successful result is exactly the text an MCP client gets. Errors do not change: a tool's error is the text an agent reads, on stderr.")
    var withoutDetails = false

    func run() throws {
        var text = arguments ?? "{}"
        if text == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        let value: JSONValue
        do {
            value = try JSONReader.read(text)
        } catch {
            throw ToolRunner.Failure("The arguments are not valid JSON (\(error.description)). Pass one JSON object.")
        }
        guard case .object(let object) = value else {
            throw ToolRunner.Failure(#"The arguments must be a JSON object, e.g. '{"name": "items"}'."#)
        }
        try ToolRunner.run(tool, object, withoutDetails: withoutDetails)
    }
}
