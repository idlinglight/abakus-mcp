import AbakusCore
import Testing

@Suite struct JSONReaderTests {
    @Test func literals() throws {
        #expect(try JSONReader.read("true") == .bool(true))
        #expect(try JSONReader.read("false") == .bool(false))
        #expect(try JSONReader.read("null") == .null)
        #expect(try JSONReader.read(" \t\r\n null \n") == .null)
    }

    @Test(arguments: [
        "0", "-0", "7", "-12", "0.1", "0.30000000000000004", "1e400", "1E+2", "-2.5e-3", "10.0",
        "123456789012345678901234567890.123456789",
    ])
    func numbersKeepTheirText(literal: String) throws {
        #expect(try JSONReader.read(literal) == .number(literal))
        #expect(JSONReader.isNumberLiteral(literal))
    }

    @Test(arguments: [
        "01", "-01", "1.", ".5", "+1", "1e", "1e+", "-", "0x10", "NaN", "Infinity", "-Infinity", "1.e3", "--1",
        "1,5", "1 000", "١",
    ])
    func invalidNumbers(text: String) {
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
        #expect(!JSONReader.isNumberLiteral(text))
    }

    @Test func numberLiteralCheckRejectsSurroundingText() {
        #expect(!JSONReader.isNumberLiteral(""))
        #expect(!JSONReader.isNumberLiteral(" 1"))
        #expect(!JSONReader.isNumberLiteral("1 "))
        #expect(!JSONReader.isNumberLiteral("\"1\""))
    }

    @Test func stringEscapes() throws {
        let text = #""a\"b\\c\/d\b\f\n\r\tAé€\u0000""#
        #expect(try JSONReader.read(text) == .string("a\"b\\c/d\u{08}\u{0C}\n\r\tAé€\u{00}"))
    }

    @Test func surrogatePairs() throws {
        #expect(try JSONReader.read(#""😀""#) == .string("😀"))
        #expect(try JSONReader.read(#""x𝄞y""#) == .string("x𝄞y"))
    }

    @Test(arguments: [
        #""\ud83d""#, #""\ud83dx""#, #""\ud83dA""#, #""\ude00""#, #""\ude00\ud83d""#, #""\ud83d\n""#,
    ])
    func loneSurrogatesAreRejected(text: String) {
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
    }

    @Test(arguments: [
        #""\x""#, #""\u12""#, #""\u12G4""#, #""\'""#, #""abc"#, #""abc\"#,
    ])
    func malformedStrings(text: String) {
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
    }

    @Test func rawControlCharactersInStringsAreRejected() {
        #expect(throws: JSONReadError.self) { try JSONReader.read("\"a\nb\"") }
        #expect(throws: JSONReadError.self) { try JSONReader.read("\"a\tb\"") }
        #expect(throws: JSONReadError.self) { try JSONReader.read("\"a\u{00}b\"") }
    }

    @Test func rawUTF8IsKept() throws {
        #expect(try JSONReader.read("\"Grüße, 世界 😀\"") == .string("Grüße, 世界 😀"))
        // DEL and U+2028 need no escape in JSON.
        #expect(try JSONReader.read("\"a\u{7F}\u{2028}b\"") == .string("a\u{7F}\u{2028}b"))
    }

    @Test(arguments: [
        [0x22, 0xC3, 0x22] as [UInt8], // truncated two-byte sequence
        [0x22, 0xFF, 0x22], // never valid in UTF-8
        [0x22, 0xC0, 0xAF, 0x22], // overlong "/"
        [0x22, 0xED, 0xA0, 0x80, 0x22], // a surrogate encoded as UTF-8
    ])
    func invalidUTF8IsRejected(bytes: [UInt8]) {
        #expect(throws: JSONReadError.self) { try JSONReader.read(bytes) }
    }

    @Test func objectsKeepKeyOrder() throws {
        let value = try JSONReader.read(#"{"z": 1, "a": [true, null], "m": {"k": "v"}}"#)
        let object = try #require(value.objectValue)
        #expect(object.keys == ["z", "a", "m"])
        #expect(object["a"] == [true, nil])
        #expect(object["m"] == ["k": "v"])
    }

    @Test func emptyContainers() throws {
        #expect(try JSONReader.read("{}") == .object(JSONObject()))
        #expect(try JSONReader.read("[ ]") == .array([]))
        #expect(try JSONReader.read("[[],{}]") == [[], .object(JSONObject())])
    }

    @Test func duplicateKeysAreRejected() {
        #expect(throws: JSONReadError(reason: "duplicate key \"a\"", offset: 9)) {
            try JSONReader.read(#"{"a": 1, "a": 2}"#)
        }
        // Escaped and raw spellings of the same key are the same key.
        #expect(throws: JSONReadError.self) { try JSONReader.read(#"{"é": 1, "é": 2}"#) }
        // The same key in different objects is fine.
        #expect(throws: Never.self) { try JSONReader.read(#"{"a": {"a": 1}, "b": {"a": 2}}"#) }
    }

    @Test(arguments: [
        "", " ", "[1,]", "[,1]", "[1 2]", "{\"a\":1,}", "{\"a\" 1}", "{a:1}", "{'a':1}", "{\"a\":}", "[1", "{",
        "1 2", "true false", "nul", "True", "[1]]", "\u{FEFF}{}", "\u{00A0}1", "\u{0C}1", "// x\n1",
    ])
    func malformedDocuments(text: String) {
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
    }

    @Test func largeObjectsReadInLinearTime() throws {
        let count = 100_000
        let text = "{" + (0..<count).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
        var value: JSONValue = nil
        let elapsed = try ContinuousClock().measure { value = try JSONReader.read(text) }
        let object = try #require(value.objectValue)
        #expect(object.count == count)
        #expect(object.keys.first == "k0")
        #expect(object.keys.last == "k99999")
        #expect(object["k99999"] == 99999)
        // Quadratic object building took minutes for this input.
        #expect(elapsed < .seconds(5), "reading took \(elapsed)")
    }

    @Test func whitespaceIsTheFourJSONCharacters() {
        let whitespace = (UInt8.min...UInt8.max).filter(JSONReader.isWhitespace)
        #expect(whitespace == [0x09, 0x0A, 0x0D, 0x20])
    }

    @Test func nestingUpToTheLimitIsAccepted() throws {
        let depth = JSONReader.defaultMaxDepth
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(throws: Never.self) { try JSONReader.read(text) }
        let objects = String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
        #expect(throws: Never.self) { try JSONReader.read(objects) }
    }

    @Test func nestingPastTheLimitIsRejected() {
        let depth = JSONReader.defaultMaxDepth + 1
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
        #expect(throws: Never.self) { try JSONReader.read(text, maxDepth: depth) }
    }

    @Test func hostileNestingFailsWithoutExhaustingTheStack() {
        let text = String(repeating: "[", count: 1_000_000)
        #expect(throws: JSONReadError.self) { try JSONReader.read(text) }
    }

    @Test func errorsSayWhatAndWhere() {
        #expect(throws: JSONReadError(reason: "expected \",\" or \"]\" in an array, found \"}\"", offset: 2)) {
            try JSONReader.read("[1}")
        }
        #expect(throws: JSONReadError(reason: "unexpected \"x\" after the JSON value", offset: 5)) {
            try JSONReader.read("true x")
        }
        let error = JSONReadError(reason: "unterminated string", offset: 3)
        #expect(error.description == "unterminated string at byte 3")
    }
}
