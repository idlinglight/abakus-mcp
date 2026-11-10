import AbakusCore

/// MCP over stdio (ADR-0002): the protocol core, which turns one input line into at most one output line.
/// `serve(input:output:)` and `run(tools:context:)` connect it to file descriptors.
///
/// It speaks both eras of the specification at once:
/// - A request whose `params._meta` names a protocol version is served by that revision, statelessly. For the
///   modern revision (2026-07-28) `_meta` must also carry the client capabilities. A version this server does
///   not speak gets the `UnsupportedProtocolVersion` error (-32022), which lists the versions it does speak.
/// - `initialize` negotiates a legacy revision (2025-11-25 down to 2024-11-05). Requests without a version in
///   `_meta` are served by the negotiated revision, or by the newest legacy one if there was no `initialize`:
///   no request depends on a handshake.
/// - The revision decides which methods exist (`server/discover` is modern only, `ping` legacy only) and the
///   shape of results: `resultType`, cache hints and the server's identity in `_meta` (modern only),
///   `structuredContent` (since 2025-06-18), tool annotations (since 2025-03-26), and whether JSON-RPC batches
///   are accepted (2025-03-26 only, after `initialize` negotiated it).
public struct MCPServer {
    public let tools: [any Tool]
    public let context: ToolContext
    public let instructions: String
    /// The revision the last `initialize` negotiated, nil before any.
    public private(set) var negotiatedRevision: ProtocolRevision?
    let diagnose: (String) -> Void

    /// How long clients may cache the `server/discover` and `tools/list` results, in milliseconds. The tool list
    /// never changes while the process runs.
    static let cacheTTLMilliseconds = 3_600_000

    /// - Parameter diagnostics: receives notes on ignored input, for stderr. Never for stdout.
    public init(
        tools: [any Tool],
        context: ToolContext,
        instructions: String = ServerInstructions.text,
        diagnostics: @escaping (String) -> Void = { _ in }
    ) {
        self.tools = tools
        self.context = context
        self.instructions = instructions
        self.diagnose = diagnostics
    }

    public mutating func handle(line: String) -> String? {
        handle(line: Array(line.utf8))
    }

    /// Handles one line of input (without its line break) and returns the line to send back, or nil when
    /// nothing is to be sent: for notifications, responses from the client and blank lines.
    public mutating func handle(line: [UInt8]) -> String? {
        guard line.contains(where: { !JSONReader.isWhitespace($0) }) else { return nil }
        let message: JSONValue
        do {
            message = try JSONReader.read(line)
        } catch {
            return JSONWriter.write(RPCResponse.error(id: nil, .parseError(error.description)))
        }
        if case .array(let batch) = message {
            return handleBatch(batch).map { JSONWriter.write($0) }
        }
        return handleMessage(message, inBatch: false).map { JSONWriter.write($0) }
    }

    /// Client-supplied text for a diagnostic line: written as a JSON string, so line breaks and control
    /// characters arrive escaped, and cut to 200 characters.
    static func quoted(_ text: String) -> String {
        let limit = 200
        return JSONWriter.write(.string(text.count > limit ? text.prefix(limit) + "…" : text))
    }

    // MARK: JSON-RPC

    /// Only 2025-03-26 has batches, so they are accepted only after `initialize` negotiated that revision.
    /// Anything else gets one Invalid Request error for the whole array.
    private mutating func handleBatch(_ batch: [JSONValue]) -> JSONValue? {
        guard negotiatedRevision?.hasBatches == true else {
            return .object(RPCResponse.error(id: nil, .invalidRequest(
                "JSON-RPC batches are accepted only after initialize negotiated protocol version 2025-03-26. Send one message per line."
            )))
        }
        guard !batch.isEmpty else {
            return .object(RPCResponse.error(id: nil, .invalidRequest(
                "The batch is empty. Put at least one request in it, or send one message per line."
            )))
        }
        var responses: [JSONValue] = []
        for message in batch {
            if let response = handleMessage(message, inBatch: true) {
                responses.append(.object(response))
            }
        }
        return responses.isEmpty ? nil : .array(responses)
    }

