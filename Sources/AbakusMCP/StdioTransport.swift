import AbakusCore
import Foundation

extension MCPServer {
    /// The longest message accepted, in bytes. A longer line is discarded and answered with an error.
    public static let maxLineLength = 16 * 1024 * 1024

    /// Serves `tools` on stdin and stdout until stdin closes. Diagnostics go to stderr.
    public static func run(tools: [any Tool], context: ToolContext) throws {
        // When the client goes away, writing to stdout fails with EPIPE instead of killing the process.
        signal(SIGPIPE, SIG_IGN)
        var server = MCPServer(tools: tools, context: context, diagnostics: { message in
            _ = writeAll(Array("\(AbakusInfo.name): \(message)\n".utf8), to: STDERR_FILENO)
        })
        try server.serve(input: STDIN_FILENO, output: STDOUT_FILENO)
    }

    /// Reads newline-delimited messages from `input` until end of input and writes each response as one line
    /// to `output`. Every line goes out in its own `write` calls, so nothing waits in a buffer. Returns at end of
    /// input, or early when `output` no longer accepts data.
    public mutating func serve(input: Int32, output: Int32, maxLineLength: Int = MCPServer.maxLineLength) throws(StdioError) {
        var reader = LineReader(fileDescriptor: input, maxLineLength: maxLineLength)
        while let line = try reader.next() {
            let response: String?
            switch line {
            case .complete(let bytes):
                response = handle(line: bytes)
            case .tooLong:
                response = JSONWriter.write(RPCResponse.error(id: nil, .invalidRequest(
                    "The message is longer than \(maxLineLength) bytes and was discarded."
                )))
            }
            guard let response else { continue }
            guard writeAll(Array(response.utf8) + [0x0A], to: output) else {
                diagnose("stdout no longer accepts data; stopping.")
                return
            }
        }
    }
}

/// Reading the input failed.
public struct StdioError: Error, Sendable, CustomStringConvertible {
    public var description: String
}

/// Splits a byte stream into lines at "\n" (without the "\n"). A last line without a line break still counts.
struct LineReader {
    enum Line: Equatable {
        case complete([UInt8])
        /// A line longer than the limit. Its bytes were dropped as they arrived.
        case tooLong
    }

    let fileDescriptor: Int32
    let maxLineLength: Int
    private var buffer: [UInt8] = []
    /// Where the current line starts in `buffer`.
    private var lineStart = 0
    /// How far `buffer` has been searched for "\n".
    private var searched = 0
    /// Set while the rest of a too long line is being dropped.
    private var discarding = false
    private var endOfInput = false

    init(fileDescriptor: Int32, maxLineLength: Int) {
        self.fileDescriptor = fileDescriptor
        self.maxLineLength = maxLineLength
    }

    mutating func next() throws(StdioError) -> Line? {
        while true {
            if let newline = buffer[searched...].firstIndex(of: 0x0A) {
                let start = lineStart
                lineStart = newline + 1
                searched = lineStart
                if discarding || newline - start > maxLineLength {
                    discarding = false
                    return .tooLong
                }
                return .complete(Array(buffer[start..<newline]))
            }
            searched = buffer.count
            if discarding || buffer.count - lineStart > maxLineLength {
                discarding = true
                buffer.removeAll(keepingCapacity: true)
                lineStart = 0
                searched = 0
            }
            if endOfInput {
                if discarding {
                    discarding = false
                    return .tooLong
                }
                guard lineStart < buffer.count else { return nil }
                let line = Array(buffer[lineStart...])
                lineStart = buffer.count
                searched = buffer.count
                return .complete(line)
            }
            if lineStart > 0 {
                buffer.removeFirst(lineStart)
                searched -= lineStart
                lineStart = 0
            }
            try fill()
        }
    }

    private mutating func fill() throws(StdioError) {
        let descriptor = fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
                return
            }
            if count == 0 {
                endOfInput = true
                return
            }
            if errno == EINTR { continue }
            throw StdioError(description: "Reading the input failed: \(String(cString: strerror(errno))).")
        }
    }
}

/// Writes all of `bytes`, continuing after partial writes and interruptions. Returns false when the file
/// descriptor refuses the data, e.g. because the reading end of a pipe has been closed.
func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes[offset...].withUnsafeBytes { Darwin.write(fileDescriptor, $0.baseAddress, $0.count) }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}
