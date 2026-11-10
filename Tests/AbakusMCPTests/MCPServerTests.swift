import AbakusCore
import AbakusMCP
import Testing

@Suite struct LegacyEraTests {
    @Test(arguments: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
    func initializeAnswersWithASupportedRequestedVersion(version: String) throws {
        var server = makeServer()
        let initialized = try result(&server, initializeRequest(version: version))
        #expect(initialized["protocolVersion"] == .string(version))
        #expect(initialized["capabilities"] == ["tools": [:]])
        #expect(initialized["serverInfo"] == ["name": "abakus", "version": .string(AbakusInfo.version)])
        #expect(initialized["instructions"] == .string(ServerInstructions.text))
        #expect(initialized["resultType"] == nil)
        #expect(server.negotiatedRevision?.rawValue == version)
    }

    @Test(arguments: ["2026-07-28", "1999-01-01", "2025-01-01", ""])
    func initializeFallsBackToTheNewestLegacyVersion(version: String) throws {
        var server = makeServer()
        let initialized = try result(&server, initializeRequest(version: version))
        #expect(initialized["protocolVersion"] == "2025-11-25")
    }

    @Test func initializeNeedsAProtocolVersion() throws {
        var server = makeServer()
        let failure = try error(&server, request(1, "initialize", ["capabilities": [:]]))
        #expect(failure["code"] == -32602)
        #expect(try error(&server, request(2, "initialize"))["code"] == -32602)
        #expect(try error(&server, request(3, "initialize", ["protocolVersion": 20251125]))["code"] == -32602)
    }

    @Test func initializedNotificationGetsNoResponse() throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: "2025-11-25"))
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func toolsWorkWithoutAHandshake() throws {
        var server = makeServer()
        let list = try result(&server, request(1, "tools/list"))
        #expect(list[path: ["tools", 0, "name"]] == "echo")
        let call = try result(&server, request(2, "tools/call", ["name": "echo", "arguments": ["x": 1]]))
        #expect(call["isError"] == false)
        // Without initialize, requests are served as the newest legacy revision.
        #expect(call["structuredContent"] == ["received": ["x": 1]])
        #expect(call["resultType"] == nil)
    }

    /// A tool's detail keys stay out of the MCP result, in the text and in structuredContent alike (ADR-0008).
    @Test func resultsLeaveOutDetailKeys() throws {
        struct DetailTool: Tool {
            let name = "detail"
            let description = "Answers, with a detail."
            let inputSchema: JSONValue = ["type": "object", "properties": [:]]
            let annotations = ToolAnnotations(readOnly: true, destructive: false, idempotent: true)
            let detailKeys = ["each"]

            func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
                ["answer": 3, "each": [1, 2]]
            }
        }
        var server = MCPServer(tools: [DetailTool()], context: testContext())
        let call = try result(&server, request(1, "tools/call", ["name": "detail"]))
        #expect(call["structuredContent"] == ["answer": 3])
        #expect(call[path: ["content", 0, "text"]] == #"{"answer":3}"#)
    }

    /// A tool's own `withoutDetails` is the one the server uses, although it holds the tool as `any Tool`: calc
    /// shortens its `tallies` that way (ADR-0008, amendment).
    @Test func resultsGoThroughTheToolsOwnWithoutDetails() throws {
        struct ShorteningTool: Tool {
            let name = "shortening"
            let description = "Answers with a list, shortened over MCP."
            let inputSchema: JSONValue = ["type": "object", "properties": [:]]
            let annotations = ToolAnnotations(readOnly: true, destructive: false, idempotent: true)

            func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
                ["answer": 3, "each": [1, 2, 3]]
            }

            func withoutDetails(_ result: JSONObject) -> JSONObject {
                ["answer": result["answer"] ?? .null, "each": [1], "each_total": 3]
            }
        }
        var server = MCPServer(tools: [ShorteningTool()], context: testContext())
        let call = try result(&server, request(1, "tools/call", ["name": "shortening"]))
        #expect(call["structuredContent"] == ["answer": 3, "each": [1], "each_total": 3])
        #expect(call[path: ["content", 0, "text"]] == #"{"answer":3,"each":[1],"each_total":3}"#)
    }

    /// The tally tools go through their own withoutDetails too: an at threshold's marks stay off MCP, in the text
    /// and in structuredContent, while the core result has them for the command line.
    @Test func tallyResultsLeaveOutTheMarksOfAnAtThreshold() throws {
        var server = MCPServer(tools: TallyTools.all, context: testContext())
        let marks: JSONValue = .array((1...20).map { .number(String($0)) })
        let arguments: JSONValue = ["name": "marks", "shared": true, "thresholds": [["at": marks]]]
        let call = try result(&server, request(1, "tools/call", ["name": "tally_create", "arguments": arguments]))
        let expected: JSONValue = [["marks_total": 20, "of": "value", "passed": 0, "ahead": [1, 2, 3, 4, 5]]]
        #expect(call[path: ["structuredContent", "thresholds"]] == expected)
        let text = try #require(call[path: ["content", 0, "text"]]?.stringValue)
        #expect(text.contains(#""thresholds":[{"marks_total":20,"of":"value","passed":0,"ahead":[1,2,3,4,5]}]"#))
        #expect(!text.contains(#""marks":"#))
    }

    @Test func toolListShapeFollowsTheNegotiatedRevision() throws {
        var newest = makeServer()
        _ = try result(&newest, initializeRequest(version: "2025-11-25"))
        let tools = try result(&newest, request(2, "tools/list"))
        #expect(tools[path: ["tools", 0]] == [
            "name": "echo",
            "description": "Returns its arguments under \"received\".",
            "inputSchema": ["type": "object", "properties": ["x": ["type": ["number", "string"]]]],
            "annotations": [
                "title": "Echo", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
                "openWorldHint": false,
            ],
        ])
        // A tool without a title gets no title annotation.
        #expect(tools[path: ["tools", 1, "annotations"]] == [
            "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false,
        ])
        #expect(tools["ttlMs"] == nil)
        #expect(tools["cacheScope"] == nil)
        #expect(tools["resultType"] == nil)

        var annotationsAdded = makeServer()
        _ = try result(&annotationsAdded, initializeRequest(version: "2025-03-26"))
        #expect(try result(&annotationsAdded, request(2, "tools/list"))[path: ["tools", 0, "annotations"]] != nil)

        var oldest = makeServer()
        _ = try result(&oldest, initializeRequest(version: "2024-11-05"))
        let oldTools = try result(&oldest, request(2, "tools/list"))
        #expect(oldTools[path: ["tools", 0, "name"]] == "echo")
        #expect(oldTools[path: ["tools", 0, "annotations"]] == nil)
    }

    @Test(arguments: [("2025-11-25", true), ("2025-06-18", true), ("2025-03-26", false), ("2024-11-05", false)])
    func structuredContentOnlyWhereTheRevisionHasIt(version: String, expected: Bool) throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: version))
        let call = try result(&server, request(2, "tools/call", ["name": "echo", "arguments": ["x": 1]]))
        #expect((call["structuredContent"] != nil) == expected)
        #expect(call[path: ["content", 0, "text"]] == #"{"received":{"x":1}}"#)
        #expect(call["isError"] == false)
    }

    @Test func pingAnswersWithAnEmptyResult() throws {
        var server = makeServer()
        #expect(try result(&server, request(1, "ping")) == JSONObject())
        _ = try result(&server, initializeRequest(2, version: "2024-11-05"))
        #expect(try result(&server, request(3, "ping")) == JSONObject())
    }

    @Test func aLaterInitializeRenegotiates() throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: "2024-11-05"))
        _ = try result(&server, initializeRequest(2, version: "2025-06-18"))
        #expect(server.negotiatedRevision == .v2025_06_18)
    }

    @Test func legacyMetaWithoutProtocolFieldsIsFine() throws {
        var server = makeServer()
        let call = try result(&server, request(1, "tools/call", ["name": "echo", "_meta": ["progressToken": "p1"]]))
        #expect(call["isError"] == false)
    }
}

