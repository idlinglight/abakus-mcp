import AbakusCore
import AbakusMCP
import ArgumentParser

@main
struct Abakus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: AbakusInfo.name,
        abstract: "Tallies, exact sums and date differences for agents: an MCP server and a command line tool.",
        version: AbakusInfo.version,
        subcommands: [Serve.self]
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
