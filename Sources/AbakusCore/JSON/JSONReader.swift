/// Reads JSON text into a `JSONValue`, strictly by RFC 8259.
///
/// - Number literals are checked against the JSON grammar and kept as their text (ADR-0005): `0.1` becomes
///   `.number("0.1")`, `1e400` stays `.number("1e400")`. No binary floating point is involved.
/// - Strings: all escapes, including surrogate pairs (`\ud83d\ude00`). A lone surrogate, an unescaped control
///   character or invalid UTF-8 is an error.
/// - Duplicate keys in one object are an error. RFC 8259 leaves their meaning open, and readers disagree (first
///   wins, last wins), so accepting them would let two programs read different values from the same text.
///   Keys count as duplicates when Swift's `String` equality says so, which is also how `JSONObject` looks
///   them up.
/// - Arrays and objects may nest at most `maxDepth` levels, so hostile input cannot exhaust the stack.
/// - Only the four JSON whitespace characters are allowed between tokens; a byte order mark is an error.
public enum JSONReader {
    public static let defaultMaxDepth = 64

    public static func read(_ text: String, maxDepth: Int = defaultMaxDepth) throws(JSONReadError) -> JSONValue {
        try read(Array(text.utf8), maxDepth: maxDepth)
    }

    /// Reads UTF-8 encoded JSON text.
    public static func read(_ bytes: [UInt8], maxDepth: Int = defaultMaxDepth) throws(JSONReadError) -> JSONValue {
        var parser = Parser(bytes: bytes, maxDepth: maxDepth)
        return try parser.document()
    }

    /// Whether `text` is a JSON number literal, e.g. `-0.5` or `2.5e3`, but not `01`, `.5`, `1.` or `+1`.
    /// Works on the string's UTF-8 view directly and allocates nothing.
    public static func isNumberLiteral(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard case .end(let end) = scanNumber(utf8, from: utf8.startIndex) else { return false }
        return end == utf8.endIndex
    }

    /// The whitespace JSON allows between tokens: space, tab, line feed, carriage return.
    package static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    enum NumberScan<Index> {
        /// A complete literal ends before this index.
        case end(Index)
        /// The byte at this index (or the end of input) breaks the grammar.
        case failure(NumberGrammarError, Index)
    }

    enum NumberGrammarError {
        case missingDigit(where: String)
        case leadingZero

        func reason(found: String) -> String {
            switch self {
            case .missingDigit(let place): "expected a digit \(place), found \(found)"
            case .leadingZero: "a number must not start with 0 followed by more digits"
            }
        }
    }

    /// Scans the JSON number grammar, `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`, starting at `start`.
    /// The one implementation of the grammar, for the reader and for `isNumberLiteral`.
    static func scanNumber<Bytes: Collection<UInt8>>(_ bytes: Bytes, from start: Bytes.Index) -> NumberScan<Bytes.Index> {
        var index = start
        func current() -> UInt8? { index < bytes.endIndex ? bytes[index] : nil }
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } ?? false }
        func skipDigits() { while isDigit(current()) { bytes.formIndex(after: &index) } }

        if current() == UInt8(ascii: "-") { bytes.formIndex(after: &index) }
        guard let first = current(), isDigit(first) else { return .failure(.missingDigit(where: "in a number"), index) }
        bytes.formIndex(after: &index)
        if first == UInt8(ascii: "0") {
            if isDigit(current()) { return .failure(.leadingZero, index) }
        } else {
            skipDigits()
        }
        if current() == UInt8(ascii: ".") {
            bytes.formIndex(after: &index)
            guard isDigit(current()) else { return .failure(.missingDigit(where: "after the decimal point"), index) }
            skipDigits()
        }
        if current() == UInt8(ascii: "e") || current() == UInt8(ascii: "E") {
            bytes.formIndex(after: &index)
            if current() == UInt8(ascii: "+") || current() == UInt8(ascii: "-") { bytes.formIndex(after: &index) }
            guard isDigit(current()) else { return .failure(.missingDigit(where: "in the exponent"), index) }
            skipDigits()
        }
        return .end(index)
    }
}

/// Why JSON text could not be read, and where.
public struct JSONReadError: Error, Sendable, Equatable, CustomStringConvertible {
    /// What is wrong, e.g. `duplicate key "name"`.
    public var reason: String
    /// The byte offset in the input at which the problem was found.
    public var offset: Int

    public init(reason: String, offset: Int) {
        self.reason = reason
        self.offset = offset
    }

    public var description: String { "\(reason) at byte \(offset)" }
}

private struct Parser {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0
    var depth = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    var atEnd: Bool { index >= bytes.count }

    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    func failure(_ reason: String, at offset: Int? = nil) -> JSONReadError {
        JSONReadError(reason: reason, offset: offset ?? index)
    }

    /// Names the byte at the current position for an error message.
    var found: String {
        guard let byte = current else { return "end of input" }
        if byte >= 0x21, byte <= 0x7E { return "\"\(Character(Unicode.Scalar(byte)))\"" }
        let hex = String(byte, radix: 16, uppercase: true)
        return "byte 0x\(hex.count == 1 ? "0" + hex : hex)"
    }

