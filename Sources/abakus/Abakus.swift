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

    func run() throws {
        try MCPServer.run(tools: Catalog.tools, context: ToolContext.live())
    }
}
