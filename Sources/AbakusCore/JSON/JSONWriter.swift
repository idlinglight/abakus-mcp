/// Writes a `JSONValue` as compact JSON text: no whitespace between tokens, object keys in their stored order.
///
/// The output never contains a line break: every control character is escaped (`\n`, `\t`, `\u0001`, ...),
/// and so are DEL, the C1 controls and U+2028/U+2029, which some readers treat as line ends. The MCP stdio
/// transport frames one message per line and depends on that. Other characters are written as UTF-8.
///
/// Number literals are written as their text, unchanged. A `.number` whose text is not a JSON number literal
/// breaks the `JSONValue` contract; it is written as a JSON string instead, so the output stays valid JSON.
public enum JSONWriter {
    public static func write(_ value: JSONValue) -> String {
        var output = ""
        append(value, to: &output)
        return output
    }

    public static func write(_ object: JSONObject) -> String {
        write(.object(object))
    }

    private static func append(_ value: JSONValue, to output: inout String) {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let literal):
            if JSONReader.isNumberLiteral(literal) {
                output += literal
            } else {
                appendString(literal, to: &output)
            }
        case .string(let text):
            appendString(text, to: &output)
        case .array(let elements):
            output += "["
            for (position, element) in elements.enumerated() {
                if position > 0 { output += "," }
                append(element, to: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (position, entry) in object.entries.enumerated() {
                if position > 0 { output += "," }
                appendString(entry.key, to: &output)
                output += ":"
                append(entry.value, to: &output)
            }
            output += "}"
        }
    }

    private static func appendString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{00}"..."\u{1F}", "\u{7F}"..."\u{9F}", "\u{2028}", "\u{2029}":
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
