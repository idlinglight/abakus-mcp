@testable import AbakusCore
import Foundation
import Testing

/// calc (ADR-0007) end to end through the tool: parsing, tallies, exact evaluation, the response and its errors.
/// Every test has its own state folder (`TallyTestState`); the expected values were worked out with exact
/// fractions independently of abakus.
@Suite struct CalcToolTests {
    private let tool = CalcTool()

    // MARK: Definition

    @Test func isListedAfterSum() {
        #expect(ArithmeticTools.all.map(\.name) == ["sum", "calc"])
        #expect(Catalog.tool(named: "calc") != nil)
        #expect(Catalog.tools.map(\.name).suffix(3) == ["sum", "calc", "date_diff"])
    }

    @Test func annotationsAndSchema() throws {
        #expect(tool.annotations == ToolAnnotations(title: "Exact calculation", readOnly: true, destructive: false, idempotent: true))
        let schema = try #require(tool.inputSchema.objectValue)
        #expect(schema["type"] == "object")
        #expect(schema["required"] == ["expression"])
        #expect(schema["additionalProperties"] == false)
        #expect(schema["properties"]?.objectValue?.keys == ["expression"])
        #expect(schema["properties"]?.objectValue?["expression"]?.objectValue?["type"] == "string")
    }

    @Test func readIsADetail() throws {
        #expect(tool.detailKeys == ["read"])
        let result = try calc("1/3")
        #expect(result.keys == ["result", "exact", "fraction", "read"])
        #expect(tool.withoutDetails(result) == ["result": .number("0.333333333333333"), "exact": false, "fraction": "1/3"])
        #expect(tool.withoutDetails(result).keys == ["result", "exact", "fraction"])
    }

    // MARK: The probe's tasks

    /// The tallies of the probe in ADR-0007: four of a session's own, with suffixes, and two shared ones.
    private func probeState() throws -> TallyTestState {
        let state = TallyTestState()
        for (name, value, count) in [
            ("errors-k3f9", "37", 37), ("requests-p2x7", "1250", 1250), ("effort-a1b2", "47.5", 12),
            ("tokens-m4q8", "312400", 9), ("build-errors", "18", 18), ("builds", "240", 240),
        ] {
            try state.call("tally_create", ["name": .string(name), "shared": true])
            try state.call("tally_set", ["name": .string(name), "value": .string(value), "count": .number(String(count))])
        }
        return state
    }

    static let probeCases: [(String, JSONObject)] = [
        // T1: a rate from two tallies
        ("{errors-k3f9} / {requests-p2x7} * 100", [
            "result": .number("2.96"), "read": "({errors-k3f9} / {requests-p2x7}) * 100",
            "tallies": [
                ["name": "errors-k3f9", "of": "value", "value": 37],
                ["name": "requests-p2x7", "of": "value", "value": 1250],
            ],
        ]),
        // T2: the mean of a tally, 47.5 / 12 = 95/24 = 3.9583333…
        ("{effort-a1b2} / {effort-a1b2:count}", [
            "result": .number("3.95833333333333"), "exact": false, "fraction": "95/24",
            "read": "{effort-a1b2} / {effort-a1b2:count}",
            "tallies": [
                ["name": "effort-a1b2", "of": "value", "value": .number("47.5")],
                ["name": "effort-a1b2", "of": "count", "value": 12],
            ],
        ]),
        // T3: what is left of a budget, 97600 / 4100 = 976/41 = 23.80487804878048780…
        ("(410k - {tokens-m4q8}) / 410k * 100", [
            "result": .number("23.8048780487805"), "exact": false, "fraction": "976/41",
            "read": "((410000 - {tokens-m4q8}) / 410000) * 100",
            "tallies": [["name": "tokens-m4q8", "of": "value", "value": 312400]],
        ]),
        // T4: rows per second, 1234567 / 9000 = 137.1741111…
        ("1234567 / (2.5 * 3600)", [
            "result": .number("137.174111111111"), "exact": false, "fraction": "1234567/9000",
            "read": "1234567 / (2.5 * 3600)",
        ]),
        // T5 without the root: 3.5^2 + 12^2
        ("3.5^2 + 12^2", ["result": .number("156.25"), "read": "(3.5 ^ 2) + (12 ^ 2)"]),
        // T6: 1000 * 1.045^10 = 1552.969421732897124632822265625, exactly, then rounded to cents
        ("round(1000 * 1.045^10, 2)", ["result": .number("1552.97"), "read": "round(1000 * (1.045 ^ 10), 2)"]),
        // T7: the square of -20
        ("(-20)^2", ["result": 400, "read": "(-20) ^ 2"]),
        // T8: 19% VAT
        ("2450.80 * 1.19", ["result": .number("2916.452"), "read": "2450.8 * 1.19"]),
        // T9: two shared tallies, which have no suffix
        ("{build-errors} / {builds}", [
            "result": .number("0.075"), "read": "{build-errors} / {builds}",
            "tallies": [
                ["name": "build-errors", "of": "value", "value": 18],
                ["name": "builds", "of": "value", "value": 240],
            ],
        ]),
    ]

