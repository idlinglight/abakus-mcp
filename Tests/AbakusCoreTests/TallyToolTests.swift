@testable import AbakusCore
import Foundation
import Testing

@Suite struct TallyCreateTests {
    @Test func returnsTheNewTallysState() throws {
        let state = TallyTestState()
        let response = try state.call("tally_create", ["name": "items"])
        #expect(response.keys == ["name", "value", "count", "thresholds", "created", "updated"])
        #expect(response == [
            "name": "items", "value": 0, "count": 0, "thresholds": [],
            "created": "2026-11-08T09:30:00Z", "updated": "2026-11-08T09:30:00Z",
        ])
    }

    @Test func writesOnePrivateFileWithDecimalsAsStrings() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "budget", "thresholds": [["limit": .number("2490123.5")]]])
        #expect(TallyTest.permissions(state.url) == 0o700)
        #expect(TallyTest.permissions(state.tallies) == 0o700)
        #expect(TallyTest.permissions(state.file("budget")) == 0o600)

        let file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: state.file("budget"))) as? [String: Any])
        #expect(file["format"] as? Int == 1)
        #expect(file["value"] as? String == "0")
        let thresholds = try #require(file["thresholds"] as? [[String: Any]])
        #expect(thresholds.first?["limit"] as? String == "2490123.5")
    }

    @Test func refusesAnExistingNameAndShowsIt() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        try state.call("tally_add", ["name": "items", "amount": 3])
        let error = try #require(state.failure("tally_create", ["name": "items"]))
        #expect(error.message.contains("already exists"))
        #expect(error.message.contains("unique: true"))
        let existing = try #require(error.details?["existing"]?.objectValue)
        #expect(existing["name"] == "items")
        #expect(existing["value"] == 3)
    }

    @Test func uniqueAppendsASuffixAndReturnsTheName() throws {
        let state = TallyTestState()
        let first = try #require(try state.call("tally_create", ["name": "items", "unique": true])["name"]?.stringValue)
        let second = try #require(try state.call("tally_create", ["name": "items", "unique": true])["name"]?.stringValue)
        #expect(first.wholeMatch(of: /items-[a-z0-9]{4}/) != nil)
        #expect(second.wholeMatch(of: /items-[a-z0-9]{4}/) != nil)
        #expect(first != second)
        #expect(TallyTest.names(try state.call("tally_list"), in: "tallies") == [first, second].sorted())
    }

    @Test func refusesInvalidNamesWithASuggestion() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_create", ["name": "Items"]))
        #expect(error.details?["suggestion"] == "items")
        #expect(state.failure("tally_create", ["name": 5])?.message.contains("must be a string") == true)
        #expect(state.failure("tally_create", [:])?.message.contains("Missing argument \"name\"") == true)
        #expect(state.failure("tally_create", ["name": "items", "unique": "yes"])?.message.contains("true or false") == true)
    }

    @Test func showsHowThresholdStringsWereRead() throws {
        let state = TallyTestState()
        let response = try state.call("tally_create", ["name": "budget", "thresholds": [["limit": "20"]]])
        #expect(response["read"] == [["input": "20", "value": 20]])
        #expect(response["thresholds"] == [["limit": 20, "of": "value", "reached": false, "remaining": 20]])
    }

    @Test func refusesInvalidThresholdsWithoutCreatingAnything() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_create", ["name": "items", "thresholds": [["limit": 20, "at": [5]]]]))
        #expect(error.message.contains("thresholds[0]"))
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }
}