    /// Returns the response object, or nil for a notification or a response from the client.
    private mutating func handleMessage(_ value: JSONValue, inBatch: Bool) -> JSONObject? {
        guard case .object(let message) = value else {
            return RPCResponse.error(id: nil, .invalidRequest(
                "Each message must be a JSON object. Send one JSON-RPC request or notification per line."
            ))
        }
        // A message without an "id" member is a notification. Notifications never get a response, not even
        // when they are malformed.
        guard let idValue = message["id"] else {
            handleNotification(message)
            return nil
        }
        // MCP allows string and number ids. Any other id, null included, cannot be echoed.
        let id: JSONValue?
        switch idValue {
        case .string, .number: id = idValue
        default: id = nil
        }
        guard message["jsonrpc"]?.stringValue == "2.0" else {
            return RPCResponse.error(id: id, .invalidRequest(
                "The member \"jsonrpc\" must be \"2.0\". Add \"jsonrpc\": \"2.0\" to every message."
            ))
        }
        guard let methodValue = message["method"] else {
            if message["result"] != nil || message["error"] != nil {
                diagnose("ignored a JSON-RPC response; this server sends no requests.")
                return nil
            }
            return RPCResponse.error(id: id, .invalidRequest(
                "The member \"method\" is missing. Name the method as a string, e.g. \"method\": \"tools/list\"."
            ))
        }
        guard case .string(let method) = methodValue else {
            return RPCResponse.error(id: id, .invalidRequest(
                "The member \"method\" must be a string, e.g. \"method\": \"tools/list\"."
            ))
        }
        guard let id else {
            return RPCResponse.error(id: nil, .invalidRequest(
                "The member \"id\" must be a string or a number. Use one, or leave \"id\" out to send a notification."
            ))
        }
        let params: JSONObject
        switch message["params"] {
        case nil:
            params = JSONObject()
        case .some(.object(let object)):
            params = object
        case .some(.array):
            return RPCResponse.error(id: id, .invalidParams(
                "The member \"params\" must be an object; MCP uses named parameters. Pass them as an object."
            ))
        default:
            return RPCResponse.error(id: id, .invalidRequest(
                "The member \"params\" must be an object. Pass the parameters as an object, or leave \"params\" out."
            ))
        }
        if inBatch, method == "initialize" {
            return RPCResponse.error(id: id, .invalidRequest(
                "initialize must not be part of a batch. Send it on its own line first."
            ))
        }
        switch dispatch(method: method, params: params) {
        case .success(let result): return RPCResponse.result(id: id, result)
        case .failure(let error): return RPCResponse.error(id: id, error)
        }
    }

    /// Never produces a response. Malformed notifications and unknown ones are noted on stderr.
    private func handleNotification(_ message: JSONObject) {
        guard message["jsonrpc"]?.stringValue == "2.0", let method = message["method"]?.stringValue else {
            if message["result"] != nil || message["error"] != nil {
                diagnose("ignored a JSON-RPC response without an id; this server sends no requests.")
            } else {
                diagnose("dropped a malformed message without an id: it needs \"jsonrpc\": \"2.0\" and a string \"method\".")
            }
            return
        }
        switch method {
        case "notifications/initialized":
            break
        case "notifications/cancelled":
            // Requests are answered before the next line is read, so none is ever in flight.
            break
        default:
            diagnose("ignored the notification \(Self.quoted(method)).")
        }
    }

    // MARK: MCP

