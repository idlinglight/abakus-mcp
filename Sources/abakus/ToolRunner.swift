import AbakusCore
import ArgumentParser
import Foundation

/// Runs a catalog tool for a CLI command: the same tool and arguments as over MCP, and the full result, with the
/// detail keys an MCP result leaves out (ADR-0008).
///
/// Exit status: 0 with the result on stdout; 1 for a tool error ("Error: <message>" on stderr, the same text an
/// agent reads); 64 for a usage mistake, with the command's usage.
enum ToolRunner {
    static func run(_ name: String, _ arguments: JSONObject) throws {
        let tool = try tool(named: name)
        let context: ToolContext
        do {
            context = try ToolContext.live()
        } catch {
            throw Failure(error.text)
        }
        do {
            print(JSONWriter.write(try tool.call(arguments, in: context)))
        } catch {
            throw Failure(error.text)
        }
    }

    static func tool(named name: String) throws -> any Tool {
        guard let tool = Catalog.tool(named: name) else {
            throw Failure("abakus has no tool named \(name). `abakus tools` lists the tools.")
        }
        return tool
    }

    /// ArgumentParser prints this as "Error: <description>" on stderr and exits with status 1.
    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ text: String) {
            description = text
        }
    }

    /// The words of an argument list that captures negative numbers (`parsing: .allUnrecognized`), which also
    /// captures what ArgumentParser would otherwise reject: a `--` terminator is dropped, and before it a word
    /// that looks like an option rather than a negative number is a usage mistake.
    static func numberWords(_ words: [String]) throws -> [String] {
        var result: [String] = []
        var terminated = false
        for word in words {
            if !terminated, word == "--" {
                terminated = true
                continue
            }
            if !terminated, word.hasPrefix("-"), word.count > 1 {
                let next = word[word.index(after: word.startIndex)]
                if !(next.isASCII && (next.isNumber || next == ".")) {
                    throw ValidationError("Unknown option '\(word)'. Negative numbers like -5 are fine; see --help for the options.")
                }
            }
            result.append(word)
        }
        return result
    }

    /// Whitespace-separated words from stdin, for commands that take numbers from a pipe. A terminal on stdin is
    /// a usage mistake: nobody is going to type the numbers and press ctrl-D.
    static func wordsFromStandardInput(command: String) throws -> [String] {
        if isatty(STDIN_FILENO) != 0 {
            throw ValidationError("Give the numbers as arguments, or pipe them in: printf '1\\n2\\n' | abakus \(command)")
        }
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