@Suite struct TallyAddTests {
    @Test func countsOneByDefault() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        try state.call("tally_add", ["name": "items"])
        let response = try state.call("tally_add", ["name": "items"])
        #expect(response.keys == ["name", "value", "count", "added", "crossed", "thresholds", "created", "updated"])
        #expect(response["value"] == 2)
        #expect(response["count"] == 2)
        #expect(response["added"] == 1)
        #expect(response["crossed"] == [])
    }

    @Test func addsExactlyAndShowsHowStringsWereRead() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "sum"])
        try state.call("tally_add", ["name": "sum", "amount": .number("0.1")])
        let response = try state.call("tally_add", ["name": "sum", "amount": "0.2"])
        #expect(response["value"] == .number("0.3"))
        #expect(response["added"] == .number("0.2"))
        #expect(response["read"] == [["input": "0.2", "value": .number("0.2")]])
    }

    @Test func negativeAmountsSubtract() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "stock"])
        let response = try state.call("tally_add", ["name": "stock", "amount": -4])
        #expect(response["value"] == -4)
        #expect(response["count"] == 1)
    }

    @Test func refusesAnUnknownNameAndSaysWhy() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "other"])
        let unique = try #require(try state.call("tally_create", ["name": "items", "unique": true])["name"]?.stringValue)
        let error = try #require(state.failure("tally_add", ["name": "items"]))
        #expect(error.message.contains("no tally named \"items\""))
        #expect(error.message.contains("expired"))
        #expect(error.message.contains("three days"))
        #expect(error.message.contains(unique))
        #expect(error.details?["existing"] == [.string(unique), "other"])  // suffixed names first
    }

    @Test func capsTheListOfExistingNames() throws {
        let state = TallyTestState()
        for index in 0..<25 {
            try state.call("tally_create", ["name": .string("t\(index)")])
        }
        let error = try #require(state.failure("tally_add", ["name": "nope"]))
        #expect(error.details?["existing"]?.arrayValue?.count == TallyErrors.listedNames)
        #expect(error.details?["existing_total"] == 25)
    }

    @Test func neverCreatesATallyOrFolder() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_add", ["name": "items"]))
        #expect(error.message.contains("No tallies exist"))
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }

    @Test func refusesUnknownArgumentsAndBadDecimalMarks() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        let typo = try #require(state.failure("tally_add", ["name": "items", "amout": 5]))
        #expect(typo.message.contains("\"amout\""))
        let mark = try #require(state.failure("tally_add", ["name": "items", "amount": "1", "decimal": ";"]))
        #expect(mark.message.contains("decimal must be"))
        let unreadable = try #require(state.failure("tally_add", ["name": "items", "amount": "lots"]))
        #expect(unreadable.message.hasPrefix("amount:"))
        #expect(try state.call("tally_list")["tallies"]?.arrayValue?.first?.objectValue?["count"] == 0)  // all refused
        #expect(try state.call("tally_add", ["name": "items", "amount": 1, "decimal": ","])["value"] == 1)
        #expect(try state.call("tally_add", ["name": "items", "amount": nil])["value"] == 2)  // null counts as absent
    }

    @Test func effortPointsWithALimitOnTheValueAndACheckpointOnTheCount() throws {
        let state = TallyTestState()
        try state.call("tally_create", [
            "name": "effort", "thresholds": [["limit": 20], ["every": 5, "of": "count"]],
        ])
        var response = JSONObject()
        for points in [3, 4, 2, 5] {
            response = try state.call("tally_add", ["name": "effort", "amount": .number(String(points))])
            #expect(response["crossed"] == [])
        }
        #expect(response["thresholds"] == [
            ["limit": 20, "of": "value", "reached": false, "remaining": 6],
            ["every": 5, "of": "count", "next": 5],
        ])

        response = try state.call("tally_add", ["name": "effort", "amount": 1])
        #expect(response["count"] == 5)
        #expect(response["crossed"] == [["every": 5, "of": "count", "at": [5]]])

        response = try state.call("tally_add", ["name": "effort", "amount": 6])
        #expect(response["value"] == 21)
        #expect(response["crossed"] == [["limit": 20, "of": "value"]])
        #expect(response["thresholds"] == [
            ["limit": 20, "of": "value", "reached": true, "over": 1],
            ["every": 5, "of": "count", "next": 10],
        ])

        // Once reached, the limit is no longer "crossed", but every response still says it is reached.
        response = try state.call("tally_add", ["name": "effort", "amount": 2])
        #expect(response["crossed"] == [])
        #expect(response["thresholds"]?.arrayValue?.first == ["limit": 20, "of": "value", "reached": true, "over": 3])
    }

    @Test func keepsInexactnessOnceTheTallyRounded() throws {
        let state = TallyTestState()
        try state.plantTally(TallyTest.tally("rounded", value: "0.3333333333333333333333333333333333333", count: 3, exact: false))
        let response = try state.call("tally_add", ["name": "rounded", "amount": 1])
        #expect(response.keys.prefix(4) == ["name", "value", "exact", "count"])
        #expect(response["exact"] == false)
        #expect(try state.call("tally_add", ["name": "rounded"])["exact"] == false)
    }

    @Test func updatesTheTimeFromTheContextClock() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        state.clock.advance(by: 90)
        let response = try state.call("tally_add", ["name": "items"])
        #expect(response["created"] == "2026-11-08T09:30:00Z")
        #expect(response["updated"] == "2026-11-08T09:31:30Z")
    }

    /// The reviewer's reproducer: this used to loop forever while holding the lock.
    @Test func everyOneNearThirtyEightDigitsFinishes() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "big", "thresholds": [["every": 1]]])
        try state.call("tally_set", ["name": "big", "value": "400000000000000000000000000000000000000"])
        let response = try state.call("tally_add", ["name": "big", "amount": 10])
        #expect(response["value"] == .number("400000000000000000000000000000000000010"))
        let crossed = try #require(response["crossed"]?.arrayValue?.first?.objectValue)
        #expect(crossed["times"] == 10)
        #expect(crossed["exact"] == false)
    }

    @Test func overflowIsAnErrorAndChangesNothing() throws {
        let state = TallyTestState()
        let largest = Decimal.greatestFiniteMagnitude.description
        try state.plantTally(TallyTest.tally("huge", value: largest))
        let error = try #require(state.failure("tally_add", ["name": "huge", "amount": .number(largest)]))
        #expect(error.message.contains("too large"))
        #expect(error.message.contains("unchanged"))
        #expect(try state.call("tally_list")["tallies"]?.arrayValue?.first?.objectValue?["count"] == 0)
    }
}