    @Test(arguments: CalcToolTests.probeCases)
    func probeTask(expression: String, expected: JSONObject) throws {
        let state = try probeState()
        let result = try calc(expression, in: state)
        #expect(result == expected, "\(expression)")
        #expect(result.keys == expected.keys, "\(expression)")
    }

    /// T5 as the probe wrote it: there is no square root, and the error says so.
    @Test func probeTaskWithARootIsRefused() throws {
        let error = try #require(failure("sqrt(3.5^2 + 12^2)"))
        #expect(error.message.hasPrefix("There is no square root in calc: \"sqrt\" at character 1 of \"sqrt(3.5^2 + 12^2)\"."))
        #expect(error.message.contains("no roots and no fractional powers"))
    }

    // MARK: Exact arithmetic

    static let valueCases: [(String, String)] = [
        ("1/3*3", "1"), ("0.1 + 0.2", "0.3"), ("-2^2", "-4"), ("2^3^2", "512"), ("2^-1", "0.5"), ("0^0", "1"),
        ("2 * -3", "-6"), ("1 - -2", "3"), ("-0", "0"), ("7 - 7", "0"), ("abs(-2.5)", "2.5"), ("abs(3)", "3"),
        ("min(4, -1, 2)", "-1"), ("max(4, -1, 2)", "4"), ("max(1/3, 0.3)", "0.333333333333333"),
        ("round(2.5, 0)", "3"), ("round(-2.5, 0)", "-3"), ("round(12.5, 2)", "12.5"), ("round(1234, -2)", "1200"),
        ("round(1/3, 2)", "0.33"), ("round(2/3, 5)", "0.66667"), ("1000 * 1.045^10", "1552.969421732897124632822265625"),
        ("410k / 1M", "0.41"), ("1.5e3 * 2", "3000"), ("(1 + 2) * 3", "9"), ("6 / 2 * 3", "9"), ("2 ** 10", "1024"),
        ("6 × 7 ÷ 2 − 1", "20"), ("1e-128 * 1", "0." + String(repeating: "0", count: 127) + "1"),
        // Intermediate values beyond the result's range are fine.
        ("10^200 / 10^199", "10"), ("1e-100 * 1e-100 * 1e150", "0." + String(repeating: "0", count: 49) + "1"),
    ]

    @Test(arguments: CalcToolTests.valueCases)
    func worksOutExactly(expression: String, value: String) throws {
        let result = try calc(expression)
        #expect(result["result"] == .number(value), "\(expression): \(result)")
    }