@Suite struct ModernEraTests {
    @Test func discoverDescribesTheServer() throws {
        var server = makeServer()
        let discovered = try result(&server, modernRequest(1, "server/discover"))
        #expect(discovered.keys == [
            "resultType", "supportedVersions", "capabilities", "instructions", "ttlMs", "cacheScope", "_meta",
        ])
        #expect(discovered["resultType"] == "complete")
        #expect(discovered["supportedVersions"] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
        #expect(discovered["capabilities"] == ["tools": [:]])
        #expect(discovered["instructions"] == .string(ServerInstructions.text))
        #expect(discovered["ttlMs"] == 3_600_000)
        #expect(discovered["cacheScope"] == "public")
        #expect(discovered["_meta"] == [
            "io.modelcontextprotocol/serverInfo": ["name": "abakus", "version": .string(AbakusInfo.version)],
        ])
        // Discovery is stateless: it negotiates nothing.
        #expect(server.negotiatedRevision == nil)
    }

    @Test func toolsListCarriesResultTypeCacheHintsAndServerInfo() throws {
        var server = makeServer()
        let list = try result(&server, modernRequest(1, "tools/list"))
        #expect(list.keys == ["resultType", "tools", "ttlMs", "cacheScope", "_meta"])
        #expect(list["resultType"] == "complete")
        #expect(list[path: ["tools", 0, "annotations", "readOnlyHint"]] == true)
        #expect(list[path: ["_meta", "io.modelcontextprotocol/serverInfo", "name"]] == "abakus")
    }

    @Test func toolsCallCarriesResultTypeAndStructuredContent() throws {
        var server = makeServer()
        let call = try result(&server, modernRequest(1, "tools/call", ["name": "echo", "arguments": ["x": "410k"]]))
        #expect(call.keys == ["resultType", "content", "structuredContent", "isError", "_meta"])
        #expect(call["content"] == [["type": "text", "text": #"{"received":{"x":"410k"}}"#]])
        #expect(call["structuredContent"] == ["received": ["x": "410k"]])
        #expect(call["isError"] == false)
    }

    @Test func modernRequestsAreServedModernEvenAfterALegacyHandshake() throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: "2024-11-05"))
        let call = try result(&server, modernRequest(2, "tools/call", ["name": "echo"]))
        #expect(call["resultType"] == "complete")
        #expect(call["structuredContent"] != nil)
    }

    @Test(arguments: ["1900-01-01", "2026-12-31", "latest", ""])
    func unsupportedVersionsGetTheModernError(version: String) throws {
        var server = makeServer()
        let meta: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": .string(version),
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        for method in ["server/discover", "tools/list", "tools/call", "no/such/method"] {
            let failure = try error(&server, modernRequest(1, method, ["name": "echo"], meta: meta))
            #expect(failure["code"] == -32022)
            #expect(failure["message"]?.stringValue?.hasPrefix("Unsupported protocol version.") == true)
            #expect(failure["data"] == [
                "supported": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"],
                "requested": .string(version),
            ])
        }
    }

    @Test func modernRequestsNeedClientCapabilities() throws {
        var server = makeServer()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
        for method in ["server/discover", "tools/list", "tools/call"] {
            #expect(try error(&server, modernRequest(1, method, meta: meta))["code"] == -32602)
        }
        let notAnObject: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": true,
        ]
        #expect(try error(&server, modernRequest(2, "tools/list", meta: notAnObject))["code"] == -32602)
    }

    @Test func modernFieldsWithoutAProtocolVersionAreRejected() throws {
        var server = makeServer()
        let meta: JSONValue = ["io.modelcontextprotocol/clientCapabilities": [:]]
        #expect(try error(&server, modernRequest(1, "tools/list", meta: meta))["code"] == -32602)
        let numericVersion: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": 20260728,
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        #expect(try error(&server, modernRequest(2, "tools/list", meta: numericVersion))["code"] == -32602)
        #expect(try error(&server, modernRequest(3, "tools/list", meta: "2026-07-28"))["code"] == -32602)
    }

    @Test func discoverNeedsTheModernMeta() throws {
        var server = makeServer()
        let failure = try error(&server, request(1, "server/discover"))
        #expect(failure["code"] == -32602)
        #expect(try error(&server, request(2, "server/discover", ["_meta": [:]]))["code"] == -32602)
    }

    @Test(arguments: ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"])
    func discoverIsNotPartOfLegacyRevisions(version: String) throws {
        var server = makeServer()
        let meta: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": .string(version),
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        let failure = try error(&server, modernRequest(1, "server/discover", meta: meta))
        #expect(failure["code"] == -32601)
        #expect(failure["message"]?.stringValue?.contains("2026-07-28") == true)
    }

    @Test func pingIsNotPartOfTheModernRevision() throws {
        var server = makeServer()
        #expect(try error(&server, modernRequest(1, "ping"))["code"] == -32601)
    }

    @Test func aLegacyVersionInMetaIsServedByThatRevision() throws {
        var server = makeServer()
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2025-03-26"]
        let call = try result(&server, modernRequest(1, "tools/call", ["name": "echo"], meta: meta))
        #expect(call["resultType"] == nil)
        #expect(call["structuredContent"] == nil)
        #expect(server.negotiatedRevision == nil)
    }
}