@Suite struct TallySetTests {
    @Test func setsValueCountAndThresholdsWithoutCrossing() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "thresholds": [["at": [5]]]])
        let response = try state.call("tally_set", ["name": "items", "value": "10", "count": 4])
        #expect(response["value"] == 10)
        #expect(response["count"] == 4)
        #expect(response["crossed"] == nil)
        #expect(response["read"] == [["input": "10", "value": 10]])
        #expect(response["thresholds"] == [["at": [5], "of": "value"]])

        let cleared = try state.call("tally_set", ["name": "items", "thresholds": []])
        #expect(cleared["thresholds"] == [])
        #expect(cleared["value"] == 10)
    }

    @Test func settingTheValueMakesItExactAgain() throws {
        let state = TallyTestState()
        try state.plantTally(TallyTest.tally("rounded", value: "1", exact: false))
        let response = try state.call("tally_set", ["name": "rounded", "value": 2])
        #expect(response["exact"] == nil)
        #expect(try state.call("tally_set", ["name": "rounded", "count": 7])["exact"] == nil)
    }

    @Test func refusesNothingToSetBadCountsAndUnknownNames() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        #expect(state.failure("tally_set", ["name": "items"])?.message.contains("Nothing to set") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": -1])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": .number("2.5")])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": .number("1e30")])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "nope", "value": 1])?.message.contains("no tally named") == true)
        #expect(try state.call("tally_set", ["name": "items", "count": "3"])["count"] == 3)
    }
}

@Suite struct TallyListTests {
    @Test func listsSortedWithFullStateAndTheFolder() throws {
        let state = TallyTestState()
        for name in ["b", "a-2", "a"] {
            try state.call("tally_create", ["name": .string(name), "thresholds": [["limit": 3]]])
        }
        let response = try state.call("tally_list")
        #expect(response.keys == ["folder", "tallies"])
        #expect(response["folder"] == .string(state.tallies.path))
        #expect(TallyTest.names(response, in: "tallies") == ["a", "a-2", "b"])
        let first = try #require(response["tallies"]?.arrayValue?.first?.objectValue)
        #expect(first["thresholds"] == [["limit": 3, "of": "value", "reached": false, "remaining": 3]])

        #expect(TallyTest.names(try state.call("tally_list", ["prefix": "a"]), in: "tallies") == ["a", "a-2"])
        #expect(TallyTest.names(try state.call("tally_list", ["prefix": "zz"]), in: "tallies") == [])
    }

    @Test func emptyWithoutCreatingTheFolder() throws {
        let state = TallyTestState()
        #expect(try state.call("tally_list")["tallies"] == [])
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }

    @Test func reportsUnreadableFilesAndIgnoresForeignOnes() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "good"])
        try state.plant("broken.json", "{ not json")
        try state.plant("Notes.json", "{}")  // not a tally name
        try state.plant("readme.txt", "hello")
        let response = try state.call("tally_list")
        #expect(TallyTest.names(response, in: "tallies") == ["good"])
        #expect(TallyTest.names(response, in: "unreadable") == ["broken"])
    }
}

@Suite struct TallyDropTests {
    @Test func returnsTheFinalStateAndForgetsTheTally() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items"])
        try state.call("tally_add", ["name": "items", "amount": 2])
        let response = try state.call("tally_drop", ["name": "items"])
        #expect(response.keys.prefix(3) == ["name", "dropped", "value"])
        #expect(response["dropped"] == true)
        #expect(response["value"] == 2)
        #expect(!FileManager.default.fileExists(atPath: state.file("items").path))
        #expect(state.failure("tally_add", ["name": "items"])?.message.contains("no tally named") == true)
        #expect(state.failure("tally_drop", ["name": "items"])?.message.contains("no tally named") == true)
    }

    @Test func removesAFileItCannotRead() throws {
        let state = TallyTestState()
        try state.plant("broken.json", "{ not json")
        let error = try #require(state.failure("tally_add", ["name": "broken"]))
        #expect(error.message.contains("cannot be read"))
        #expect(error.message.contains("tally_drop"))
        let response = try state.call("tally_drop", ["name": "broken"])
        #expect(response["dropped"] == true)
        #expect(response["unreadable"]?.stringValue?.contains("not a tally file") == true)
        #expect(!FileManager.default.fileExists(atPath: state.file("broken").path))
    }
}

