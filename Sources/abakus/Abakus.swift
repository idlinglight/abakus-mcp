import AbakusCore
import AbakusMCP
import ArgumentParser

@main
struct Abakus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AbakusInfo.name,
        abstract: "Tallies, exact sums, calculations and date differences for agents: an MCP server and a command line tool.",
        discussion: """
            Every command runs one of the tools the MCP server offers and prints its result as JSON, the same \
            JSON an agent gets. A tool's error goes to stderr with exit status 1; a usage mistake shows the usage \
            with exit status 64.
            """,
        version: AbakusInfo.version,
        subcommands: [Serve.self, TallyCommand.self, Sum.self, Calc.self, DateDiff.self, Tools.self, Call.self]
    )
}

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the tools over MCP on stdin and stdout (for an MCP client to start, not for a terminal)."
    )

    /// Serves until stdin closes, then exits with status 0.
    func run() throws {
        let context: ToolContext
        do {
            context = try ToolContext.live()
        } catch {
            throw StartupFailure(description: error.message)
        }
        try MCPServer.run(tools: Catalog.tools, context: context)
    }

    /// ArgumentParser prints this as "Error: <description>" on stderr and exits with status 1.
    struct StartupFailure: Error, CustomStringConvertible {
        var description: String
    }
}
