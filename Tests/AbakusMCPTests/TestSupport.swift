import AbakusCore
import AbakusMCP
import Foundation
import Testing

/// Returns its arguments under "received", so tests can see exactly what reached the tool.
struct EchoTool: Tool {
    let name = "echo"
    let description = "Returns its arguments under \"received\"."
    let inputSchema: JSONValue = ["type": "object", "properties": ["x": ["type": ["number", "string"]]]]
    let annotations = ToolAnnotations(title: "Echo", readOnly: true, destructive: false, idempotent: true)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        ["received": .object(arguments)]
    }
}

/// Always throws a `ToolError`; with `withDetails: true` the error carries details.
struct FailingTool: Tool {
    let name = "fail"
    let description = "Fails on purpose."
    let inputSchema: JSONValue = ["type": "object", "properties": ["withDetails": ["type": "boolean"]]]
    let annotations = ToolAnnotations(readOnly: false, destructive: true, idempotent: false)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        if arguments["withDetails"]?.boolValue == true {
            throw ToolError(
                "A tally named \"items\" already exists. Use another name, or pass unique: true.",
                details: ["name": "items", "value": .number("3.5"), "count": 2]
            )
        }
        throw ToolError("Nothing to do.")
    }
}

/// A context whose state folder is never created: these tools write nothing.
func testContext() -> ToolContext {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("abakus-mcp-tests-\(UUID().uuidString)")
    return ToolContext(stateDirectory: folder)
}

func makeServer() -> MCPServer {
    MCPServer(tools: [EchoTool(), FailingTool()], context: testContext())
}

let modernMeta: JSONValue = [
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": [:],
    "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1.0"],
]

func request(_ id: Int, _ method: String, _ params: JSONObject? = nil) -> String {
    var message: JSONObject = ["jsonrpc": "2.0", "id": .number(String(id)), "method": .string(method)]
    message["params"] = params.map { .object($0) }
    return JSONWriter.write(message)
}

/// A request with the modern per-request fields in `params._meta`.
func modernRequest(_ id: Int, _ method: String, _ params: JSONObject = [:], meta: JSONValue = modernMeta) -> String {
    var params = params
    params["_meta"] = meta
    return request(id, method, params)
}

func initializeRequest(_ id: Int = 1, version: String) -> String {
    request(id, "initialize", [
        "protocolVersion": .string(version),
        "capabilities": [:],
        "clientInfo": ["name": "test-client", "version": "1.0"],
    ])
}

/// Sends one line and returns the response line, failing the test if there is none.
func respond(_ server: inout MCPServer, _ line: String) throws -> String {
    try respond(&server, Array(line.utf8))
}

func respond(_ server: inout MCPServer, _ line: [UInt8]) throws -> String {
    let output = server.handle(line: line)
    return try #require(output)
}

/// Sends one line and returns the parsed response, or nil when the server sent nothing.
func send(_ server: inout MCPServer, _ line: String) throws -> JSONObject? {
    guard let output = server.handle(line: line) else { return nil }
    #expect(!output.utf8.contains(0x0A), "a response must fit on one line")
    let response: JSONObject = try #require(JSONReader.read(output).objectValue)
    return response
}

/// Sends one request and returns its `result`, failing the test if the response is anything else.
func result(_ server: inout MCPServer, _ line: String) throws -> JSONObject {
    let response = try #require(try send(&server, line))
    #expect(response["error"] == nil, "unexpected error: \(JSONWriter.write(response))")
    return try #require(response["result"]?.objectValue)
}

/// Sends one request and returns its `error`, failing the test if the response is anything else.
func error(_ server: inout MCPServer, _ line: String) throws -> JSONObject {
    let response = try #require(try send(&server, line))
    #expect(response["result"] == nil, "unexpected result: \(JSONWriter.write(response))")
    return try #require(response["error"]?.objectValue)
}

extension JSONObject {
    /// The value at a path of object keys and array indices, e.g. `["content", 0, "text"]`.
    subscript(path path: [any Sendable]) -> JSONValue? {
        var current: JSONValue? = .object(self)
        for step in path {
            switch (current, step) {
            case (.object(let object)?, let key as String): current = object[key]
            case (.array(let array)?, let index as Int): current = array.indices.contains(index) ? array[index] : nil
            default: return nil
            }
        }
        return current
    }
}