@Suite struct TallyFileTests {
    @Test func roundTripsEveryField() throws {
        let tally = TallyTest.tally(
            "budget", value: "-2490123.25", count: 12, exact: false,
            thresholds: [Threshold(.limit(TallyTest.decimal("1e30"))), Threshold(.at([1, 2]), of: .count), Threshold(.every(TallyTest.decimal("0.5")))]
        )
        #expect(try Tally(fileData: tally.fileData(), name: "budget") == tally)
    }

    @Test func aNewerFormatIsRefusedAndLeftAlone() throws {
        let state = TallyTestState()
        let text = #"{"format": 2, "name": "items", "count": 1}"#
        try state.plant("items.json", text)
        let error = try #require(state.failure("tally_add", ["name": "items"]))
        #expect(error.message.contains("newer version of abakus"))
        #expect(state.failure("tally_create", ["name": "items"])?.message.contains("newer version") == true)
        #expect(try String(contentsOf: state.file("items"), encoding: .utf8) == text)
    }

    @Test(arguments: [
        #"{"format": 1, "name": "x", "value": 1, "count": 0, "exact": true, "thresholds": [], "created": "", "updated": ""}"#,
        #"{"format": 1, "name": "x", "value": "1e3", "count": 0, "exact": true, "thresholds": [], "created": "", "updated": ""}"#,
        #"{"format": 1, "name": "x", "value": "1", "count": 0, "exact": true, "thresholds": [{"of": "value"}], "created": "", "updated": ""}"#,
        #"{"format": 1, "name": "x", "value": "1", "count": 0, "exact": true, "thresholds": [{"every": "0", "of": "value"}], "created": "", "updated": ""}"#,
        "[]",
    ])
    func damagedFilesAreErrors(text: String) {
        #expect(throws: ToolError.self) { try Tally(fileData: Data(text.utf8), name: "x") }
    }
}

@Suite struct TallyToolDefinitionTests {
    @Test func theFiveToolsInOrder() {
        #expect(TallyTools.all.map(\.name) == ["tally_create", "tally_add", "tally_set", "tally_list", "tally_drop"])
        #expect(Catalog.tools.prefix(5).map(\.name) == TallyTools.all.map(\.name))
    }

    @Test func annotationsAreDeliberate() {
        let byName = Dictionary(uniqueKeysWithValues: TallyTools.all.map { ($0.name, $0.annotations) })
        #expect(byName["tally_list"] == ToolAnnotations(title: "List tallies", readOnly: true, destructive: false, idempotent: true))
        #expect(byName["tally_drop"]?.destructive == true)
        #expect(byName["tally_set"]?.destructive == true)
        #expect(byName["tally_add"]?.readOnly == false)
        #expect(byName["tally_add"]?.destructive == false)
        #expect(byName["tally_add"]?.idempotent == false)
        #expect(byName["tally_create"]?.idempotent == false)
        #expect(TallyTools.all.allSatisfy { $0.annotations.openWorld == false })
    }

    @Test func schemasAreClosedObjects() throws {
        for tool in TallyTools.all {
            let schema = try #require(tool.inputSchema.objectValue)
            #expect(schema["type"] == "object", "\(tool.name)")
            #expect(schema["additionalProperties"] == false, "\(tool.name)")
            let properties = try #require(schema["properties"]?.objectValue)
            if tool.name == "tally_list" {
                #expect(schema["required"] == nil)
            } else {
                #expect(schema["required"] == ["name"], "\(tool.name)")
                #expect(properties["name"] != nil)
            }
        }
    }

    @Test func toolsThatTakeNumbersSayHowTheyAreRead() {
        for tool in TallyTools.all where ["tally_create", "tally_add", "tally_set"].contains(tool.name) {
            #expect(tool.description.contains(#""410k" or "1,234.5" (with decimal: "," for a decimal comma)"#), "\(tool.name)")
        }
    }
}

extension TallyTestState {
    /// Saves a tally directly, bypassing the tools, e.g. one that is already inexact.
    func plantTally(_ tally: Tally) throws {
        try TallyStore(context).change(creatingFolder: true) { files throws(ToolError) in try files.save(tally) }
    }
}
