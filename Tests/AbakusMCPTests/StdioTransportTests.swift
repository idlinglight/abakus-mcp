import AbakusCore
@testable import AbakusMCP
import Foundation
import Testing

/// Files in a fresh temporary folder stand in for stdin and stdout; reading a regular file ends at its end,
/// like a closed pipe.
struct ScratchFiles: ~Copyable {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("abakus-stdio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func input(_ bytes: [UInt8]) throws -> Int32 {
        let url = folder.appendingPathComponent("input-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        let descriptor = open(url.path, O_RDONLY)
        #expect(descriptor >= 0)
        return descriptor
    }

    func output() -> (descriptor: Int32, url: URL) {
        let url = folder.appendingPathComponent("output-\(UUID().uuidString)")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        #expect(descriptor >= 0)
        return (descriptor, url)
    }
}

@Suite struct LineReaderTests {
    func lines(_ text: String, maxLineLength: Int = 1024) throws -> [LineReader.Line] {
        let files = try ScratchFiles()
        let descriptor = try files.input(Array(text.utf8))
        defer { close(descriptor) }
        var reader = LineReader(fileDescriptor: descriptor, maxLineLength: maxLineLength)
        var result: [LineReader.Line] = []
        while let line = try reader.next() {
            result.append(line)
        }
        return result
    }

    @Test func splitsAtLineFeeds() throws {
        #expect(try lines("a\nb\r\n\nlast") == [
            .complete(Array("a".utf8)), .complete(Array("b\r".utf8)), .complete([]), .complete(Array("last".utf8)),
        ])
        #expect(try lines("one\n") == [.complete(Array("one".utf8))])
        #expect(try lines("") == [])
    }

    @Test func tooLongLinesAreDiscarded() throws {
        #expect(try lines("short\n0123456789abcdef\nok\n0123456789abcdef", maxLineLength: 8) == [
            .complete(Array("short".utf8)), .tooLong, .complete(Array("ok".utf8)), .tooLong,
        ])
        #expect(try lines("12345678\n", maxLineLength: 8) == [.complete(Array("12345678".utf8))])
    }

    @Test func nonBlockingInputWaitsForDataInsteadOfFailing() throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        let (readEnd, writeEnd) = (ends[0], ends[1])
        defer { close(readEnd) }
        #expect(fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK) == 0)
        // The first read finds the pipe empty (EAGAIN); the data arrives a little later.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            let bytes = Array("late\n".utf8)
            _ = bytes.withUnsafeBytes { write(writeEnd, $0.baseAddress, $0.count) }
            close(writeEnd)
        }
        var reader = LineReader(fileDescriptor: readEnd, maxLineLength: 1024)
        #expect(try reader.next() == .complete(Array("late".utf8)))
        #expect(try reader.next() == nil)
    }

    @Test func tooLongLinesSpanningManyReadsAreDiscarded() throws {
        let long = String(repeating: "x", count: 300_000)
        #expect(try lines("first\n" + long + "\nafter\n", maxLineLength: 100_000) == [
            .complete(Array("first".utf8)), .tooLong, .complete(Array("after".utf8)),
        ])
        // Lines longer than one read but within the limit arrive whole.
        let result = try lines(long + "\n", maxLineLength: 400_000)
        #expect(result == [.complete(Array(long.utf8))])
    }
}

@Suite struct ServeTests {
    @Test func servesUntilEndOfInput() throws {
        let files = try ScratchFiles()
        let input = [
            initializeRequest(version: "2025-06-18"),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            request(2, "tools/call", ["name": "echo", "arguments": ["x": .number("0.1")]]),
            "garbage",
            request(3, "ping"),
        ].joined(separator: "\n")
        let inputDescriptor = try files.input(Array(input.utf8))
        let (outputDescriptor, outputURL) = files.output()
        var server = makeServer()
        try server.serve(input: inputDescriptor, output: outputDescriptor)
        close(inputDescriptor)
        close(outputDescriptor)

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output.hasSuffix("\n"))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 4)
        let responses = try lines.map { try #require(try JSONReader.read(String($0)).objectValue) }
        #expect(responses[0][path: ["result", "protocolVersion"]] == "2025-06-18")
        #expect(responses[1][path: ["result", "structuredContent", "received", "x"]] == .number("0.1"))
        #expect(responses[2][path: ["error", "code"]] == -32700)
        #expect(responses[3] == ["jsonrpc": "2.0", "id": 3, "result": [:]])
    }

    @Test func aTooLongLineIsAnsweredWithAnError() throws {
        let files = try ScratchFiles()
        let input = request(1, "tools/call", ["name": "echo", "arguments": ["x": .string(String(repeating: "9", count: 500))]])
            + "\n" + request(2, "ping") + "\n"
        let inputDescriptor = try files.input(Array(input.utf8))
        let (outputDescriptor, outputURL) = files.output()
        var server = makeServer()
        try server.serve(input: inputDescriptor, output: outputDescriptor, maxLineLength: 200)
        close(inputDescriptor)
        close(outputDescriptor)

        let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try JSONReader.read(String(lines[0])).objectValue?[path: ["error", "code"]] == -32600)
        #expect(try JSONReader.read(String(lines[1])).objectValue?["id"] == 2)
    }

    @Test func stopsWhenOutputIsClosed() throws {
        // Without this, writing to a pipe without a reader would end the test process; `run` does the same.
        signal(SIGPIPE, SIG_IGN)
        let files = try ScratchFiles()
        let inputDescriptor = try files.input(Array((request(1, "ping") + "\n" + request(2, "ping") + "\n").utf8))
        defer { close(inputDescriptor) }
        var pipeEnds: [Int32] = [0, 0]
        #expect(pipe(&pipeEnds) == 0)
        close(pipeEnds[0])
        defer { close(pipeEnds[1]) }
        var notes: [String] = []
        var server = MCPServer(tools: [], context: testContext(), diagnostics: { notes.append($0) })
        try server.serve(input: inputDescriptor, output: pipeEnds[1])
        #expect(notes.contains { $0.contains("stopping") })
    }
}