@Suite struct ToolCallTests {
    @Test func missingArgumentsCountAsAnEmptyObject() throws {
        var server = makeServer()
        let call = try result(&server, request(1, "tools/call", ["name": "echo"]))
        #expect(call["structuredContent"] == ["received": [:]])
        let withNull = try result(&server, request(2, "tools/call", ["name": "echo", "arguments": nil]))
        #expect(withNull["structuredContent"] == ["received": [:]])
    }

    @Test func numberLiteralsSurviveTheRoundTripUnchanged() throws {
        var server = makeServer()
        let line = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{"x":0.1,"big":1e400,"long":123456789012345678901234567890.5,"neg":-0}}}"#
        let output = try respond(&server, line)
        let echoed = #"{"received":{"x":0.1,"big":1e400,"long":123456789012345678901234567890.5,"neg":-0}}"#
        #expect(output.contains(#""structuredContent":"# + echoed))
        let response = try #require(try JSONReader.read(output).objectValue)
        #expect(response[path: ["result", "content", 0, "text"]] == .string(echoed))
        #expect(response[path: ["result", "structuredContent", "received", "x"]] == .number("0.1"))
        #expect(response[path: ["result", "structuredContent", "received", "big"]] == .number("1e400"))
    }

    @Test func aToolErrorWithDetailsBecomesAReadableFailedResult() throws {
        var server = makeServer()
        let call = try result(&server, request(1, "tools/call", ["name": "fail", "arguments": ["withDetails": true]]))
        #expect(call["isError"] == true)
        #expect(call["content"] == [[
            "type": "text",
            "text": "A tally named \"items\" already exists. Add to it only if you coordinate with whoever created it.\nDetails: {\"name\":\"items\",\"value\":3.5,\"count\":2}",
        ]])
        #expect(call["structuredContent"] == nil)
    }

    @Test func aToolErrorWithoutDetailsIsJustTheMessage() throws {
        var server = makeServer()
        let call = try result(&server, modernRequest(1, "tools/call", ["name": "fail"]))
        #expect(call.keys == ["resultType", "content", "isError", "_meta"])
        #expect(call["content"] == [["type": "text", "text": "Nothing to do."]])
        #expect(call["isError"] == true)
    }

    @Test func unknownToolsAreInvalidParams() throws {
        var server = makeServer()
        let failure = try error(&server, request(1, "tools/call", ["name": "nope"]))
        #expect(failure["code"] == -32602)
        #expect(failure["message"]?.stringValue?.hasPrefix("Unknown tool: nope.") == true)
        #expect(try error(&server, modernRequest(2, "tools/call", ["name": "nope"]))["code"] == -32602)
    }

    /// An agent with the old habit learns the new name from the error.
    @Test func aRenamedToolsOldNameGetsTheNewName() throws {
        var server = makeServer()
        let failure = try error(&server, request(1, "tools/call", ["name": "tally_list"]))
        #expect(failure["code"] == -32602)
        #expect(failure["message"] == "Unknown tool: tally_list. It was renamed to tallies_info in abakus 0.5.1. tools/list shows the available tools.")
        #expect(try error(&server, request(2, "tools/call", ["name": "nope"]))["message"] == "Unknown tool: nope. tools/list shows the available tools.")
    }

    @Test func malformedCallsAreInvalidParams() throws {
        var server = makeServer()
        #expect(try error(&server, request(1, "tools/call"))["code"] == -32602)
        #expect(try error(&server, request(2, "tools/call", ["name": 3]))["code"] == -32602)
        #expect(try error(&server, request(3, "tools/call", ["name": "echo", "arguments": [1, 2]]))["code"] == -32602)
        #expect(try error(&server, request(4, "tools/call", ["name": "echo", "arguments": "x=1"]))["code"] == -32602)
    }

    @Test func toolsListRejectsCursorsItNeverIssued() throws {
        var server = makeServer()
        #expect(try error(&server, request(1, "tools/list", ["cursor": "page2"]))["code"] == -32602)
        #expect(try result(&server, request(2, "tools/list", ["cursor": nil]))["tools"] != nil)
    }

    @Test func responsesNeverContainARawLineBreak() throws {
        var server = makeServer()
        let output = try respond(&server, request(1, "tools/call", [
            "name": "echo", "arguments": ["text": "line one\nline two\r\n\u{2028}end"],
        ]))
        #expect(!output.utf8.contains(0x0A))
        #expect(!output.utf8.contains(0x0D))
        let failure = try respond(&server, request(2, "tools/call", ["name": "fail", "arguments": ["withDetails": true]]))
        #expect(!failure.utf8.contains(0x0A))
    }
}

