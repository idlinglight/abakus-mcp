import AbakusCore

/// The `error` member of a JSON-RPC error response.
struct RPCError: Error, Equatable {
    var code: Int
    var message: String
    var data: JSONValue?

    // Standard JSON-RPC 2.0 codes.
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    // Defined by MCP 2026-07-28.
    static let unsupportedProtocolVersionCode = -32022

    static func parseError(_ detail: String) -> RPCError {
        RPCError(code: parseErrorCode, message: "Parse error: \(detail).")
    }

    static func invalidRequest(_ message: String) -> RPCError {
        RPCError(code: invalidRequestCode, message: message)
    }

    static func methodNotFound(_ method: String, _ detail: String? = nil) -> RPCError {
        RPCError(code: methodNotFoundCode, message: "Method not found: \(method)." + (detail.map { " " + $0 } ?? ""))
    }

    static func invalidParams(_ message: String) -> RPCError {
        RPCError(code: invalidParamsCode, message: message)
    }

    /// The modern error for a protocol version the server does not speak; `data` lists what it does speak.
    static func unsupportedProtocolVersion(requested: String) -> RPCError {
        RPCError(
            code: unsupportedProtocolVersionCode,
            message: "Unsupported protocol version",
            data: [
                "supported": .array(ProtocolRevision.supported.map { .string($0.rawValue) }),
                "requested": .string(requested),
            ]
        )
    }

    var object: JSONObject {
        var object: JSONObject = ["code": .number(String(code)), "message": .string(message)]
        object["data"] = data
        return object
    }
}

/// Builds JSON-RPC response objects.
enum RPCResponse {
    static func result(id: JSONValue, _ result: JSONObject) -> JSONObject {
        ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }

    /// `id` is nil when the request's id could not be read. MCP then leaves the member out: its schema has no
    /// `null` id, unlike plain JSON-RPC.
    static func error(id: JSONValue?, _ error: RPCError) -> JSONObject {
        var response: JSONObject = ["jsonrpc": "2.0"]
        response["id"] = id
        response["error"] = .object(error.object)
        return response
    }
}

/// `_meta` keys that MCP 2026-07-28 reserves for per-request and per-result protocol fields.
enum MetaKey {
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    static let serverInfo = "io.modelcontextprotocol/serverInfo"
}
