@testable import AbakusCore
import Testing

@Suite struct TallyNameTests {
    @Test(arguments: ["items", "a", "9", "review.items_2026-11-08", String(repeating: "x", count: 64)])
    func validNames(name: String) {
        #expect(TallyName.isValid(name))
        #expect(throws: Never.self) { try TallyName.validate(name) }
    }

    @Test(arguments: [
        "", "Items", "-items", ".items", "_items", "my items", "items/2", "zähler", "e\u{301}",
        String(repeating: "x", count: 65),
    ])
    func invalidNames(name: String) {
        #expect(!TallyName.isValid(name))
        #expect(throws: ToolError.self) { try TallyName.validate(name) }
    }

    @Test func errorStatesTheRuleAndSuggestsAName() throws {
        let error = try #require(throws: ToolError.self) { try TallyName.validate("My Items") }
        #expect(error.message.contains("lowercase letters"))
        #expect(error.message.contains("\"my-items\""))
        #expect(error.details?["suggestion"] == "my-items")
    }

    /// A long invalid name is quoted cut in the middle; the suggestion has at most 64 characters anyway (ADR-0008).
    @Test func errorCutsALongName() throws {
        let name = "My " + String(repeating: "X", count: 5000)
        let error = try #require(throws: ToolError.self) { try TallyName.validate(name) }
        #expect(error.text.count < 1000)
        #expect(error.message.hasPrefix("\"My XXX"))
        #expect(error.message.contains("…"))
        #expect(error.details?["name"]?.stringValue?.count == 100)
    }

    @Test func suggestions() {
        #expect(TallyName.suggestion(for: "Items") == "items")
        #expect(TallyName.suggestion(for: "--Review Items!") == "review-items-")
        #expect(TallyName.suggestion(for: "!!!") == nil)
        #expect(TallyName.suggestion(for: String(repeating: "A", count: 70)) == String(repeating: "a", count: 64))
    }

    @Test func aSuffixedNameNeedsRoomForTheSuffix() throws {
        let longest = String(repeating: "x", count: 59)
        #expect(throws: Never.self) { try TallyName.validate(longest, suffixed: true) }
        let error = try #require(throws: ToolError.self) { try TallyName.validate(longest + "x", suffixed: true) }
        #expect(error.message == """
            "\(longest)x" has 60 characters, too many for tally_create: it appends a dash and a random suffix, 5 \
            characters like "-k3f9", and a tally name has at most 64, so the name given may have at most 59. Try \
            "\(longest)".
            """)
        #expect(error.details?["suggestion"] == .string(longest))
        // The way out is a shorter name, not shared: true, which would share the tally with other sessions.
        #expect(!error.message.contains("shared"))
        #expect(throws: Never.self) { try TallyName.validate(longest + "x") }
    }

    /// Cut to 59 characters, without a separator left dangling before the suffix.
    @Test func shortenedNamesFitAndEndInALetterOrDigit() throws {
        let base = String(repeating: "a", count: 56)
        #expect(TallyName.shortened(base + "bcdefgh") == base + "bcd")
        #expect(TallyName.shortened(base + "b-._cd") == base + "b")
        #expect(TallyName.shortened(base + "b.-") == base + "b")
        let error = try #require(throws: ToolError.self) { try TallyName.validate(base + "bc_-x-y", suffixed: true) }
        #expect(error.details?["suggestion"] == .string(base + "bc"))
        #expect(throws: Never.self) { try TallyName.validate(base + "bc", suffixed: true) }
    }

    @Test func suffixedRetriesWhenTheSuffixIsTaken() throws {
        var suffixes = ["k3f9", "k3f9", "a1b2"].makeIterator()
        let name = try TallyName.suffixed("items", isTaken: { $0 == "items-k3f9" }, suffix: { suffixes.next()! })
        #expect(name == "items-a1b2")
    }

    @Test func suffixedGivesUpAfterManyCollisions() {
        #expect(throws: ToolError.self) {
            try TallyName.suffixed("items", isTaken: { _ in true }, suffix: { "aaaa" })
        }
    }

    @Test func randomSuffixesAreFourLowercaseLettersOrDigits() {
        for _ in 0..<200 {
            let suffix = TallyName.randomSuffix()
            #expect(suffix.wholeMatch(of: /[a-z0-9]{4}/) != nil)
        }
    }
}
