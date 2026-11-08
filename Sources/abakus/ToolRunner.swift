import AbakusCore
import ArgumentParser
import Foundation

/// Runs a catalog tool for a CLI command: the same tool, arguments and result an MCP client gets.
enum ToolRunner {
    /// Prints the result as compact JSON on stdout. A `ToolError` becomes "Error: <message>" on stderr (plus its
    /// details as JSON) and exit status 1.
    static func run(_ name: String, _ arguments: JSONObject) throws {
        guard let tool = Catalog.tool(named: name) else {
            throw Failure("abakus has no tool named \(name). `abakus tools` lists the tools.")
        }
        let context: ToolContext
        do {
            context = try ToolContext.live()
        } catch {
            throw Failure(error)
        }
        do {
            print(JSONWriter.write(try tool.call(arguments, in: context)))
        } catch {
            throw Failure(error)
        }
    }

    /// ArgumentParser prints this as "Error: <description>" on stderr and exits with status 1.
    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ text: String) {
            description = text
        }

        init(_ error: ToolError) {
            if let details = error.details {
                description = "\(error.message)\nDetails: \(JSONWriter.write(details))"
            } else {
                description = error.message
            }
        }
    }

    /// Whitespace-separated words from stdin, for commands that take numbers from a pipe.
    static func wordsFromStandardInput() -> [String] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// `--decimal`, shared by every command that reads number strings.
struct DecimalOption: ParsableArguments {
    @Option(help: ArgumentHelp("The decimal mark in number strings: . (default) or ,", valueName: "mark"))
    var decimal: String?

    func apply(to arguments: inout JSONObject) {
        if let decimal {
            arguments["decimal"] = .string(decimal)
        }
    }
}