@Suite struct JSONRPCTests {
    @Test func idsAreEchoedExactly() throws {
        var server = makeServer()
        #expect(try send(&server, #"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#)?["id"] == "abc-1")
        let output = try respond(&server, #"{"jsonrpc":"2.0","id":1.50,"method":"ping"}"#)
        #expect(output == #"{"jsonrpc":"2.0","id":1.50,"result":{}}"#)
    }

    @Test func invalidJSONIsAParseErrorWithoutID() throws {
        var server = makeServer()
        for line in [#"{"jsonrpc":"2.0","id":1,"method":"ping""#, "not json", #"{"id":1,"id":2}"#, "[1,]"] {
            let response = try #require(try send(&server, line))
            #expect(response.keys == ["jsonrpc", "error"])
            #expect(response[path: ["error", "code"]] == -32700)
        }
    }

    @Test func invalidUTF8IsAParseError() throws {
        var server = makeServer()
        var bytes = Array(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"#.utf8)
        bytes += [0x22, 0xFF, 0x22, 0x7D, 0x7D]
        let output = try respond(&server, bytes)
        #expect(try JSONReader.read(output).objectValue?[path: ["error", "code"]] == -32700)
    }

    @Test func deepNestingIsAParseError() throws {
        var server = makeServer()
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"# + deep + "}}"
        #expect(try send(&server, line)?[path: ["error", "code"]] == -32700)
    }

