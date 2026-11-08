import AbakusCore
import Foundation

/// MCP over stdio (ADR-0002). Placeholder until the server is implemented.
public enum MCPServer {
    public struct NotImplemented: Error, CustomStringConvertible {
        public var description: String { "the MCP server is not implemented yet" }
    }

    /// Serves `tools` on stdin/stdout until stdin closes.
    public static func run(tools: [any Tool], context: ToolContext) throws {
        throw NotImplemented()
    }
}
