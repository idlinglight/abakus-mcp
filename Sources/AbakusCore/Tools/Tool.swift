import Foundation

/// One operation agents can call: over MCP (`tools/call`) or from the CLI. Defined once, here in the core.
public protocol Tool: Sendable {
    /// The name agents see, lowercase snake_case: `tally_add`. With deferred tool loading, agents often see
    /// nothing but the name before deciding to load a tool, so it has to say what the tool is for.
    var name: String { get }
    /// What the tool does, what it returns, and the rules its arguments follow (e.g. how number strings are
    /// read). Plain text; written for an agent deciding whether and how to call it.
    var description: String { get }
    /// JSON Schema of the arguments: an object schema (`"type": "object"`, `properties`, `required`).
    var inputSchema: JSONValue { get }
    var annotations: ToolAnnotations { get }
    /// Keys of the result that grow with the input, such as how each string was read. The command line prints
    /// them; an MCP result leaves them out, so that its size does not depend on how much input there was
    /// (ADR-0008). Most tools have none.
    var detailKeys: [String] { get }
    /// Runs the tool. The result is always a JSON object, with the detail keys included. Anything the caller
    /// should fix (unknown name, unreadable number, ...) is a `ToolError`, which reaches the agent as a failed tool
    /// call it can read.
    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject
}

extension Tool {
    public var detailKeys: [String] { [] }

    /// A result as an MCP client gets it: without the detail keys (ADR-0008).
    public func withoutDetails(_ result: JSONObject) -> JSONObject {
        var answer = result
        for key in detailKeys {
            answer[key] = nil
        }
        return answer
    }
}

/// MCP tool annotations. Set every flag deliberately; clients show them and some decide on them.
public struct ToolAnnotations: Sendable, Equatable {
    public var title: String?
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool
    /// abakus never reaches outside the machine, so this stays false.
    public var openWorld: Bool

    public init(title: String? = nil, readOnly: Bool, destructive: Bool, idempotent: Bool, openWorld: Bool = false) {
        self.title = title
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
        self.openWorld = openWorld
    }
}

/// A failure the caller can act on. `message` says what is wrong and what to do instead, in a sentence or
/// two; `details` carries data that helps, e.g. the existing tally when a name is taken.
public struct ToolError: Error, Sendable, Equatable {
    public var message: String
    public var details: JSONObject?

    public init(_ message: String, details: JSONObject? = nil) {
        self.message = message
        self.details = details
    }

    /// The error as an agent reads it, over MCP and on the command line alike: the message, then the details
    /// as compact JSON on a line of their own.
    public var text: String {
        guard let details else { return message }
        return message + "\nDetails: " + JSONWriter.write(details)
    }
}

/// What a tool may use from its surroundings. Tests build their own; the server and the CLI use `live()`.
public struct ToolContext: Sendable {
    /// Where state lives (ADR-0003). Tools create what they need below it.
    public var stateDirectory: URL
    /// The current time. Injected so tests can fix it.
    public var now: @Sendable () -> Date

    public init(stateDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.stateDirectory = stateDirectory
        self.now = now
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ToolError) -> ToolContext {
        ToolContext(stateDirectory: try StateDirectory.resolve(environment: environment))
    }
}