    mutating func document() throws(JSONReadError) -> JSONValue {
        skipWhitespace()
        let result = try value()
        skipWhitespace()
        guard atEnd else { throw failure("unexpected \(found) after the JSON value") }
        return result
    }

    mutating func skipWhitespace() {
        while let byte = current, JSONReader.isWhitespace(byte) {
            index += 1
        }
    }

    mutating func value() throws(JSONReadError) -> JSONValue {
        guard let byte = current else { throw failure("expected a JSON value, found end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw failure("expected a JSON value, found \(found)")
        }
    }

    mutating func literal(_ word: String) throws(JSONReadError) {
        let start = index
        for byte in word.utf8 {
            guard current == byte else { throw failure("invalid literal, expected \(word)", at: start) }
            index += 1
        }
    }

    mutating func enterContainer() throws(JSONReadError) {
        depth += 1
        guard depth <= maxDepth else { throw failure("arrays and objects nest deeper than \(maxDepth) levels") }
    }

    mutating func object() throws(JSONReadError) -> JSONValue {
        try enterContainer()
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            depth -= 1
            return .object(JSONObject())
        }
        var entries: [(key: String, value: JSONValue)] = []
        var seen = Set<String>()
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw failure("expected a string as object key, found \(found)") }
            let keyOffset = index
            let key = try string()
            guard seen.insert(key).inserted else { throw failure("duplicate key \"\(key)\"", at: keyOffset) }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw failure("expected \":\" after an object key, found \(found)") }
            index += 1
            skipWhitespace()
            entries.append((key, try value()))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                depth -= 1
                return .object(JSONObject(uniqueEntries: entries))
            default:
                throw failure("expected \",\" or \"}\" in an object, found \(found)")
            }
        }
    }

    mutating func array() throws(JSONReadError) -> JSONValue {
        try enterContainer()
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            depth -= 1
            return .array([])
        }
        var elements: [JSONValue] = []
        while true {
            skipWhitespace()
            elements.append(try value())
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                depth -= 1
                return .array(elements)
            default:
                throw failure("expected \",\" or \"]\" in an array, found \(found)")
            }
        }
    }

    mutating func string() throws(JSONReadError) -> String {
        let start = index
        index += 1
        var utf8: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("unterminated string", at: start) }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let text = String(validating: utf8, as: UTF8.self) else {
                    throw failure("string is not valid UTF-8", at: start)
                }
                return text
            case UInt8(ascii: "\\"):
                try escape(into: &utf8)
            case 0x00..<0x20:
                throw failure("control character \(found) in a string must be escaped")
            default:
                utf8.append(byte)
                index += 1
            }
        }
    }

    mutating func escape(into utf8: inout [UInt8]) throws(JSONReadError) {
        let start = index
        index += 1
        guard let byte = current else { throw failure("unterminated escape sequence", at: start) }
        index += 1
        switch byte {
        case UInt8(ascii: "\""): utf8.append(0x22)
        case UInt8(ascii: "\\"): utf8.append(0x5C)
        case UInt8(ascii: "/"): utf8.append(0x2F)
        case UInt8(ascii: "b"): utf8.append(0x08)
        case UInt8(ascii: "f"): utf8.append(0x0C)
        case UInt8(ascii: "n"): utf8.append(0x0A)
        case UInt8(ascii: "r"): utf8.append(0x0D)
        case UInt8(ascii: "t"): utf8.append(0x09)
        case UInt8(ascii: "u"):
            let unit = try hex4()
            let value: UInt32
            switch unit {
            case 0xD800...0xDBFF:
                guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                    throw failure("high surrogate \\u\(hex(unit)) is not followed by a low surrogate", at: start)
                }
                index += 2
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw failure("high surrogate \\u\(hex(unit)) is not followed by a low surrogate", at: start)
                }
                value = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            case 0xDC00...0xDFFF:
                throw failure("low surrogate \\u\(hex(unit)) without a high surrogate before it", at: start)
            default:
                value = unit
            }
            // Every value outside the surrogate range is a Unicode scalar.
            UTF8.encode(Unicode.Scalar(value)!) { utf8.append($0) }
        default:
            index -= 1
            throw failure("invalid escape sequence: backslash followed by \(found)", at: start)
        }
    }

    mutating func hex4() throws(JSONReadError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw failure("\\u needs four hex digits, found end of input") }
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure("\\u needs four hex digits, found \(found)")
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    func hex(_ unit: UInt32) -> String {
        String(unit, radix: 16, uppercase: true)
    }

    /// Scans a number literal at the current position and returns its text unchanged.
    mutating func number() throws(JSONReadError) -> String {
        let start = index
        switch JSONReader.scanNumber(bytes, from: start) {
        case .end(let end):
            index = end
            return String(decoding: bytes[start..<end], as: UTF8.self)
        case .failure(let error, let position):
            index = position
            throw failure(error.reason(found: found))
        }
    }
}