    private mutating func dispatch(method: String, params: JSONObject) -> Result<JSONObject, RPCError> {
        if method == "initialize" {
            return initialize(params)
        }
        let revision: ProtocolRevision
        switch requestedRevision(params) {
        case .failure(let error):
            return .failure(error)
        case .success(let named?):
            revision = named
        case .success(nil):
            if method == "server/discover" {
                return .failure(.invalidParams(
                    "server/discover needs params._meta with \"\(MetaKey.protocolVersion)\" and \"\(MetaKey.clientCapabilities)\"."
                ))
            }
            revision = negotiatedRevision ?? .newestLegacy
        }
        switch method {
        case "server/discover" where revision.isModern:
            return .success(discoverResult(for: revision))
        case "server/discover":
            return .failure(.methodNotFound(method,
                "Protocol version \(revision.rawValue) has no server/discover; name a modern version such as \(ProtocolRevision.v2026_07_28.rawValue) in params._meta."
            ))
        case "tools/list":
            return listTools(params, revision: revision)
        case "tools/call":
            return callTool(params, revision: revision)
        case "ping" where !revision.isModern:
            return .success(JSONObject())
        case "ping":
            return .failure(.methodNotFound(method,
                "Protocol version \(revision.rawValue) has no ping; to check that the server answers, send server/discover."
            ))
        default:
            let methods = revision.isModern ? "server/discover, tools/list and tools/call" : "initialize, ping, tools/list and tools/call"
            return .failure(.methodNotFound(method, "In protocol version \(revision.rawValue) this server answers \(methods)."))
        }
    }

    /// The revision a request names in `params._meta`, checked by the modern rules, or nil when it names none.
    private func requestedRevision(_ params: JSONObject) -> Result<ProtocolRevision?, RPCError> {
        guard let metaValue = params["_meta"] else { return .success(nil) }
        guard let meta = metaValue.objectValue else {
            return .failure(.invalidParams(
                "params._meta must be an object. Put per-request fields such as \"\(MetaKey.protocolVersion)\" in it."
            ))
        }
        guard let versionValue = meta[MetaKey.protocolVersion] else {
            // Legacy requests may carry _meta too (progressToken), but never the modern protocol fields.
            if meta[MetaKey.clientCapabilities] != nil || meta[MetaKey.clientInfo] != nil {
                return .failure(.invalidParams(
                    "params._meta lacks \"\(MetaKey.protocolVersion)\", which every request must carry. Add it, e.g. \"\(ProtocolRevision.v2026_07_28.rawValue)\"."
                ))
            }
            return .success(nil)
        }
        guard let version = versionValue.stringValue else {
            return .failure(.invalidParams(
                "\"\(MetaKey.protocolVersion)\" in params._meta must be a string such as \"\(ProtocolRevision.v2026_07_28.rawValue)\"."
            ))
        }
        guard let revision = ProtocolRevision(rawValue: version) else {
            return .failure(.unsupportedProtocolVersion(requested: version))
        }
        if revision.isModern, meta[MetaKey.clientCapabilities]?.objectValue == nil {
            return .failure(.invalidParams(
                "params._meta lacks \"\(MetaKey.clientCapabilities)\" (an object), which protocol version \(version) requires on every request. Send {} if the client declares none."
            ))
        }
        return .success(revision)
    }

    /// Legacy handshake: answers with the requested revision if it is a legacy one this server speaks, otherwise
    /// with the newest legacy revision.
    private mutating func initialize(_ params: JSONObject) -> Result<JSONObject, RPCError> {
        guard let requested = params["protocolVersion"]?.stringValue else {
            return .failure(.invalidParams(
                "initialize needs params.protocolVersion, a string such as \"\(ProtocolRevision.newestLegacy.rawValue)\"."
            ))
        }
        let revision = ProtocolRevision(rawValue: requested).flatMap { $0.isModern ? nil : $0 } ?? .newestLegacy
        negotiatedRevision = revision
        let client = params["clientInfo"]?.objectValue?["name"]?.stringValue.map { "client \(Self.quoted($0))" } ?? "a client"
        diagnose("initialize: \(client) asked for protocol version \(Self.quoted(requested)), using \(revision.rawValue).")
        return .success([
            "protocolVersion": .string(revision.rawValue),
            "capabilities": capabilities,
            "serverInfo": serverInfo,
            "instructions": .string(instructions),
        ])
    }

    private var capabilities: JSONValue {
        ["tools": [:]]
    }

    private var serverInfo: JSONValue {
        ["name": .string(AbakusInfo.name), "version": .string(AbakusInfo.version)]
    }

