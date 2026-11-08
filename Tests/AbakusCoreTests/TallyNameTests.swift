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
        #expect(error.message.contains("at most 59 characters"))
        #expect(throws: Never.self) { try TallyName.validate(longest + "x") }
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
