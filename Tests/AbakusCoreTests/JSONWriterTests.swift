import AbakusCore
import Testing

@Suite struct JSONWriterTests {
    @Test func compactAndInKeyOrder() {
        let value: JSONValue = ["name": "items", "value": .number("0.1"), "tags": ["a", nil, true, false], "empty": [:]]
        #expect(JSONWriter.write(value) == #"{"name":"items","value":0.1,"tags":["a",null,true,false],"empty":{}}"#)
    }

    @Test func objectOverload() {
        let object: JSONObject = ["b": 1, "a": 2]
        #expect(JSONWriter.write(object) == #"{"b":1,"a":2}"#)
    }

    @Test func numberLiteralsAreWrittenUnchanged() {
        for literal in ["0.1", "-0", "1e400", "2.50", "123456789012345678901234567890"] {
            #expect(JSONWriter.write(.number(literal)) == literal)
        }
    }

    @Test func anInvalidNumberLiteralBecomesAString() {
        #expect(JSONWriter.write(.number("NaN")) == #""NaN""#)
        #expect(JSONWriter.write(.number("1,5")) == #""1,5""#)
    }

    @Test func escapes() {
        let text = "quote \" backslash \\ slash / newline \n return \r tab \t bs \u{08} ff \u{0C} nul \u{00} us \u{1F}"
        #expect(JSONWriter.write(.string(text)) ==
            #""quote \" backslash \\ slash / newline \n return \r tab \t bs \b ff \f nul \u0000 us \u001f""#)
    }

    @Test func lineSeparatorsAndControlsAreEscapedAndOtherTextIsRaw() {
        let escape = "\\u"
        let expected = "\"a\(escape)2028b\(escape)2029c\(escape)007fd\(escape)0085e\""
        #expect(JSONWriter.write(.string("a\u{2028}b\u{2029}c\u{7F}d\u{85}e")) == expected)
        #expect(JSONWriter.write(.string("Grüße 世界 😀")) == "\"Grüße 世界 😀\"")
        #expect(JSONWriter.write(.string("\r\n")) == #""\r\n""#)
    }

    @Test func keysAreEscapedToo() {
        let object = JSONObject([("line\nbreak", .null)])
        #expect(JSONWriter.write(object) == #"{"line\nbreak":null}"#)
    }

    @Test func outputNeverContainsALineBreak() {
        var allControls = ""
        for value in 0..<0x20 { allControls.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        let value: JSONValue = [.string(allControls), ["k\r\n": .string("\u{2028}\u{2029}\u{85}")]]
        let output = JSONWriter.write(value)
        #expect(!output.utf8.contains(0x0A))
        #expect(!output.utf8.contains(0x0D))
        #expect(output.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) })
    }

    @Test func roundTrip() throws {
        let value: JSONValue = [
            "text": "tab\t, quote \", emoji 😀, nul \u{00}",
            "numbers": [.number("0.1"), .number("-2.5e-3"), .number("1e400"), 7],
            "nested": ["deeper": [["x": nil]]],
            "flags": [true, false],
        ]
        #expect(try JSONReader.read(JSONWriter.write(value)) == value)
        let compact = #"{"a":[1,2.50,{"b":"\u0001\n"}],"c":null,"d":-0}"#
        #expect(JSONWriter.write(try JSONReader.read(compact)) == compact)
    }
}