    @Test func messagesThatAreNotObjectsAreInvalidRequests() throws {
        var server = makeServer()
        for line in ["42", #""ping""#, "null", "true"] {
            let response = try #require(try send(&server, line))
            #expect(response.keys == ["jsonrpc", "error"])
            #expect(response[path: ["error", "code"]] == -32600)
        }
    }

    @Test func malformedRequestObjects() throws {
        var server = makeServer()
        // Wrong or missing "jsonrpc": Invalid Request, with the id when it can be read.
        let noVersion = try #require(try send(&server, #"{"id":1,"method":"ping"}"#))
        #expect(noVersion["id"] == 1)
        #expect(noVersion[path: ["error", "code"]] == -32600)
        #expect(try send(&server, #"{"jsonrpc":"1.0","id":2,"method":"ping"}"#)?[path: ["error", "code"]] == -32600)
        #expect(try send(&server, #"{"jsonrpc":2.0,"id":3,"method":"ping"}"#)?[path: ["error", "code"]] == -32600)
        // Missing or non-string method.
        #expect(try send(&server, #"{"jsonrpc":"2.0","id":4}"#)?[path: ["error", "code"]] == -32600)
        #expect(try send(&server, #"{"jsonrpc":"2.0","id":5,"method":5}"#)?[path: ["error", "code"]] == -32600)
        // Ids MCP does not allow are not echoed.
        for id in ["null", "true", "[1]", #"{"a":1}"#] {
            let response = try #require(try send(&server, #"{"jsonrpc":"2.0","id":"# + id + #","method":"ping"}"#))
            #expect(response.keys == ["jsonrpc", "error"])
            #expect(response[path: ["error", "code"]] == -32600)
        }
        // Params must be an object.
        #expect(try send(&server, #"{"jsonrpc":"2.0","id":6,"method":"ping","params":[]}"#)?[path: ["error", "code"]] == -32602)
        #expect(try send(&server, #"{"jsonrpc":"2.0","id":7,"method":"ping","params":"x"}"#)?[path: ["error", "code"]] == -32600)
    }

    @Test func unknownMethodsAreMethodNotFound() throws {
        var server = makeServer()
        let failure = try error(&server, request(1, "resources/list"))
        #expect(failure["code"] == -32601)
        #expect(failure["message"]?.stringValue?.hasPrefix("Method not found: resources/list.") == true)
        #expect(try error(&server, modernRequest(2, "prompts/list"))["code"] == -32601)
        // A notification method sent as a request.
        #expect(try error(&server, request(3, "notifications/initialized"))["code"] == -32601)
    }

    @Test func notificationsNeverGetAResponse() {
        var server = makeServer()
        for line in [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/unknown"}"#,
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo"}}"#,
            #"{"jsonrpc":"2.0","method":"tools/call","params":[1]}"#,
            #"{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
        ] {
            #expect(server.handle(line: line) == nil, "\(line)")
        }
        #expect(server.negotiatedRevision == nil)
    }

