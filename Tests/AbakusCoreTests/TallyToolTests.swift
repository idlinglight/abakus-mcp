@testable import AbakusCore
import Foundation
import Testing

@Suite struct TallyCreateTests {
    @Test func returnsTheNewTallysStateUnderASuffixedName() throws {
        let state = TallyTestState()
        let response = try state.call("tally_create", ["name": "items"])
        #expect(response.keys == ["name", "value", "count", "thresholds", "created", "updated"])
        let name = try #require(response["name"]?.stringValue)
        #expect(name.wholeMatch(of: /items-[a-z0-9]{4}/) != nil)
        #expect(response == [
            "name": .string(name), "value": 0, "count": 0, "thresholds": [],
            "created": "2026-11-08T09:30:00Z", "updated": "2026-11-08T09:30:00Z",
        ])
        #expect(FileManager.default.fileExists(atPath: state.file(name).path))
        #expect(!FileManager.default.fileExists(atPath: state.file("items").path))
    }

    @Test func writesOnePrivateFileWithDecimalsAsStrings() throws {
        let state = TallyTestState()
        let created = try state.call("tally_create", ["name": "budget", "thresholds": [["limit": .number("2490123.5")]]])
        let file = state.file(try #require(created["name"]?.stringValue))
        #expect(TallyTest.permissions(state.url) == 0o700)
        #expect(TallyTest.permissions(state.tallies) == 0o700)
        #expect(TallyTest.permissions(file) == 0o600)

        let contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(contents["format"] as? Int == 1)
        #expect(contents["value"] as? String == "0")
        let thresholds = try #require(contents["thresholds"] as? [[String: Any]])
        #expect(thresholds.first?["limit"] as? String == "2490123.5")
    }

    /// Two sessions asking for the same name each count on their own.
    @Test func everyCreateGetsANameOfItsOwn() throws {
        let state = TallyTestState()
        let first = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        let second = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        #expect(first.wholeMatch(of: /items-[a-z0-9]{4}/) != nil)
        #expect(second.wholeMatch(of: /items-[a-z0-9]{4}/) != nil)
        #expect(first != second)
        try state.call("tally_add", ["name": .string(first), "amount": 3])
        #expect(try state.call("tally_add", ["name": .string(second)])["value"] == 1)
        #expect(TallyTest.names(try state.call("tallies_info"), in: "tallies") == [first, second].sorted())
    }

    @Test func aSharedTallyDoesNotBlockSuffixedOnes() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
        let response = try state.call("tally_create", ["name": "items"])
        let own = try #require(response["name"]?.stringValue)
        #expect(own.hasPrefix("items-"))
        #expect(response["note"]?.stringValue?.hasPrefix("A tally named \"items\" already exists") == true)
        #expect(TallyTest.names(try state.call("tallies_info"), in: "tallies") == ["items", own])
    }

    @Test func nameLengthsLeaveRoomForTheSuffixUnlessShared() throws {
        let state = TallyTestState()
        let longest = String(repeating: "x", count: 59)
        let suffixed = try #require(try state.call("tally_create", ["name": .string(longest)])["name"]?.stringValue)
        #expect(suffixed.utf8.count == 64)
        let error = try #require(state.failure("tally_create", ["name": .string(longest + "x")]))
        #expect(error.message.contains("random suffix"))
        #expect(error.message.contains("may have at most 59"))
        // The suggestion is a name tally_create takes.
        let suggestion = try #require(error.details?["suggestion"])
        #expect(try state.call("tally_create", ["name": suggestion])["name"]?.stringValue?.hasPrefix(longest + "-") == true)
        let full = String(repeating: "y", count: 64)
        #expect(try state.call("tally_create", ["name": .string(full), "shared": true])["name"] == .string(full))
    }

    @Test func sharedUsesTheNameExactly() throws {
        let state = TallyTestState()
        let response = try state.call("tally_create", ["name": "build-errors", "shared": true])
        #expect(response["name"] == "build-errors")
        #expect(FileManager.default.fileExists(atPath: state.file("build-errors").path))
        #expect(try state.call("tally_create", ["name": "plain", "shared": false])["name"]?.stringValue?.hasPrefix("plain-") == true)
    }

    @Test func sharedRefusesAnExistingNameAndShowsIt() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
        try state.call("tally_add", ["name": "items", "amount": 3])
        let error = try #require(state.failure("tally_create", ["name": "items", "shared": true]))
        #expect(error.message.contains("already exists"))
        #expect(error.message.contains("only if you are coordinating with whoever created it"))
        #expect(error.message.contains("without shared"))
        #expect(!error.message.contains("unique"))
        // An agent cannot know a shared tally is its own; starting it over could wipe other sessions' count.
        #expect(!error.message.contains("tally_set"))
        #expect(!error.message.contains("tally_drop"))
        let existing = try #require(error.details?["existing"]?.objectValue)
        #expect(existing["name"] == "items")
        #expect(existing["value"] == 3)
        #expect(try state.call("tallies_info")["tallies"]?.arrayValue?.count == 1)  // nothing new
    }

    @Test func uniqueIsGoneAndTheErrorSaysWhatToDoInstead() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_create", ["name": "items", "unique": true]))
        #expect(error.message == """
            Unknown argument "unique". tally_create takes "name" (required), "shared", "thresholds" and "decimal". \
            Leave unique out: tally_create appends a random suffix by default now.
            """)
        #expect(error.details?["argument"] == "unique")
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }

    /// unique: false asked for the exact name, which is what shared: true does now, with its condition.
    @Test func uniqueFalsePointsToShared() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_create", ["name": "items", "unique": false]))
        #expect(error.message == """
            Unknown argument "unique". tally_create takes "name" (required), "shared", "thresholds" and "decimal". \
            To use the name exactly, without a suffix, pass shared: true instead; the name must not exist yet.
            """)
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
        // Any other value gets no hint: it is not clear what it asked for.
        #expect(state.failure("tally_create", ["name": "items", "unique": "yes"])?.message == """
            Unknown argument "unique". tally_create takes "name" (required), "shared", "thresholds" and "decimal".
            """)
    }

    /// Typically a name tally_create returned earlier, given again after compaction: still a new tally, with a
    /// note on how to continue the old one instead.
    @Test func creatingWithAnExistingNameNotesItAndStillCreates() throws {
        let state = TallyTestState()
        let first = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        state.clock.advance(by: 60)
        let again = try state.call("tally_create", ["name": .string(first)])
        let second = try #require(again["name"]?.stringValue)
        #expect(second.hasPrefix(first + "-"))
        #expect(again.keys == ["name", "value", "count", "thresholds", "created", "updated", "note"])
        #expect(again["note"] == .string("""
            A tally named "\(first)" already exists, and tally_create always makes a new tally: this one is \
            "\(second)". If you meant to continue "\(first)", add to it with tally_add and drop this new one with \
            tally_drop.
            """))
        #expect(TallyTest.names(try state.call("tallies_info"), in: "tallies") == [first, second])
        // No note when nothing has exactly the given name, even if suffixed tallies of it exist.
        #expect(try state.call("tally_create", ["name": "items"])["note"] == nil)
    }

    @Test func refusesInvalidNamesWithASuggestion() throws {
        let state = TallyTestState()
        let error = try #require(state.failure("tally_create", ["name": "Items"]))
        #expect(error.details?["suggestion"] == "items")
        #expect(state.failure("tally_create", ["name": "Items", "shared": true])?.details?["suggestion"] == "items")
        #expect(state.failure("tally_create", ["name": 5])?.message.contains("must be a string") == true)
        #expect(state.failure("tally_create", [:])?.message.contains("Missing argument \"name\"") == true)
        #expect(state.failure("tally_create", ["name": "items", "shared": "yes"])?.message.contains("true or false") == true)
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
        try state.call("tally_create", ["name": "items", "shared": true])
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
        try state.call("tally_create", ["name": "sum", "shared": true])
        try state.call("tally_add", ["name": "sum", "amount": .number("0.1")])
        let response = try state.call("tally_add", ["name": "sum", "amount": "0.2"])
        #expect(response["value"] == .number("0.3"))
        #expect(response["added"] == .number("0.2"))
        #expect(response["read"] == [["input": "0.2", "value": .number("0.2")]])
    }

    @Test func negativeAmountsSubtract() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "stock", "shared": true])
        let response = try state.call("tally_add", ["name": "stock", "amount": -4])
        #expect(response["value"] == -4)
        #expect(response["count"] == 1)
    }

    /// The likely mistake: adding to the name asked for instead of the suffixed one tally_create returned. But
    /// every tally has a suffix, so a match may as well be another session's: the error shows when each was
    /// created and suggests none.
    @Test func refusesAnUnknownNameAndSaysWhy() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "other", "shared": true])
        let mine = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        try state.call("tally_add", ["name": .string(mine), "amount": 3])
        state.clock.advance(by: 120)
        let theirs = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        let (a, b) = mine < theirs ? (mine, theirs) : (theirs, mine)
        func described(_ name: String) -> String {
            name == mine
                ? "\"\(mine)\" (created 2026-11-08T09:30:00Z, value 3, count 1)"
                : "\"\(theirs)\" (created 2026-11-08T09:32:00Z, value 0, count 0)"
        }
        let error = try #require(state.failure("tally_add", ["name": "items"]))
        #expect(error.message == """
            There is no tally named "items". It may never have been created (check the spelling), or it may have \
            expired: macOS deletes tallies that have not changed for about three days. tally_create adds a random \
            suffix to every name unless shared: true is passed, and tallies whose names start with "items-" exist: \
            \(described(a)) and \(described(b)). They may belong to other sessions: use one only if you know you \
            created it (compare its created time with when you created yours). If unsure, create a new tally with \
            tally_create. details.matching shows them; details.existing lists the tallies that exist.
            """)
        #expect(!error.message.contains("did you mean"))
        #expect(error.details?.keys == ["name", "matching", "existing"])
        func entry(_ name: String) -> JSONValue {
            name == mine
                ? ["name": .string(mine), "value": 3, "count": 1, "created": "2026-11-08T09:30:00Z"]
                : ["name": .string(theirs), "value": 0, "count": 0, "created": "2026-11-08T09:32:00Z"]
        }
        #expect(error.details?["matching"] == [entry(a), entry(b)])
        #expect(error.details?["existing"] == [.string(a), .string(b), "other"])  // suffixed names first
    }

    @Test func describesAtMostThreeMatchesInTheMessage() throws {
        let state = TallyTestState()
        for _ in 0..<5 { try state.call("tally_create", ["name": "items"]) }
        let error = try #require(state.failure("tally_set", ["name": "items", "value": 1]))
        #expect(error.message.contains("count 0) and 2 more. They may belong to other sessions"))
        #expect(error.details?["matching"]?.arrayValue?.count == 5)
        // One match reads as one.
        let solo = try #require(try state.call("tally_create", ["name": "solo"])["name"]?.stringValue)
        let one = try #require(state.failure("tally_add", ["name": "solo"]))
        #expect(one.message.contains("a tally whose name starts with \"solo-\" exists: \"\(solo)\" (created 2026-11-08T09:30:00Z, value 0, count 0). It may belong to another session: use it only if you know you created it"))
        #expect(one.message.hasSuffix("details.matching shows it; details.existing lists the tallies that exist."))
        // Without matches, the error is about the name alone.
        let plain = try #require(state.failure("tally_add", ["name": "other"]))
        #expect(plain.details?.keys == ["name", "existing"])
        #expect(plain.message.hasSuffix("details.existing lists the tallies that exist. To start over, create it with tally_create."))
    }

    @Test func dropsUnknownNamesWithoutSuggestingToCreateOne() throws {
        let state = TallyTestState()
        let empty = try #require(state.failure("tally_drop", ["name": "items"]))
        #expect(empty.message == """
            There is no tally named "items". It may already have been dropped (a repeated tally_drop ends here), \
            it may never have been created (check the spelling), or it may have expired: macOS deletes tallies \
            that have not changed for about three days. No tallies exist right now, so there is nothing to drop.
            """)

        let solo = try #require(try state.call("tally_create", ["name": "solo"])["name"]?.stringValue)
        let one = try #require(state.failure("tally_drop", ["name": "solo"]))
        #expect(one.message.contains("exists: \"\(solo)\" (created 2026-11-08T09:30:00Z, value 0, count 0). It may belong to another session: drop it only if you know you created it (compare its created time with when you created yours). If unsure, leave it to expire. details.matching shows it;"))
        #expect(!suggestsCreating(one.message))

        try state.call("tally_create", ["name": "solo"])
        let two = try #require(state.failure("tally_drop", ["name": "solo"]))
        #expect(two.message.contains("They may belong to other sessions: drop one only if you know you created it"))
        #expect(two.message.contains("If unsure, leave them to expire."))

        let plain = try #require(state.failure("tally_drop", ["name": "other"]))
        #expect(plain.details?.keys == ["name", "existing"])
        #expect(plain.message.hasSuffix("details.existing lists the tallies that exist. Nothing was dropped."))
        #expect(!suggestsCreating(plain.message))
        #expect(!suggestsCreating(empty.message))
        func suggestsCreating(_ message: String) -> Bool {
            let lowered = message.lowercased()
            return lowered.contains("create a new") || lowered.contains("create it")
        }
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
        try state.call("tally_create", ["name": "items", "shared": true])
        let typo = try #require(state.failure("tally_add", ["name": "items", "amout": 5]))
        #expect(typo.message == "Unknown argument \"amout\". tally_add takes \"name\" (required), \"amount\" and \"decimal\".")
        #expect(state.failure("tallies_info", ["prefx": "a"])?.message == "Unknown argument \"prefx\". tallies_info takes \"prefix\".")
        let mark = try #require(state.failure("tally_add", ["name": "items", "amount": "1", "decimal": ";"]))
        #expect(mark.message.contains("decimal must be"))
        let unreadable = try #require(state.failure("tally_add", ["name": "items", "amount": "lots"]))
        // NumberReader's own wording and details, labelled with the argument.
        #expect(unreadable.message.hasPrefix("amount: Cannot read \"lots\" as a number"))
        #expect(unreadable.details?["input"] == "lots")
        let tooPrecise = try #require(state.failure("tally_add", ["name": "items", "amount": "1234567890123456789012345678901234567891"]))
        #expect(tooPrecise.message.hasPrefix("amount: Cannot read"))
        #expect(tooPrecise.message.contains("significant digits"))
        #expect(try state.call("tallies_info")["tallies"]?.arrayValue?.first?.objectValue?["count"] == 0)  // all refused
        #expect(try state.call("tally_add", ["name": "items", "amount": 1, "decimal": ","])["value"] == 1)
        #expect(try state.call("tally_add", ["name": "items", "amount": nil])["value"] == 2)  // null counts as absent
    }

    @Test func effortPointsWithALimitOnTheValueAndACheckpointOnTheCount() throws {
        let state = TallyTestState()
        try state.call("tally_create", [
            "name": "effort", "shared": true, "thresholds": [["limit": 20], ["every": 5, "of": "count"]],
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
        try state.call("tally_create", ["name": "items", "shared": true])
        state.clock.advance(by: 90)
        let response = try state.call("tally_add", ["name": "items"])
        #expect(response["created"] == "2026-11-08T09:30:00Z")
        #expect(response["updated"] == "2026-11-08T09:31:30Z")
    }

    /// The reviewer's reproducer: this used to loop forever while holding the lock.
    @Test func everyOneNearThirtyEightDigitsFinishes() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "big", "shared": true, "thresholds": [["every": 1]]])
        try state.call("tally_set", ["name": "big", "value": "400000000000000000000000000000000000000"])
        let response = try state.call("tally_add", ["name": "big", "amount": 10])
        #expect(response["value"] == .number("400000000000000000000000000000000000010"))
        let crossed = try #require(response["crossed"]?.arrayValue?.first?.objectValue)
        #expect(crossed["times"] == 10)
        #expect(crossed["exact"] == false)
    }

    @Test func overflowIsAnErrorAndChangesNothing() throws {
        let state = TallyTestState()
        // 9e164 is readable (below 10^165), but twice that is past what exact decimal arithmetic holds.
        let large = "9" + String(repeating: "0", count: 164)
        try state.plantTally(TallyTest.tally("huge", value: large))
        let error = try #require(state.failure("tally_add", ["name": "huge", "amount": .number(large)]))
        #expect(error.message.contains("too large"))
        #expect(error.message.contains("unchanged"))
        #expect(try state.call("tallies_info")["tallies"]?.arrayValue?.first?.objectValue?["count"] == 0)
    }
}

@Suite struct TallySetTests {
    @Test func setsValueCountAndThresholdsWithoutCrossing() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true, "thresholds": [["at": [5]]]])
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
        try state.call("tally_create", ["name": "items", "shared": true])
        #expect(state.failure("tally_set", ["name": "items"])?.message.contains("Nothing to set") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": -1])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": .number("2.5")])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "items", "count": .number("1e30")])?.message.contains("whole number") == true)
        #expect(state.failure("tally_set", ["name": "nope", "value": 1])?.message.contains("no tally named") == true)
        #expect(try state.call("tally_set", ["name": "items", "count": "3"])["count"] == 3)
    }
}

@Suite struct TalliesInfoTests {
    private let tool = TalliesInfo()

    @Test func countsAndListsSortedWithFullStateAndTheFolder() throws {
        let state = TallyTestState()
        for name in ["b", "a-2", "a"] {
            try state.call("tally_create", ["name": .string(name), "shared": true, "thresholds": [["limit": 3]]])
        }
        let response = try state.call("tallies_info")
        #expect(response.keys == ["folder", "tallies_found", "tallies"])
        #expect(response["folder"] == .string(state.tallies.path))
        #expect(response["tallies_found"] == 3)
        #expect(TallyTest.names(response, in: "tallies") == ["a", "a-2", "b"])
        let first = try #require(response["tallies"]?.arrayValue?.first?.objectValue)
        #expect(first["thresholds"] == [["limit": 3, "of": "value", "reached": false, "remaining": 3]])

        let prefixed = try state.call("tallies_info", ["prefix": "a"])
        #expect(prefixed["tallies_found"] == 2)
        #expect(TallyTest.names(prefixed, in: "tallies") == ["a", "a-2"])
        let none = try state.call("tallies_info", ["prefix": "zz"])
        #expect(none["tallies_found"] == 0)
        #expect(none["tallies"] == [])
    }

    @Test func emptyWithoutCreatingTheFolder() throws {
        let state = TallyTestState()
        let response = try state.call("tallies_info")
        #expect(response == ["folder": .string(state.tallies.path), "tallies_found": 0, "tallies": []])
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }

    @Test func reportsUnreadableFilesAndIgnoresForeignOnes() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "good", "shared": true])
        try state.plant("broken.json", "{ not json")
        try state.plant("Notes.json", "{}")  // not a tally name
        try state.plant("readme.txt", "hello")
        let response = try state.call("tallies_info")
        #expect(response.keys == ["folder", "tallies_found", "unreadable_found", "tallies", "unreadable"])
        #expect(response["tallies_found"] == 1)
        #expect(response["unreadable_found"] == 1)
        #expect(TallyTest.names(response, in: "tallies") == ["good"])
        #expect(TallyTest.names(response, in: "unreadable") == ["broken"])
        let problem = response["unreadable"]?.arrayValue?.first?.objectValue?["problem"]?.stringValue
        #expect(problem?.contains("not a tally file") == true)
    }

    /// The lists grow with the number of tallies, other sessions' included, so they are details: over MCP the
    /// result is the folder and the counts (ADR-0008).
    @Test func overMCPOnlyTheFolderAndTheCounts() throws {
        #expect(tool.detailKeys == ["tallies", "unreadable"])
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "thresholds": [["at": [1, 2, 3]]]])
        #expect(tool.withoutDetails(try state.call("tallies_info")) == ["folder": .string(state.tallies.path), "tallies_found": 1])

        try state.plant("broken.json", "{ not json")
        let withUnreadable = tool.withoutDetails(try state.call("tallies_info"))
        #expect(withUnreadable.keys == ["folder", "tallies_found", "unreadable_found"])
        #expect(withUnreadable["unreadable_found"] == 1)
    }

    /// 40 times as many tallies, each with more thresholds and marks, add one digit to the MCP result and nothing
    /// else.
    @Test func theMCPResultGrowsOnlyByTheDigitsOfTheCount() throws {
        let state = TallyTestState()
        func written() throws -> String { JSONWriter.write(tool.withoutDetails(try state.call("tallies_info"))) }
        try state.call("tally_create", ["name": "items"])
        let one = try written()
        let marks: [JSONValue] = (1...20).map { .number(String($0)) }
        for _ in 1..<40 {
            try state.call("tally_create", ["name": "items", "thresholds": [["limit": 20], ["at": .array(marks)], ["every": 5, "of": "count"]]])
        }
        let forty = try written()
        #expect(forty.count == one.count + 1)
        #expect(forty.count <= state.tallies.path.count + 40)
    }

    /// What the description promises for a lost name: calc with the name without its suffix shows the tallies named
    /// with it plus a suffix, and writes nothing. A partial name finds none, and unreadable_found follows the prefix.
    @Test func calcLooksUpALostNameWithoutWriting() throws {
        let state = TallyTestState()
        let name = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        try state.plant("broken.json", "{ not json")
        let before = try Data(contentsOf: state.file(name))
        let calc = try #require(Catalog.tool(named: "calc"))
        func lookup(_ expression: String) throws -> ToolError {
            try #require(throws: ToolError.self) { try calc.call(["expression": .string(expression)], in: state.context) }
        }
        #expect(TallyTest.names(try lookup("{items}").details ?? [:], in: "matching") == [name])
        #expect(try lookup("{item}").details?["matching"] == nil)
        #expect(try Data(contentsOf: state.file(name)) == before)

        #expect(tool.withoutDetails(try state.call("tallies_info", ["prefix": "items"])) == ["folder": .string(state.tallies.path), "tallies_found": 1])
        #expect(tool.withoutDetails(try state.call("tallies_info", ["prefix": "b"])) == ["folder": .string(state.tallies.path), "tallies_found": 0, "unreadable_found": 1])
    }

    /// The description says what an MCP result holds and that the command line lists the tallies, and keeps the
    /// files internal: it tells nothing about their format, and says tallies change only through the tally tools.
    @Test func theDescriptionKeepsTheFilesInternal() {
        let text = tool.description
        #expect(text.contains("returns folder and tallies_found"))
        #expect(text.contains("unreadable_found"))
        #expect(text.contains("With prefix, both count only tallies whose names start with it."))
        #expect(text.contains("It lists no names or states"))
        // A lookup by a guessed name goes through calc, which never writes: tally_add or tally_drop would change or
        // delete a shared tally of exactly that name.
        #expect(text.contains("call calc with {items}: calc never writes"))
        #expect(!text.contains("tally_add") && !text.contains("tally_drop") && !text.contains("tally_set"))
        #expect(text.contains("abakus tallies info"))
        #expect(text.contains("Tallies change only through the tally tools, which hold the lock on the folder, never by changing files in it."))
        for word in [".json", "JSON file", "format", " ls ", " cat ", "jq", "grep"] {
            #expect(!text.contains(word), "\(word)")
        }
    }
}

@Suite struct TallyDropTests {
    @Test func returnsTheFinalStateAndForgetsTheTally() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
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

/// Thresholds only inform: one whose arithmetic fails (here value / every overflows Decimal) must not stop a
/// tally from being added to, listed or dropped.
@Suite struct TallyUncomputableThresholdTests {
    private static let huge = "1" + String(repeating: "0", count: 159)  // 1e159; 1e159 / 1e-7 overflows

    private func plant(_ state: TallyTestState) throws {
        try state.plantTally(TallyTest.tally("odd", value: Self.huge, thresholds: [Threshold(.every(TallyTest.decimal("0.0000001")))]))
    }

    private func problem(_ object: JSONObject, in key: String) -> String? {
        object[key]?.arrayValue?.first?.objectValue?["problem"]?.stringValue
    }

    @Test func listShowsTheTallyWithANoteNotAsUnreadable() throws {
        let state = TallyTestState()
        try plant(state)
        let response = try state.call("tallies_info")
        #expect(response["unreadable"] == nil)
        let tally = try #require(response["tallies"]?.arrayValue?.first?.objectValue)
        #expect(tally["name"] == "odd")
        #expect(problem(tally, in: "thresholds")?.contains("cannot be computed") == true)
        #expect(problem(tally, in: "thresholds")?.contains("too large") == true)
    }

    @Test func addCountsAndSaysWhatItCouldNotCompute() throws {
        let state = TallyTestState()
        try plant(state)
        let response = try state.call("tally_add", ["name": "odd", "amount": .number("1" + String(repeating: "0", count: 150))])
        #expect(response["count"] == 1)
        #expect(problem(response, in: "crossed")?.contains("crossed one of its marks cannot be computed") == true)
        #expect(problem(response, in: "thresholds") != nil)
        #expect(try state.call("tallies_info")["tallies"]?.arrayValue?.first?.objectValue?["count"] == 1)  // saved
    }

    @Test func dropStillDeletesAndReturnsTheState() throws {
        let state = TallyTestState()
        try plant(state)
        let response = try state.call("tally_drop", ["name": "odd"])
        #expect(response["dropped"] == true)
        #expect(response["value"] == .number(Self.huge))
        #expect(problem(response, in: "thresholds") != nil)
        #expect(!FileManager.default.fileExists(atPath: state.file("odd").path))
    }

    @Test func aFailedSaveSaysTheTallyIsUnchanged() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
        let before = try Data(contentsOf: state.file("items"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.tallies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.tallies.path) }
        let error = try #require(state.failure("tally_add", ["name": "items"]))
        #expect(error.message.contains("Nothing was saved"))
        #expect(try Data(contentsOf: state.file("items")) == before)
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
        #expect(state.failure("tally_create", ["name": "items", "shared": true])?.message.contains("newer version") == true)
        #expect(try String(contentsOf: state.file("items"), encoding: .utf8) == text)
    }

    /// A file with these fields filled in, the rest valid.
    private static func file(format: String = "1", value: String = #""1""#, count: String = "0", thresholds: String = "[]") -> String {
        #"{"format": \#(format), "name": "x", "value": \#(value), "count": \#(count), "exact": true, "thresholds": \#(thresholds), "created": "", "updated": ""}"#
    }

    @Test func aValidFileReads() throws {
        let tally = try Tally(fileData: Data(Self.file(thresholds: #"[{"every": "5", "of": "count"}]"#).utf8), name: "x")
        #expect(tally.thresholds == [Threshold(.every(5), of: .count)])
    }

    /// Files follow the same rules as arguments; what breaks them is unreadable.
    @Test(arguments: [
        ("[]", "not a tally file"),
        (file(format: "0"), "invalid file format version (0)"),
        (file(format: "-1"), "invalid file format version (-1)"),
        (file(value: "1"), "damaged"),
        (file(value: #""12abc""#), "where a number belongs"),
        (file(value: #""1,5""#), "where a number belongs"),
        (file(value: #""1234567890123456789012345678901234567891""#), "significant digits"),  // never truncated
        (file(thresholds: #"[{"limit": "1e999", "of": "value"}]"#), "where a number belongs"),
        (file(count: "-1"), "invalid count (count must be a whole number, 0 or more"),
        (file(thresholds: #"[{"of": "value"}]"#), "without exactly one of limit, at and every"),
        (file(thresholds: #"[{"limit": "1", "every": "2", "of": "value"}]"#), "without exactly one of limit, at and every"),
        (file(thresholds: #"[{"limit": "1", "of": "items"}]"#), "neither value nor count"),
        (file(thresholds: #"[{"every": "0", "of": "value"}]"#), "invalid threshold (thresholds[0].every must be greater than 0)"),
        (file(thresholds: #"[{"at": [], "of": "value"}]"#), "invalid threshold (thresholds[0].at must be a non-empty list"),
        (file(thresholds: #"[{"limit": "3", "of": "value"}, {"every": "2.5", "of": "count"}]"#), "invalid threshold (thresholds[1] watches the count"),
        (file(thresholds: #"[{"at": ["1", "1.5"], "of": "count"}]"#), "whole numbers"),
    ])
    func invalidFilesAreUnreadable(text: String, expected: String) throws {
        let error = try #require(throws: ToolError.self) { try Tally(fileData: Data(text.utf8), name: "x") }
        #expect(error.message.contains(expected), "\(error.message)")
        #expect(!error.message.hasSuffix("."))  // it is embedded as a clause
    }

    @Test func toolsTreatAFileBreakingTheRulesAsUnreadable() throws {
        let state = TallyTestState()
        try state.plant("checks.json", Self.file(thresholds: #"[{"every": "2.5", "of": "count"}]"#))
        let error = try #require(state.failure("tally_add", ["name": "checks"]))
        #expect(error.message.contains("cannot be read"))
        #expect(error.message.contains("whole numbers"))
        #expect(TallyTest.names(try state.call("tallies_info"), in: "unreadable") == ["checks"])
        #expect(try state.call("tally_drop", ["name": "checks"])["unreadable"] != nil)
    }
}

@Suite struct TallyToolDefinitionTests {
    @Test func theFiveToolsInOrder() {
        #expect(TallyTools.all.map(\.name) == ["tally_create", "tally_add", "tally_set", "tallies_info", "tally_drop"])
        #expect(Catalog.tools.prefix(5).map(\.name) == TallyTools.all.map(\.name))
    }

    @Test func annotationsAreDeliberate() {
        let byName = Dictionary(uniqueKeysWithValues: TallyTools.all.map { ($0.name, $0.annotations) })
        #expect(byName["tallies_info"] == ToolAnnotations(title: "Count tallies", readOnly: true, destructive: false, idempotent: true))
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
            if tool.name == "tallies_info" {
                #expect(schema["required"] == nil)
            } else {
                #expect(schema["required"] == ["name"], "\(tool.name)")
                #expect(properties["name"] != nil)
            }
        }
    }

    /// In brief: the full rules are in sum's description, once.
    @Test func toolsThatTakeNumbersSayHowTheyAreRead() {
        for tool in TallyTools.all where ["tally_create", "tally_add", "tally_set"].contains(tool.name) {
            #expect(tool.description.contains(NumberReader.rulesInBrief), "\(tool.name)")
            #expect(!tool.description.contains(NumberReader.rulesSummary), "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["decimal"] == DecimalMark.schema, "\(tool.name)")
        }
    }

    @Test func createLeadsWithTheSuffixAndOffersShared() throws {
        let create = try #require(TallyTools.all.first { $0.name == "tally_create" })
        #expect(create.description.contains("Every tally gets a random suffix"))
        #expect(create.description.contains("shared: true"))
        #expect(create.description.contains("Leave other sessions' tallies alone unless you coordinate with them."))
        #expect(create.description.contains("tally_add to continue it: tally_create always makes a new tally"))
        let properties = try #require(create.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(properties.keys == ["name", "shared", "thresholds", "decimal"])
        #expect(properties["shared"]?.objectValue?["default"] == false)
        #expect(TallyTools.all.allSatisfy { !$0.description.contains("unique") })
    }
}

extension TallyTestState {
    /// Saves a tally directly, bypassing the tools, e.g. one that is already inexact.
    func plantTally(_ tally: Tally) throws {
        try TallyStore(context).change(creatingFolder: true) { files throws(ToolError) in try files.save(tally) }
    }
}
