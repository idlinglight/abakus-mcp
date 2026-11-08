import AbakusCore
import Foundation
import Testing

@Suite struct JSONObjectTests {
    @Test func keepsInsertionOrder() {
        var object: JSONObject = ["name": "items", "value": 3]
        object["count"] = 3
        #expect(object.keys == ["name", "value", "count"])
    }

    @Test func replacingKeepsPositionAndNilRemoves() {
        var object: JSONObject = ["a": 1, "b": 2, "c": 3]
        object["b"] = 20
        object["a"] = nil
        #expect(object.keys == ["b", "c"])
        #expect(object["b"] == 20)
    }

    @Test func equalityIgnoresOrder() {
        let one: JSONObject = ["a": 1, "b": "x"]
        let other: JSONObject = ["b": "x", "a": 1]
        #expect(one == other)
        #expect(one != ["a": 1])
    }
}

@Suite struct DecimalOutputTests {
    @Test(arguments: [
        ("2490123.5", "2490123.5"),
        ("1e30", "1000000000000000000000000000000"),
        ("1e-20", "0.00000000000000000001"),
        ("-0.5", "-0.5"),
    ])
    func plainNotation(input: String, expected: String) throws {
        let value = try #require(Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")))
        #expect(JSONValue.decimal(value) == .number(expected))
    }
}

@Suite struct StateDirectoryTests {
    @Test func environmentOverrides() throws {
        let url = try StateDirectory.resolve(environment: ["ABAKUS_STATE_DIR": "/some/where"])
        #expect(url.path == "/some/where")
    }

    @Test func defaultsToPerUserTemporaryFolder() throws {
        let url = try StateDirectory.resolve(environment: [:])
        #expect(url.lastPathComponent == "abakus")
        #expect(url.path.contains("/T/"))
    }
}