    @Test func malformedNotificationsAreDroppedWithANote() {
        var notes: [String] = []
        var server = MCPServer(tools: [], context: testContext(), diagnostics: { notes.append($0) })
        let lines = [
            #"{"method":"tools/list"}"#,
            #"{"jsonrpc":"1.0","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","method":5}"#,
            #"{"jsonrpc":"2.0"}"#,
            #"{"foo":"bar"}"#,
            #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}"#,
        ]
        for line in lines {
            #expect(server.handle(line: line) == nil, "\(line)")
        }
        #expect(notes.count == lines.count)
    }

    @Test func clientSuppliedTextIsEscapedInDiagnostics() throws {
        var notes: [String] = []
        var server = MCPServer(tools: [], context: testContext(), diagnostics: { notes.append($0) })
        let name = "evil\nabakus: forged line\u{1B}[31m" + String(repeating: "x", count: 500)
        let initialize = request(1, "initialize", [
            "protocolVersion": "2025-11-25\nforged", "clientInfo": ["name": .string(name), "version": "1"],
        ])
        _ = try respond(&server, initialize)
        #expect(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/x\nforged"}"#) == nil)
        #expect(notes.count == 2)
        for note in notes {
            #expect(note.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }, "\(note)")
            #expect(note.count < 600, "\(note)")
        }
        #expect(notes[0].contains(#""evil\nabakus: forged line\u001b[31mxxx"#))
        #expect(notes[0].contains(#""2025-11-25\nforged""#))
        #expect(notes[1].contains(#""notifications/x\nforged""#))
    }

    @Test func responsesFromTheClientAreIgnored() {
        var notes: [String] = []
        var server = MCPServer(tools: [], context: testContext(), diagnostics: { notes.append($0) })
        #expect(server.handle(line: #"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
        #expect(server.handle(line: #"{"jsonrpc":"2.0","id":2,"error":{"code":-1,"message":"x"}}"#) == nil)
        #expect(notes.count == 2)
    }

    @Test func blankLinesAreIgnored() {
        var server = makeServer()
        #expect(server.handle(line: "") == nil)
        #expect(server.handle(line: " \t\r") == nil)
    }
}

@Suite struct BatchTests {
    @Test func batchesAreRejectedUnlessTheRevisionHasThem() throws {
        var server = makeServer()
        let batch = "[" + request(1, "ping") + "," + request(2, "tools/list") + "]"
        let response = try #require(try send(&server, batch))
        #expect(response.keys == ["jsonrpc", "error"])
        #expect(response[path: ["error", "code"]] == -32600)

        _ = try result(&server, initializeRequest(version: "2025-06-18"))
        #expect(try send(&server, batch)?[path: ["error", "code"]] == -32600)
    }

    @Test func batchesWorkInRevision20250326() throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: "2025-03-26"))
        let batch = "[" + [
            request(2, "ping"),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            request(3, "tools/call", ["name": "echo", "arguments": ["x": .number("0.1")]]),
            request(4, "no/such/method"),
            "42",
        ].joined(separator: ",") + "]"
        let output = try respond(&server, batch)
        #expect(!output.utf8.contains(0x0A))
        let responses = try #require(try JSONReader.read(output).arrayValue)
        #expect(responses.count == 4)
        #expect(responses[0] == ["jsonrpc": "2.0", "id": 2, "result": [:]])
        #expect(responses[1].objectValue?[path: ["result", "content", 0, "text"]] == #"{"received":{"x":0.1}}"#)
        #expect(responses[2].objectValue?[path: ["error", "code"]] == -32601)
        #expect(responses[3].objectValue?[path: ["error", "code"]] == -32600)
    }

    @Test func batchEdgeCases() throws {
        var server = makeServer()
        _ = try result(&server, initializeRequest(version: "2025-03-26"))
        #expect(try send(&server, "[]")?[path: ["error", "code"]] == -32600)
        #expect(server.handle(line: #"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
        let withInitialize = try respond(&server, "[" + initializeRequest(9, version: "2025-03-26") + "]")
        let responses = try #require(try JSONReader.read(withInitialize).arrayValue)
        #expect(responses.first?.objectValue?["id"] == 9)
        #expect(responses.first?.objectValue?[path: ["error", "code"]] == -32600)
    }
}