    @Test func roundsOnceAtTheEnd() throws {
        let third = try calc("1/3")
        #expect(third == ["result": .number("0.333333333333333"), "exact": false, "fraction": "1/3", "read": "1 / 3"])
        #expect(third.keys == ["result", "exact", "fraction", "read"])
        #expect(try calc("-2/3") == ["result": .number("-0.666666666666667"), "exact": false, "fraction": "-2/3", "read": "-2 / 3"])
        // Whole units when the integer part is longer than 15 digits; the fraction keeps the rest.
        #expect(try calc("10^20 / 3") == [
            "result": .number("33333333333333333333"), "exact": false, "fraction": "100000000000000000000/3",
            "read": "(10 ^ 20) / 3",
        ])
        // A whole number past 38 digits is rounded; its fraction is the digits alone.
        let power = try calc("2^200")
        #expect(power["exact"] == false)
        #expect(power["fraction"] == "1606938044258990275541962092341162602522202993782792835301376")
        #expect(power["result"] == .number("16069380442589902755419620923411626025" + String(repeating: "0", count: 23)))
    }

    @Test func leavesOutAVeryLongFraction() throws {
        // 1/3^210 has a denominator of 101 digits.
        let result = try calc("1 / 3^210")
        #expect(result["exact"] == false)
        #expect(result["fraction"] == nil)
        #expect(result.keys == ["result", "exact", "read"])
        // 1/3^209 still fits: 100 digits.
        #expect(try calc("1 / 3^209")["fraction"]?.stringValue?.count == 102)
    }

    /// The 1000 characters of `1+1+…+1` make a tree about 500 levels deep: evaluated without recursion, so the
    /// 512 KB stack of a test thread is enough (a recursive walk overflowed it in a debug build).
    @Test func evaluatesTheLongestChainWithoutRecursion() throws {
        let sum = Array(repeating: "1", count: 500).joined(separator: "+")
        #expect(sum.count == 999)
        #expect(try calc(sum)["result"] == 500)
        // read grows with the chain (about 2000 characters); an MCP result leaves it out (ADR-0008).
        #expect(JSONWriter.write(tool.withoutDetails(try calc(sum))) == #"{"result":500}"#)
        let difference = "1000" + String(repeating: "-2", count: 498)
        #expect(difference.count == 1000)
        #expect(try calc(difference)["result"] == 4)
        let product = try calc("2" + String(repeating: "*2", count: 499))  // 2^500, 151 digits
        #expect(product["result"] == .number("32733906078961418700131896968275991522" + String(repeating: "0", count: 113)))
        #expect(product["exact"] == false)
        #expect(product["fraction"] == nil)  // more than 100 digits
    }

    // MARK: Tallies

    @Test func readsValuesAndCountsInOrderOfFirstAppearance() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "a", "shared": true])
        try state.call("tally_set", ["name": "a", "value": .number("2.5"), "count": 4])
        try state.call("tally_create", ["name": "b", "shared": true])
        try state.call("tally_set", ["name": "b", "value": 10, "count": 3])
        let result = try calc("{b:count} + {a} * {a:count} + {b} - {a} + {b:count} + {a:value}", in: state)
        #expect(result["result"] == 26)  // 3 + 2.5 * 4 + 10 - 2.5 + 3 + 2.5
        #expect(result["read"] == "(({b:count} + ({a} * {a:count}) + {b}) - {a}) + {b:count} + {a}")
        // Each (name, of) once, in the order of first appearance; {a:value} is {a}.
        #expect(result["tallies"] == [
            ["name": "b", "of": "count", "value": 3],
            ["name": "a", "of": "value", "value": .number("2.5")],
            ["name": "a", "of": "count", "value": 4],
            ["name": "b", "of": "value", "value": 10],
        ])
    }

    @Test func aRoundedTallyMakesTheResultInexact() throws {
        let state = TallyTestState()
        try plant(TallyTest.tally("rough", value: "2.5", count: 2, exact: false), in: state)
        try plant(TallyTest.tally("fine", value: "3", count: 1), in: state)

        // The result itself needed no rounding: exact false, no fraction, the tally marked.
        let doubled = try calc("{rough} * 2", in: state)
        #expect(doubled == [
            "result": 5, "exact": false, "read": "{rough} * 2",
            "tallies": [["name": "rough", "of": "value", "value": .number("2.5"), "exact": false]],
        ])
        #expect(doubled.keys == ["result", "exact", "read", "tallies"])
        #expect(doubled["tallies"]?.arrayValue?.first?.objectValue?.keys == ["name", "of", "value", "exact"])

        // Rounded here as well: the fraction undoes this rounding.
        let third = try calc("{rough} / 3 + {fine}", in: state)
        #expect(third == [
            "result": .number("3.83333333333333"), "exact": false, "fraction": "23/6", "read": "({rough} / 3) + {fine}",
            "tallies": [
                ["name": "rough", "of": "value", "value": .number("2.5"), "exact": false],
                ["name": "fine", "of": "value", "value": 3],
            ],
        ])

        // A count is always exact.
        #expect(try calc("{rough:count} * 2", in: state) == [
            "result": 4, "read": "{rough:count} * 2", "tallies": [["name": "rough", "of": "count", "value": 2]],
        ])
    }

    @Test func anUnknownNameComputesNothingAndSuggestsNoCreation() throws {
        let state = TallyTestState()
        let empty = try #require(failure("{items} + 1", in: state))
        #expect(empty.message == """
            {items} at character 1 of "{items} + 1": there is no tally named "items". It may never have been created \
            (check the spelling), it may have been dropped, or it may have expired: macOS deletes tallies that have \
            not changed for about three days. No tallies exist right now. Nothing was computed.
            """)
        #expect(empty.details == ["name": "items", "existing": []])
        #expect(!FileManager.default.fileExists(atPath: state.url.path))  // reading creates no folder

        try state.call("tally_create", ["name": "other", "shared": true])
        let plain = try #require(failure("{other} / {items}", in: state))
        #expect(plain.message.hasPrefix("{items} at character 11 of \"{other} / {items}\": there is no tally named \"items\"."))
        #expect(plain.message.hasSuffix("details.existing lists the tallies that exist. Nothing was computed."))
        #expect(plain.details == ["name": "items", "existing": ["other"]])

        let mine = try #require(try state.call("tally_create", ["name": "items"])["name"]?.stringValue)
        let one = try #require(failure("{items} + 1", in: state))
        #expect(one.message.hasSuffix("""
            tally_create adds a random suffix to every name unless shared: true is passed, and a tally whose name \
            starts with "items-" exists: "\(mine)" (created 2026-11-08T09:30:00Z, value 0, count 0). It may belong \
            to another session: write its full name, suffix included, only if you know it is the one you mean \
            (compare its created time with when you created yours). Nothing was computed. details.matching shows \
            it; details.existing lists the tallies that exist.
            """), "\(one.message)")
        #expect(one.details?.keys == ["name", "matching", "existing"])

        try state.call("tally_create", ["name": "items"])
        let two = try #require(failure("1 + {items:count} * {items}", in: state))
        #expect(two.message.hasPrefix("{items:count} at character 5 of"), "\(two.message)")
        #expect(two.message.contains("""
            They may belong to other sessions: write the full name, suffix included, only for the one you know you \
            mean (compare its created time with when you created yours). Nothing was computed.
            """), "\(two.message)")

        for error in [empty, plain, one, two] {
            let lowered = error.message.lowercased()
            #expect(!lowered.contains("create a new") && !lowered.contains("create it"), "\(error.message)")
            #expect(!lowered.contains("with tally_create"), "\(error.message)")
        }
        // The first unknown name in the text is the one reported.
        #expect(failure("{nope} + {items}", in: state)?.details?["name"] == "nope")
    }

    @Test func anUnreadableTallyIsAnErrorThatNamesIt() throws {
        let state = TallyTestState()
        try state.plant("broken.json", "not json")
        let error = try #require(failure("{broken} + 1", in: state))
        #expect(error.message.hasPrefix("The tally \"broken\" cannot be read: it is not a tally file"))
        #expect(error.message.hasSuffix(" Nothing was computed."))
        #expect(error.details?["name"] == "broken")
    }

    @Test func aTallyFileThatCannotBeOpenedComputesNothing() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "locked", "shared": true])
        let file = state.file("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let error = try #require(failure("{locked} + 1", in: state))
        #expect(error.message.hasPrefix("Cannot read \(file.path)"), "\(error.message)")
        #expect(error.message.hasSuffix(" Nothing was computed."), "\(error.message)")
    }

    @Test func anExpressionWithoutTalliesNeverTouchesTheStateFolder() throws {
        let state = TallyTestState()
        _ = try calc("1 + 2", in: state)
        _ = failure("1 / 0", in: state)
        #expect(!FileManager.default.fileExists(atPath: state.url.path))
    }

    @Test func neverChangesATally() throws {
        let state = try probeState()
        let before = try Data(contentsOf: state.file("effort-a1b2"))
        _ = try calc("{effort-a1b2} / {effort-a1b2:count}", in: state)
        #expect(try Data(contentsOf: state.file("effort-a1b2")) == before)
    }

    /// Eight references to seven tallies: the command line gets them all, an MCP result the first five and how many
    /// there are (ADR-0008).
    @Test func anMCPResultListsFiveTalliesAndHowManyThereAre() throws {
        let state = TallyTestState()
        for (index, name) in ["a", "b", "c", "d", "e", "f", "g"].enumerated() {
            try state.call("tally_create", ["name": .string(name), "shared": true])
            try state.call("tally_add", ["name": .string(name), "amount": .number(String(index + 1))])
        }
        let result = try calc("{a} + {b} + {c:count} + {d} + {e} + {f} + {g} / 3 + {a:count}", in: state)
        let all: [JSONValue] = [
            ["name": "a", "of": "value", "value": 1], ["name": "b", "of": "value", "value": 2],
            ["name": "c", "of": "count", "value": 1], ["name": "d", "of": "value", "value": 4],
            ["name": "e", "of": "value", "value": 5], ["name": "f", "of": "value", "value": 6],
            ["name": "g", "of": "value", "value": 7], ["name": "a", "of": "count", "value": 1],
        ]
        // 1 + 2 + 1 + 4 + 5 + 6 + 7/3 + 1 = 67/3
        #expect(result == [
            "result": .number("22.3333333333333"), "exact": false, "fraction": "67/3",
            "read": "{a} + {b} + {c:count} + {d} + {e} + {f} + ({g} / 3) + {a:count}", "tallies": .array(all),
        ])
        let mcp = tool.withoutDetails(result)
        #expect(mcp == [
            "result": .number("22.3333333333333"), "exact": false, "fraction": "67/3",
            "tallies": .array(Array(all.prefix(5))), "tallies_total": 8,
        ])
        #expect(mcp.keys == ["result", "exact", "fraction", "tallies", "tallies_total"])
        // Through `any Tool`, as the server and `abakus call --without-details` hold it, calc's own version runs.
        let anyTool: any Tool = tool
        #expect(anyTool.withoutDetails(result) == mcp)

        // Five references: all of them, and no count.
        let five = tool.withoutDetails(try calc("{a} + {b} + {c} + {d} + {e:count}", in: state))
        #expect(five.keys == ["result", "tallies"])
        #expect(five["tallies"]?.arrayValue?.count == 5)
    }

    // MARK: Notes

    static let noteCases: [(String, [String])] = [
        ("-2^2", [
            """
            "-2^2" at character 1 was read as -(2^2): the power comes first, then the minus, as in mathematics. Excel \
            and bc apply the minus first; for that reading, write (-2)^2.
            """,
        ]),
        ("2^3^2", [
            """
            "2^3^2" at character 1 was read as 2^(3^2): powers group from the right, as in mathematics. Excel groups \
            them from the left; for that reading, write (2^3)^2.
            """,
        ]),
        // The agent's own spelling and spacing stay; the parentheses go around what it wrote.
        ("10 - \u{2212}2 ** 2", [
            """
            "\u{2212}2 ** 2" at character 6 was read as \u{2212}(2 ** 2): the power comes first, then the minus, as \
            in mathematics. Excel and bc apply the minus first; for that reading, write (\u{2212}2) ** 2.
            """,
        ]),
        // A parenthesised base, and a minus in a group or before an exponent.
        ("-(1 + 1)^2", [
            """
            "-(1 + 1)^2" at character 1 was read as -((1 + 1)^2): the power comes first, then the minus, as in \
            mathematics. Excel and bc apply the minus first; for that reading, write (-(1 + 1))^2.
            """,
        ]),
        ("3 * (-2^2)", [
            """
            "-2^2" at character 6 was read as -(2^2): the power comes first, then the minus, as in mathematics. Excel \
            and bc apply the minus first; for that reading, write (-2)^2.
            """,
        ]),
        ("2^-3^2", [
            """
            "-3^2" at character 3 was read as -(3^2): the power comes first, then the minus, as in mathematics. Excel \
            and bc apply the minus first; for that reading, write (-3)^2.
            """,
        ]),
        // A longer chain is one chain, with every parenthesis written out.
        ("2 ** 3 ** 2 ^ 1", [
            """
            "2 ** 3 ** 2 ^ 1" at character 1 was read as 2 ** (3 ** (2 ^ 1)): powers group from the right, as in \
            mathematics. Excel groups them from the left; for that reading, write ((2 ** 3) ** 2) ^ 1.
            """,
        ]),
        // Beyond four operands, the readings are described.
        ("2^1^1^1^1", [
            """
            In "2^1^1^1^1" at character 1, powers group from the right, as in mathematics. Excel groups them from the \
            left; for that reading, write the parentheses yourself, as in (2^3)^2.
            """,
        ]),
        // Both kinds: one note each, the minus first.
        ("-2^3^2", [
            """
            "-2^3^2" at character 1 was read as -(2^3^2): the power comes first, then the minus, as in mathematics. \
            Excel and bc apply the minus first; for that reading, write (-2)^3^2.
            """,
            """
            "2^3^2" at character 2 was read as 2^(3^2): powers group from the right, as in mathematics. Excel groups \
            them from the left; for that reading, write (2^3)^2.
            """,
        ]),
        // Several: how many, the first one, and advice for all of them.
        ("1 + 2^2^2 + 3^3^3", [
            """
            The expression has 2 chains of powers. The first, "2^2^2" at character 5, was read as 2^(2^2): powers \
            group from the right, as in mathematics. Excel groups them from the left; for that reading, write the \
            parentheses yourself, as in (2^2)^2.
            """,
        ]),
        // Parentheses around an exponent end a chain: two chains, the outer one first.
        ("2^2^(1^1^1)", [
            """
            The expression has 2 chains of powers. The first, "2^2^(1^1^1)" at character 1, was read as \
            2^(2^(1^1^1)): powers group from the right, as in mathematics. Excel groups them from the left; for that \
            reading, write the parentheses yourself, as in (2^2)^(1^1^1).
            """,
        ]),
        ("5 - -2^2 * 3 + -1^2", [
            """
            The expression has 2 powers with a leading minus. The first, "-2^2" at character 5, was read as -(2^2): \
            the power comes first, then the minus, as in mathematics. Excel and bc apply the minus first; for that \
            reading, put the minus and the base in parentheses, as in (-2)^2.
            """,
        ]),
    ]

    @Test(arguments: CalcToolTests.noteCases)
    func notesWhereConventionsDiffer(expression: String, notes: [String]) throws {
        let result = try calc(expression)
        #expect(result["notes"] == .array(notes.map(JSONValue.string)), "\(expression)")
        // Over MCP too: notes take the place of read.
        #expect(tool.withoutDetails(result).keys == ["result", "notes"], "\(expression)")
    }

    /// Parentheses the agent wrote settle the reading; mixed chains of * and / or + and - read the same everywhere.
    @Test(arguments: [
        "-(2^2)", "(-2)^2", "2^(3^2)", "(2^3)^2", "-(2^(3^2))", "((-2))^2", "-((2^2))", "(2^(-3))^2", "2^-1", "-2 * 3",
        "2 * -3", "10 / 4 * 2", "37 / 1250 * 100", "1 - 2 + 3", "8 / 4 / 2", "1 - 2 - 3", "-abs(2)", "--2", "2^2",
        "(1+1)^(2^2)",
    ])
    func noNoteWhereTheReadingIsSettled(expression: String) throws {
        #expect(try calc(expression)["notes"] == nil, "\(expression)")
    }

    @Test func notesHoldForTallies() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "errors-k3f9", "shared": true])
        try state.call("tally_add", ["name": "errors-k3f9", "amount": 3])
        let result = try calc("-{errors-k3f9}^2", in: state)
        #expect(result["result"] == -9)
        #expect(result["notes"] == [
            """
            "-{errors-k3f9}^2" at character 1 was read as -({errors-k3f9}^2): the power comes first, then the minus, \
            as in mathematics. Excel and bc apply the minus first; for that reading, write (-{errors-k3f9})^2.
            """,
        ])
        #expect(result.keys == ["result", "notes", "read", "tallies"])
        #expect(tool.withoutDetails(result).keys == ["result", "notes", "tallies"])
        #expect(try calc("(-{errors-k3f9})^2", in: state)["notes"] == nil)
    }

    /// A long occurrence is cut in the middle, and the readings are described instead of written out.
    @Test func aLongOccurrenceIsCut() throws {
        let base = "(" + (1...11).map(String.init).joined(separator: " + ") + ")"
        #expect(try calc("-\(base)^2")["notes"] == [
            """
            In "-(1 + 2 + 3 + 4 + 5 … 8 + 9 + 10 + 11)^2" at character 1, the power comes first, then the minus, as in \
            mathematics. Excel and bc apply the minus first; for that reading, put the minus and the base in \
            parentheses, as in (-2)^2.
            """,
        ])
        #expect(try calc("1 + \(base)^2^1")["notes"] == [
            """
            In "(1 + 2 + 3 + 4 + 5 +… + 9 + 10 + 11)^2^1" at character 5, powers group from the right, as in \
            mathematics. Excel groups them from the left; for that reading, write the parentheses yourself, as in \
            (2^3)^2.
            """,
        ])
    }

    /// One note per kind, of the same size however many occurrences there are (ADR-0008).
    @Test func notesDoNotGrowWithTheExpression() throws {
        func notes(_ terms: Int) throws -> [String] {
            let expression = Array(repeating: "-2^2^1", count: terms).joined(separator: " + ")
            return try #require(calc(expression)["notes"]?.arrayValue).compactMap(\.stringValue)
        }
        let two = try notes(2)
        #expect(two.count == 2)
        // 111 terms make 996 characters: the same notes, but for the count.
        #expect(try notes(111) == two.map { $0.replacingOccurrences(of: "has 2 ", with: "has 111 ") })
    }

    // MARK: Errors

    static let evaluationErrorCases: [(String, String)] = [
        ("1 + 10 / (5 - 5)", """
            Division by zero at character 8 of "1 + 10 / (5 - 5)": the divisor (5 - 5) is 0. While the divisor is 0, \
            the result has no value: report that, or change the divisor.
            """),
        ("1/0", "Division by zero at character 2 of \"1/0\": the divisor is 0. While"),
        ("0^-1", """
            0 raised to a negative power at character 2 of "0^-1": the base is 0, and 0 ^ -n is 1 / 0^n, a division \
            by zero. While the base is 0, the result has no value: report that, or change the base.
            """),
        ("(1 - 1) ^ -2", "0 raised to a negative power at character 9 of \"(1 - 1) ^ -2\": the base (1 - 1) is 0,"),
        ("2 ^ 0.5", """
            The power at character 3 of "2 ^ 0.5" has the exponent 0.5, which is not a whole number: calc has no \
            roots and no fractional powers. ^ takes whole-number exponents from -9999 to 9999.
            """),
        ("2^(1/2)", "The power at character 2 of \"2^(1/2)\" has the exponent (1 / 2) = 1/2, which is not a whole number"),
        ("2^10000", """
            The power at character 2 of "2^10000" has the exponent 10000, outside -9999 to 9999, the exponents ^ \
            takes. Use an exponent in that range.
            """),
        ("1^-(10^9)", "The power at character 2 of \"1^-(10^9)\" has the exponent -(10 ^ 9) = -1000000000, outside"),
        // Operands too long to repeat: a number as written, anything else cut, with the size of its value.
        ("2^1e-50", "The power at character 2 of \"2^1e-50\" has the exponent 1e-50, which is not a whole number"),
        ("1^(10^1999)", "has the exponent (10 ^ 1999) = a whole number of 2000 digits, outside -9999 to 9999"),
        ("2^(1 / 10^50)", "has the exponent (1 / (10 ^ 50)) = a fraction of 1 digit over 51 digits, which is not"),
        ("2^(-1 / 10^50)", "has the exponent (-1 / (10 ^ 50)) = a negative fraction of 1 digit over 51 digits,"),
        ("2^(1/3 + 1/7 + 1/11 + 1/13 + 1/17 + 1/19)", "has the exponent ((1 / 3) + (1 / 7) +…1 / 17) + (1 / 19)) = 732790/969969, which"),
        // Too many digits: the advice depends on the operation.
        ("9^9999", """
            The power at character 2 of "9^9999" gives a value with more than 2000 digits in its numerator or \
            denominator: calc keeps every value as an exact fraction and stops at 2000 digits. Use a smaller \
            exponent, or a base with fewer digits.
            """),
        ("10^1000 * 10^1000", """
            The multiplication at character 9 of "10^1000 * 10^1000" gives a value with more than 2000 digits in its \
            numerator or denominator: calc keeps every value as an exact fraction and stops at 2000 digits. Use \
            smaller operands, or round an inner part first with round(x, places).
            """),
        ("round(10^1950 + 1/3, 128)", """
            round at character 1 of "round(10^1950 + 1/3, 128)" gives a value with more than 2000 digits in its \
            numerator or denominator: calc keeps every value as an exact fraction and stops at 2000 digits. Round to \
            fewer decimal places, or round a smaller value.
            """),
        ("round(1, 0.5)", """
            round at character 1 of "round(1, 0.5)" has the places 0.5, which is not a whole number. Write a whole \
            number from -165 to 128: round(x, 2) for two decimal places, round(x, 0) for a whole number, round(x, -3) \
            for thousands.
            """),
        ("2 * round(1, 129)", "round at character 5 of \"2 * round(1, 129)\" has the places 129, outside -165 to 128,"),
        ("round(1, -166)", "round at character 1 of \"round(1, -166)\" has the places -166, outside -165 to 128"),
        // Out of range: by how much, and the power of ten that brings the result back.
        ("10^164 * 10", """
            The result is too large for exact decimal arithmetic, which ends below 10^165: it lies between 10^165 and \
            10^166. Values on the way may be larger, up to 2000 digits; only the result has to fit. To see its \
            leading digits, divide the whole expression by 10^165, as in (…) / 10^165; that result lies between 1 \
            and 10.
            """),
        ("10^200 - 1", "it lies between 10^199 and 10^200."),
        ("-(10^200) * 3", "it lies between -10^201 and -10^200. Values"),
        ("-(10^200) * 3 ", "divide the whole expression by 10^200, as in (…) / 10^200; that result lies between -10 and -1."),
        ("1e-128 / 3", """
            The result is not 0, but it lies between 10^-129 and 10^-128 and rounds to 0 at 10^-128, the finest step \
            of exact decimal arithmetic. Values on the way may be smaller, with up to 2000 digits in a denominator; \
            only the result has to fit. To see its leading digits, multiply the whole expression by 10^129, as in \
            (…) * 10^129; that result lies between 1 and 10.
            """),
        ("10^-500", "it lies between 10^-500 and 10^-499 and rounds to 0"),
        ("1 / (10^1999 * 9)", """
            it lies between 10^-2000 and 10^-1999 and rounds to 0 at 10^-128, the finest step of exact decimal \
            arithmetic. Values on the way may be smaller, with up to 2000 digits in a denominator; only the result \
            has to fit. It cannot be brought into range: that takes a factor of 10^2000, which has more than 2000 \
            digits.
            """),
    ]

    /// Each expected text is the start of the message, or a part of it when it starts in lowercase.
    @Test(arguments: CalcToolTests.evaluationErrorCases)
    func evaluationErrorsSayWhereAndWhatToDo(expression: String, expected: String) throws {
        let error = try #require(failure(expression), "\(expression)")
        let whole = expected.first?.isLowercase == true || expected.first == "("
        #expect(whole ? error.message.contains(expected) : error.message.hasPrefix(expected), "\(expression): \(error.message)")
        #expect(error.details == nil)  // no tallies, no details
    }

    /// The scaling an out-of-range error suggests works.
    @Test func theSuggestedPowerOfTenBringsTheResultIntoRange() throws {
        #expect(try calc("(7 * 10^-500) * 10^500")["result"] == 7)
        #expect(try calc("(-(10^200) * 3) / 10^200")["result"] == -3)
        #expect(try calc("(1e-128 / 3) * 10^129")["result"] == .number("3.33333333333333"))
    }

    @Test func underflowStartsBelowHalfTheSmallestStep() throws {
        // 0.5e-128 and up round to 1e-128: not an error, but not exact either.
        let half = try calc("1e-128 / 2")
        #expect(half["result"] == .number("0." + String(repeating: "0", count: 127) + "1"))
        #expect(half["exact"] == false)
        #expect(failure("1e-128 / 2.000001")?.message.hasPrefix("The result is not 0, but it lies between 10^-129") == true)
    }

    @Test func errorsAfterReadingTalliesShowThem() throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "requests", "shared": true])
        try state.call("tally_create", ["name": "errors", "shared": true])
        try state.call("tally_add", ["name": "errors", "amount": 2])
        let error = try #require(failure("{errors} / {requests} * 100", in: state))
        #expect(error.message == """
            Division by zero at character 10 of "{errors} / {requests} * 100": the divisor {requests} is 0. While the \
            divisor is 0, the result has no value: report that, or calculate again once something has been added to \
            the tally "requests".
            """)
        #expect(error.details == ["tallies": [
            ["name": "errors", "of": "value", "value": 2],
            ["name": "requests", "of": "value", "value": 0],
        ]])
    }

    @Test func aDivisorOfSeveralTalliesNamesThemAll() throws {
        let state = TallyTestState()
        for name in ["queued", "done", "errors"] {
            try state.call("tally_create", ["name": .string(name), "shared": true])
        }
        let error = try #require(failure("{errors} / ({queued:count} - {done})", in: state))
        #expect(error.message.hasSuffix("""
            the divisor ({queued:count} - {done}) is 0. While the divisor is 0, the result has no value: report that, \
            or calculate again once the tallies "queued" and "done" have changed (details.tallies has their values).
            """), "\(error.message)")
    }

    /// Errors are bounded too (ADR-0008): details.tallies lists five, then tallies_total, and the message names at
    /// most five tallies, pointing to details.tallies only when it has them all.
    @Test func errorsListFiveTalliesAndHowManyThereAre() throws {
        let state = TallyTestState()
        for name in ["a", "b", "c", "d", "e", "f", "g"] {
            try state.call("tally_create", ["name": .string(name), "shared": true])
        }
        try state.call("tally_add", ["name": "a", "amount": 2])
        let five: [JSONValue] = [
            ["name": "a", "of": "value", "value": 2], ["name": "b", "of": "value", "value": 0],
            ["name": "c", "of": "value", "value": 0], ["name": "d", "of": "value", "value": 0],
            ["name": "e", "of": "value", "value": 0],
        ]

        let all = try #require(failure("{a} / ({b} + {c} + {d} + {e} + {f} + {g:count})", in: state))
        #expect(all.message.hasSuffix("""
            calculate again once the tallies "b", "c", "d", "e", "f" and 1 more have changed.
            """), "\(all.message)")
        #expect(all.details == ["tallies": .array(five), "tallies_total": 7])
        #expect(all.details?.keys == ["tallies", "tallies_total"])

        // The divisor's tallies are among the five listed.
        let shown = try #require(failure("{a} / ({b} - {c}) + {d} + {e} + {f} + {g}", in: state))
        #expect(shown.message.hasSuffix("""
            calculate again once the tallies "b" and "c" have changed (details.tallies has their values).
            """), "\(shown.message)")
        #expect(shown.details == ["tallies": .array(five), "tallies_total": 7])

        // One of them is not.
        let hidden = try #require(failure("{a} + {b} + {c} + {d} + {e} + {f} / ({b} - {g})", in: state))
        #expect(hidden.message.hasSuffix("once the tallies \"b\" and \"g\" have changed."), "\(hidden.message)")
    }

    @Test func errorsInLongExpressionsQuoteAnExcerpt() throws {
        let expression = String(repeating: "1 + ", count: 30) + "2 / (3 - 3) + " + String(repeating: "4 + ", count: 30) + "5"
        let error = try #require(failure(expression))
        #expect(error.message.hasPrefix("Division by zero at character 123 of \"…"), "\(error.message)")
        #expect(error.message.contains("2 / (3 - 3)"), "\(error.message)")
        #expect(error.message.contains("…\": the divisor (3 - 3) is 0"), "\(error.message)")
    }

    @Test func parseErrorsComeFromTheParser() throws {
        #expect(failure("37 / 1250 %")?.message == """
            Unexpected "%" at character 11 of "37 / 1250 %": there is no % operator, and it is not modulo either. For \
            a percentage, multiply by 100 (37 / 1250 * 100); to add 10%, multiply by 1.1.
            """)
        #expect(failure("1,234 + 1")?.message.contains("thousands separators") == true)
    }

    // MARK: Arguments

    @Test func refusesUnknownMissingAndNonStringArguments() throws {
        #expect(failure(["expression": "1", "decimal": ","])?.message
            == "Unknown argument \"decimal\". calc takes \"expression\" (required).")
        #expect(failure(["expr": "1"])?.message.hasPrefix("Unknown argument \"expr\".") == true)
        let missing = try #require(failure([:]))
        #expect(missing.message == """
            Missing argument "expression": pass the formula as a string, e.g. {"expression": "{errors-k3f9} / \
            {requests-p2x7} * 100"}.
            """)
        #expect(failure(["expression": .null])?.message == missing.message)
        let number = try #require(failure(["expression": 42]))
        #expect(number.message.hasPrefix("expression must be a string with the formula, not a number; e.g. {\"expression\":"))
        #expect(failure(["expression": true])?.message.contains("not true;") == true)
        #expect(failure(["expression": ["1", "+", "2"]])?.message.contains("not a list") == true)
        #expect(failure(["expression": ""])?.message.contains("The expression is empty") == true)
    }

    // MARK: Helpers

    private func calc(_ expression: String, in state: TallyTestState = TallyTestState()) throws(ToolError) -> JSONObject {
        try tool.call(["expression": .string(expression)], in: state.context)
    }

    private func failure(_ expression: String, in state: TallyTestState = TallyTestState()) -> ToolError? {
        failure(["expression": .string(expression)], in: state)
    }

    private func failure(_ arguments: JSONObject, in state: TallyTestState = TallyTestState()) -> ToolError? {
        do {
            _ = try tool.call(arguments, in: state.context)
            return nil
        } catch {
            return error
        }
    }

    /// Writes a tally file as tally tools would, for states they cannot reach directly (a value rounded long ago).
    private func plant(_ tally: Tally, in state: TallyTestState) throws {
        try FileManager.default.createDirectory(at: state.tallies, withIntermediateDirectories: true)
        try tally.fileData().write(to: state.file(tally.name))
    }
}