    /// Only for modern revisions; `dispatch` refuses `server/discover` under legacy ones.
    private func discoverResult(for revision: ProtocolRevision) -> JSONObject {
        result(withCacheHints([
            "supportedVersions": ProtocolRevision.supportedVersions,
            "capabilities": capabilities,
            "instructions": .string(instructions),
        ], for: revision), for: revision)
    }

    /// Adds what modern revisions require on every result: `resultType` first, the server's identity in `_meta`
    /// last. Legacy results stay as they are.
    private func result(_ fields: JSONObject, for revision: ProtocolRevision) -> JSONObject {
        guard revision.isModern else { return fields }
        var result: JSONObject = ["resultType": "complete"]
        for (key, value) in fields.entries {
            result[key] = value
        }
        result["_meta"] = [MetaKey.serverInfo: serverInfo]
        return result
    }

    /// Adds the cache hints modern revisions require on `server/discover` and `tools/list` results.
    private func withCacheHints(_ fields: JSONObject, for revision: ProtocolRevision) -> JSONObject {
        guard revision.isModern else { return fields }
        var fields = fields
        fields["ttlMs"] = .number(String(Self.cacheTTLMilliseconds))
        fields["cacheScope"] = "public"
        return fields
    }

    private func listTools(_ params: JSONObject, revision: ProtocolRevision) -> Result<JSONObject, RPCError> {
        if let cursor = params["cursor"], !cursor.isNull {
            return .failure(.invalidParams(
                "Unknown cursor. This server returns all tools in one page; call tools/list without a cursor."
            ))
        }
        let fields: JSONObject = ["tools": .array(tools.map { definition(of: $0, for: revision) })]
        return .success(result(withCacheHints(fields, for: revision), for: revision))
    }

    private func definition(of tool: any Tool, for revision: ProtocolRevision) -> JSONValue {
        var definition: JSONObject = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
        ]
        if revision.hasToolAnnotations {
            let flags = tool.annotations
            var annotations = JSONObject()
            annotations["title"] = flags.title.map { .string($0) }
            annotations["readOnlyHint"] = .bool(flags.readOnly)
            annotations["destructiveHint"] = .bool(flags.destructive)
            annotations["idempotentHint"] = .bool(flags.idempotent)
            annotations["openWorldHint"] = .bool(flags.openWorld)
            definition["annotations"] = .object(annotations)
        }
        return .object(definition)
    }

    /// A tool's result, without its detail keys (ADR-0008), reaches the model as compact JSON text, and clients on
    /// revisions that have it also get the object as `structuredContent`. A `ToolError` becomes a result with
    /// `isError: true` whose text is the message and, if present, the details; it carries no `structuredContent`,
    /// since that is reserved for the tool's result.
    private func callTool(_ params: JSONObject, revision: ProtocolRevision) -> Result<JSONObject, RPCError> {
        guard let name = params["name"]?.stringValue else {
            return .failure(.invalidParams(
                "tools/call needs params.name, the name of the tool (a string). tools/list shows the names."
            ))
        }
        let arguments: JSONObject
        switch params["arguments"] {
        case nil, .some(.null):
            arguments = JSONObject()
        case .some(.object(let object)):
            arguments = object
        default:
            return .failure(.invalidParams(
                "params.arguments must be an object that maps argument names to values, or be left out."
            ))
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            let renamed = Catalog.renameNote(for: name).map { $0 + " " } ?? ""
            return .failure(.invalidParams("Unknown tool: \(name). \(renamed)tools/list shows the available tools."))
        }
        var fields: JSONObject
        do {
            let output = tool.withoutDetails(try tool.call(arguments, in: context))
            fields = ["content": [["type": "text", "text": .string(JSONWriter.write(output))]]]
            if revision.hasStructuredContent {
                fields["structuredContent"] = .object(output)
            }
            fields["isError"] = false
        } catch {
            fields = ["content": [["type": "text", "text": .string(error.text)]], "isError": true]
        }
        return .success(result(fields, for: revision))
    }
}
