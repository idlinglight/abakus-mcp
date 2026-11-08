@testable import AbakusCore
import Foundation
import Testing

@Suite struct CalcParserTests {
    // MARK: Reading

    static let readCases: [(String, String)] = [
        // Operators, and parentheses around every binary operation except the outermost one
        ("1 + 2", "1 + 2"), ("1+2*3", "1 + (2 * 3)"), ("(1+2)*3", "(1 + 2) * 3"), ("1 - 2 - 3", "(1 - 2) - 3"),
        ("8 / 4 / 2", "(8 / 4) / 2"), ("1 - (2 - 3)", "1 - (2 - 3)"), ("((5))", "5"), ("  1  +  2  ", "1 + 2"),
        ("1000 * 1.045^10", "1000 * (1.045 ^ 10)"),
        // Signs and powers
        ("-2^2", "-(2 ^ 2)"), ("(-2)^2", "(-2) ^ 2"), ("2^3^2", "2 ^ (3 ^ 2)"), ("(2^3)^2", "(2 ^ 3) ^ 2"),
        ("2^-1", "2 ^ -1"), ("2 * -3", "2 * -3"), ("+5", "5"), ("-+5", "-5"), ("--5", "--5"), ("-0", "-0"),
        ("-(1 + 2)", "-(1 + 2)"), ("1 - -2", "1 - -2"), ("2 ^ -(3 ^ 2)", "2 ^ -(3 ^ 2)"),
        // Numbers in plain notation
        ("410k", "410000"), ("410K", "410000"), ("1.5M", "1500000"), ("2G", "2000000000"), ("3T", "3000000000000"),
        ("2.5e3", "2500"), (".5", "0.5"), ("2.5E-3", "0.0025"), ("1e+2", "100"), ("1e\u{2212}3", "0.001"),
        ("007", "7"), ("0.000", "0"), ("0e999999999", "0"),
        ("12345678901234567890123456789012345678", "12345678901234567890123456789012345678"),
        ("1" + String(repeating: "0", count: 50), "1" + String(repeating: "0", count: 50)),
        ("1e-128", "0." + String(repeating: "0", count: 127) + "1"),
        // Tallies
        ("{errors-k3f9} / {requests-p2x7} * 100", "({errors-k3f9} / {requests-p2x7}) * 100"),
        ("{ errors-k3f9 : count }", "{errors-k3f9:count}"), ("{builds:value}", "{builds}"),
        ("{2026-11-08}", "{2026-11-08}"), ("{a.b_c-d}^2", "{a.b_c-d} ^ 2"), ("-{a}", "-{a}"),
        // Functions
        ("round({a} / 3, 2)", "round({a} / 3, 2)"), ("round(1/3*3, 0)", "round((1 / 3) * 3, 0)"),
        ("max(1, 2, 3)", "max(1, 2, 3)"), ("min(4)", "min(4)"), ("abs(-5)", "abs(-5)"), ("-abs(5)", "-abs(5)"),
        ("round ( 2.5 , 0 )", "round(2.5, 0)"), ("max(1k,2)", "max(1000, 2)"), ("round({a},2)", "round({a}, 2)"),
        ("max(1 ,2)", "max(1, 2)"), ("abs(1 + 2) * 3", "abs(1 + 2) * 3"), ("max(min(1, 2), abs(-3))", "max(min(1, 2), abs(-3))"),
    ]

    @Test(arguments: CalcParserTests.readCases)
    func reads(expression: String, read: String) throws {
        #expect(try CalcParser.parse(expression).rendered == read, "\(expression)")
    }

    static let precedenceCases: [(String, String)] = [
        ("-2^2", "(neg (^ 2 2))"), ("(-2)^2", "(^ (neg 2) 2)"), ("2^3^2", "(^ 2 (^ 3 2))"), ("2^-1", "(^ 2 (neg 1))"),
        ("2 * -3", "(* 2 (neg 3))"), ("-2 * 3", "(* (neg 2) 3)"), ("1 + 2 * 3", "(+ 1 (* 2 3))"),
        ("1 - 2 - 3", "(- (- 1 2) 3)"), ("8 / 4 / 2", "(/ (/ 8 4) 2)"), ("2 * 3 ^ 2", "(* 2 (^ 3 2))"),
        ("2^-3^2", "(^ 2 (neg (^ 3 2)))"), ("-{a}^2", "(neg (^ {a} 2))"), ("1 - -2", "(- 1 (neg 2))"),
        ("6 / 2 * 3", "(* (/ 6 2) 3)"), ("1 + 2 - 3 + 4", "(+ (- (+ 1 2) 3) 4)"), ("-abs(2)^2", "(neg (^ (abs 2) 2))"),
        ("2 ^ 2 * 3", "(* (^ 2 2) 3)"), ("+-+-2", "(neg (neg 2))"),
    ]

    @Test(arguments: CalcParserTests.precedenceCases)
    func precedence(expression: String, expected: String) throws {
        #expect(shape(try CalcParser.parse(expression)) == expected, "\(expression)")
    }

    static let spellingCases: [(String, String)] = [
        ("6 \u{2212} 2", "6 - 2"), ("\u{2212}2", "-2"), ("6 \u{00D7} 2", "6 * 2"), ("6 \u{00B7} 2", "6 * 2"),
        ("6 \u{00F7} 2", "6 / 2"), ("2 ** 3", "2 ^ 3"), ("2**-1", "2 ^ -1"), ("1\t+\n2", "1 + 2"),
        ("1\u{00A0}+\u{2009}2", "1 + 2"), ("2^3**2", "2 ^ (3 ^ 2)"),
        // "·" is a multiplication unless it stands directly between two digits.
        ("3 \u{00B7}4", "3 * 4"), ("3\u{00B7} 4", "3 * 4"), ("2\u{00B7}{x}", "2 * {x}"), ("{a}\u{00B7}2", "{a} * 2"),
        ("5k\u{00B7}2", "5000 * 2"), ("(1)\u{00B7}(2)", "1 * 2"),
    ]

    @Test(arguments: CalcParserTests.spellingCases)
    func acceptsOtherSpellings(expression: String, canonical: String) throws {
        let variant = try CalcParser.parse(expression)
        let plain = try CalcParser.parse(canonical)
        #expect(shape(variant) == shape(plain), "\(expression)")
        #expect(variant.rendered == canonical, "\(expression)")
    }

    @Test func positionsPointAtTokensAndOperators() throws {
        let sum = try CalcParser.parse("1 + 2 * 3")
        #expect(sum.position == 3)
        guard case .binary(.add, let one, let product) = sum.node else { Issue.record("\(sum)"); return }
        #expect(one.position == 1)
        #expect(product.position == 7)
        guard case .binary(.multiply, let two, let three) = product.node else { Issue.record("\(product)"); return }
        #expect(two.position == 5)
        #expect(three.position == 9)

        let negation = try CalcParser.parse("-2^2")
        #expect(negation.position == 1)
        guard case .negation(let power) = negation.node, case .binary(.power, let base, let exponent) = power.node else {
            Issue.record("\(negation)")
            return
        }
        #expect(power.position == 3)
        #expect(base.position == 2)
        #expect(exponent.position == 4)

        let call = try CalcParser.parse("  round( {a:count} , 2)")
        #expect(call.position == 3)
        guard case .call(.round, let arguments) = call.node else { Issue.record("\(call)"); return }
        #expect(arguments.map(\.position) == [10, 22])
        #expect(arguments[0].node == .tally(name: "a", of: .count))

        // Parentheses leave no node: the addition starts at its operator.
        #expect(try CalcParser.parse("(1 + 2)").position == 4)
        // Positions count characters, not bytes: "−" and "×" are one each.
        #expect(try CalcParser.parse("\u{2212}2 \u{00D7} 3").position == 4)
    }

    @Test func numbersKeepTheirLiteral() throws {
        for literal in ["410k", ".5", "2.5e3", "007", "1e\u{2212}3"] {
            let tree = try CalcParser.parse(" \(literal) ")
            guard case .number(let value, let kept) = tree.node else { Issue.record("\(literal)"); continue }
            #expect(kept == literal)
            #expect(value == (try NumberReader.read(.string(literal))))
        }
    }

    // MARK: Errors

    static let errorCases: [(String, [String])] = [
        // Empty
        ("", ["empty"]), ("   ", ["only whitespace"]),
        // Characters calc does not read
        ("37 / 1250 %", ["Unexpected \"%\" at character 11 of \"37 / 1250 %\"", "multiply by 100", "37 / 1250 * 100",
                         "1.1", "not modulo"]),
        ("2 + 3 =", ["\"=\" at character 7", "leave out the \"=\""]), ("= 5", ["character 1", "leave out"]),
        ("$5", ["\"$\" at character 1", "abs, round, min and max"]), ("5 \u{2013} 3", ["character 3", "write -"]),
        ("[1 + 2]", ["\"[\" at character 1", "parentheses"]), ("2 # 3", ["\"#\" at character 3"]),
        (". + 1", ["\".\" at character 1", "digits after"]),
        // Words
        ("sqrt(2)", ["no square root", "character 1"]), ("root(8)", ["no square root"]),
        ("2 * pi", ["\"pi\" at character 5", "no constants", "abs, round, min and max", "{errors-k3f9}"]),
        ("e * 2", ["\"e\" at character 1", "no constants"]),
        ("ABS(5)", ["lowercase", "character 1", "abs(x)"]), ("Round(1.5, 0)", ["lowercase", "round(x, places)"]),
        ("ERRORS / 2", ["\"ERRORS\" at character 1", "braces"]),
        ("log(5)", ["Unknown function \"log\" at character 1", "abs, round, min and max"]),
        ("errors-k3f9 / 5", ["character 1", "write {errors-k3f9}"]), ("1 + total", ["character 5", "{total}"]),
        ("Errors-k3f9 / 2", ["\"Errors\" at character 1", "write {errors-k3f9}: tally names are lowercase"]),
        // A word right after a number: a missing *, or the word's own message
        ("2abs(-3)", ["Missing operator at character 2", "2 * abs(-3)"]), ("3max(1, 2)", ["3 * max(1, 2)"]),
        ("2sqrt(4)", ["no square root", "character 2", "needs a * after 2"]),
        ("2pi", ["\"pi\" at character 2", "no constants", "needs a * after 2"]), ("2PI", ["no constants"]),
        ("2Abs(1)", ["lowercase", "abs(x)", "needs a * after 2"]),
        ("2log(5)", ["Unknown function \"log\" at character 2", "needs a * after 2"]),
        ("2exp(1)", ["Unknown function \"exp\" at character 2"]), ("5k(2)", ["Missing operator", "5k * (2)"]),
        ("5 x 3", ["\"x\" at character 3", "write *"]), ("abs 5", ["Expected \"(\" after abs at character 1", "abs(x)"]),
        // Implicit multiplication
        ("2(3+4)", ["Missing operator at character 2", "2 * (3+4)"]),
        ("2{errors-k3f9}", ["character 2", "2 * {errors-k3f9}"]), ("(1)(2)", ["character 4", "(1) * (2)"]),
        ("2 3", ["character 3", "2 * 3", "write it without spaces: 23"]), ("{a}{b}", ["character 4", "{a} * {b}"]),
        ("2 abs(3)", ["character 3", "2 * abs(3)"]), ("2^3 4", ["character 5", "2^3 * 4"]),
        // Thousands separators and decimal commas
        ("1,234", ["comma between two digits at character 2", "thousands separators", "write 1234", "1.234"]),
        ("max(1,234)", ["character 6", "1234", "space after it: 1, 234"]),
        ("round(1.5,2)", ["character 10", "without separators and with \".\" as the decimal mark", "1.5, 2"]),
        ("1,234,567", ["write 1234567;"]), ("1,234.5", ["write 1234.5;"]), ("1.234,5", ["without separators"]),
        // Numbers
        ("1_000", ["\"_\" at character 2", "Write 1000."]), ("10ms", ["\"ms\" after the number 10 at character 3", "no units"]),
        ("5x", ["\"x\" after the number 5", "write * (5 * 3)"]), ("5kg", ["\"kg\"", "one suffix"]),
        ("5m", ["lowercase \"m\" after 5 at character 2", "milli", "5M"]), ("5 m", ["milli", "5M"]),
        ("410 k", ["space before \"k\" at character 5", "write 410k"]), ("10 ms", ["\"ms\" after the number 10 at character 4", "no units"]),
        ("5.", ["5. ends in a decimal mark at character 2", "5.0", "(5)"]), ("1.2.3", ["\".\" at character 4", "one decimal mark"]),
        ("2e", ["exponent after \"e\" at character 2", "2.5e3", "no constant e"]), ("2e+ 1", ["exponent", "character 2"]),
        ("1e3k", ["exponent and a suffix", "character 1"]), ("5k3", ["\"3\" after the number 5k at character 3"]),
        ("2EUR", ["\"EUR\" after the number 2", "no units"]),
        ("1e400", ["The number 1e400 at character 1", "too large", "10^165"]),
        ("1 + 123456789012345678901234567890123456789", ["at character 5", "39 significant digits", "38"]),
        ("1.5e-128", ["10^-128", "128 decimal places"]),
        // Parentheses and braces
        ("(1 + 2", ["The \"(\" at character 1", "never closed"]), ("((1)", ["\"(\" at character 1", "never closed"]),
        ("1 + 2)", ["Unexpected \")\" at character 6", "no \"(\""]), ("round(1, 2", ["\"(\" of round at character 6"]),
        ("()", ["Empty parentheses at character 1"]), ("2 * ()", ["Empty parentheses at character 5"]),
        ("{errors", ["The \"{\" at character 1", "never closed"]), ("1 + }", ["\"}\" at character 5", "no \"{\""]),
        ("{a{b}}", ["\"{\" at character 1", "next \"{\" at character 3"]),
        // Tally references
        ("{Errors-K3F9}", ["lowercase", "character 1", "{errors-k3f9}"]), ("1 + {Errors:count}", ["character 5", "{errors:count}"]),
        ("{a:counts}", [":counts", "{a:count}", "{a}"]), ("{a:}", ["{a:count}", "{a}"]), ("{a:Count}", ["{a:count}"]),
        ("{}", ["no name", "character 1"]), ("{ :count}", ["no name"]),
        ("{a b}", ["\"a b\" at character 1", "lowercase letters, digits"]),
        ("{" + String(repeating: "a", count: 65) + "}", ["at most 64 characters"]),
        // Operators and operands
        ("2 + * 3", ["Unexpected \"*\" at character 5", "has to follow \"+\""]), ("* 3", ["character 1", "has to start with"]),
        ("2 +", ["ends after \"+\" at character 3"]), ("-", ["ends after \"-\" at character 1"]),
        ("2 * * 3", ["character 5", "** without a space"]), ("(1 + )", ["\")\" at character 6", "has to follow \"+\""]),
        ("1, 2", ["\",\" at character 2", "arguments of a function call"]), ("(1, 2)", ["\",\" at character 3"]),
        ("(, 1) + 2", ["\",\" at character 2", "nothing comes before it in the parentheses", "max(1, 2)", "thousands"]),
        ("2 * (,3)", ["\",\" at character 6", "nothing comes before it"]),
        // "·" between two digits: a raised decimal point or a multiplication
        ("1\u{00B7}5", ["\"·\" between two digits at character 2", "1.5 for a decimal", "1 * 5 for a multiplication"]),
        ("2 + 1\u{00B7}5k", ["character 6", "1.5k for a decimal", "1 * 5k"]),
        // Function calls
        ("abs()", ["abs takes 1 argument, but none was given at character 1"]), ("abs(1, 2)", ["but 2 were given"]),
        ("round(5)", ["round takes 2 arguments", "1 was given", "round(5, 0)"]),
        ("1 + round({a} / 3)", ["at character 5", "round({a} / 3, 0)"]), ("round(1, 2, 3)", ["3 were given", "round(1, 0)"]),
        ("max()", ["max takes at least 1 argument, but none was given", "max(a, b, …)"]),
        ("max(1, )", ["\")\" at character 8", "argument is missing"]), ("max(, 1)", ["\",\" at character 5", "argument is missing"]),
        ("max(1, , 2)", ["\",\" at character 8", "argument is missing"]),
    ]

    @Test(arguments: CalcParserTests.errorCases)
    func refuses(expression: String, fragments: [String]) {
        let text = message(expression)
        for fragment in fragments {
            #expect(text.contains(fragment), "\(expression): \(text)")
        }
    }

    @Test func errorsInLongExpressionsQuoteAnExcerpt() {
        let expression = String(repeating: "1 + ", count: 30) + "2 % 3 + " + String(repeating: "4 + ", count: 30) + "5"
        let text = message(expression)
        #expect(text.contains("Unexpected \"%\" at character 123 of \"…"), "\(text)")
        #expect(text.contains("2 % 3"), "\(text)")
        #expect(text.contains("…\": there is no % operator"), "\(text)")
        // Near the start, the excerpt starts with the expression.
        let early = message("2 % " + String(repeating: "1 + ", count: 30) + "1")
        #expect(early.contains("at character 3 of \"2 % 1 + "), "\(early)")
        // At the end, it ends with the expression.
        let late = message(String(repeating: "1 + ", count: 30) + "(")
        #expect(late.contains("ends after \"(\" at character 121 of \"…"), "\(late)")
        #expect(late.contains("+ 1 + (\": "), "\(late)")
    }

    @Test func errorsNeverSuggestTheDecimalArgument() {
        for expression in ["1,234", "1,5", "1.234.567", "1 000", "1e400", "5m", "1_000"] {
            let text = message(expression)
            #expect(!text.contains("decimal:"), "\(expression): \(text)")
            #expect(!text.contains("groups of three"), "\(expression): \(text)")
        }
    }

    /// A rewrite an error offers keeps the value of the reading it names: suffixes and exponents travel along, and
    /// where no rewrite keeps the value, there is none.
    static let rewriteCases: [(String, [String], [String])] = [
        // Commas between digits
        ("1,5k * 2", ["1,5k is one number with a decimal comma, write 1.5k;", "space after it: 1, 5k."], ["write 15", "1.5;"]),
        ("1,234.5e3", ["write 1234.5e3;", "1, 234.5e3."], ["1234.5;", "1234.5 "]),
        ("1e3,5", ["write it without separators", "1e3, 5."], ["1e35", "1e3.5"]),
        ("12,345k", ["write 12345k, or 12.345k if the comma is a decimal mark"], []),
        ("0,5", ["0,5 is one number with a decimal comma, write 0.5;"], ["write 05"]),
        ("1,5", ["1,5 is one number with a decimal comma, write 1.5;"], ["write 15"]),
        ("1,234", ["write 1234, or 1.234 if the comma is a decimal mark"], []),
        // Two numbers with only a space between them
        ("1 234", ["1 * 234", "write it without spaces: 1234."], []),
        ("1.5 .5", ["1.5 * .5"], ["without spaces", "1.5.5"]),
        ("1k 500", ["1k * 500"], ["without spaces", "1k500"]),
        ("1e3 5", ["1e3 * 5"], ["without spaces", "1e35"]),
        ("12345678901234567890 123456789012345678901", ["Missing operator"], ["without spaces"]),
        // "·" between digits
        ("1e3\u{00B7}5", ["1e3 * 5 for a multiplication"], ["for a decimal"]),
        ("1.5\u{00B7}2", ["1.5 * 2 for a multiplication"], ["for a decimal"]),
        ("1\u{00B7}2.5", ["1 * 2.5 for a multiplication"], ["for a decimal"]),
    ]

    @Test(arguments: CalcParserTests.rewriteCases)
    func rewritesKeepTheValue(expression: String, present: [String], absent: [String]) {
        let text = message(expression)
        for fragment in present { #expect(text.contains(fragment), "\(expression): \(text)") }
        for fragment in absent { #expect(!text.contains(fragment), "\(expression): \(text)") }
    }

    // MARK: Limits

    @Test func lengthIsCheckedFirst() throws {
        let longest = String(repeating: "1+", count: 499) + "12"
        #expect(longest.count == 1000)
        #expect(try CalcParser.parse(longest).rendered.hasSuffix("+ 12"))
        let tooLong = longest + "%"
        #expect(message(tooLong).contains("The expression has 1001 characters; calc takes at most 1000."))
        // Even a malformed expression gets the length error first.
        #expect(message(String(repeating: "%", count: 1001)).contains("1001 characters"))
    }

    /// 499 additions build a tree 499 levels deep on the left. A recursive renderer overflowed the 512 KB stack of
    /// a test thread on it (debug build); `fold` walks it without recursion.
    @Test func flatChainsDoNotCountAsNestingAndRenderWithoutRecursion() throws {
        let chain = String(repeating: "1+", count: 499) + "1"
        let tree = try CalcParser.parse(chain)
        let expected = String(repeating: "(", count: 498) + "1 + 1)" + String(repeating: " + 1)", count: 497) + " + 1"
        #expect(tree.rendered == expected)
        // Its read nests 498 parentheses deep and is too long to parse again: read is for showing, not for input.
        #expect(message(expected).contains("2993 characters"))
        // Counting the nodes bottom-up visits each one once.
        #expect(tree.fold { (_, counts: [Int]) in counts.reduce(1, +) } == 999)
        let products = try CalcParser.parse(String(repeating: "2*", count: 499) + "2")
        #expect(products.rendered.hasSuffix(") * 2"))
    }

    @Test func foldGivesChildResultsInOrder() throws {
        let tree = try CalcParser.parse("max(1, -{a:count}, 2 ^ 3) - round(4, 5)")
        let order = tree.fold { (expression, parts: [String]) -> String in
            switch expression.node {
            case .number(let value, _): "\(value)"
            case .tally(let name, _): name
            case .negation: "neg[\(parts.joined(separator: " "))]"
            case .binary(let op, _, _): "\(op.rawValue)[\(parts.joined(separator: " "))]"
            case .call(let function, _): "\(function.rawValue)[\(parts.joined(separator: " "))]"
            }
        }
        #expect(order == "-[max[1 neg[a] ^[2 3]] round[4 5]]")
        // An error from combine ends the fold and comes back typed.
        let error = #expect(throws: ToolError.self) {
            try tree.fold { (expression, _: [Int]) throws(ToolError) -> Int in
                if case .tally = expression.node { throw ToolError("tally at \(expression.position)") }
                return 0
            }
        }
        #expect(error?.message == "tally at 9")
    }

    @Test func nestingUpTo64IsFine() throws {
        let parentheses = String(repeating: "(", count: 64) + "1" + String(repeating: ")", count: 64)
        #expect(try CalcParser.parse(parentheses).rendered == "1")
        let minus = String(repeating: "-", count: 64) + "1"
        #expect(try CalcParser.parse(minus).rendered == minus)
        let mixed = String(repeating: "-(", count: 32) + "1" + String(repeating: ")", count: 32)
        #expect(try CalcParser.parse(mixed).rendered == String(repeating: "-", count: 32) + "1")
        let calls = String(repeating: "abs(", count: 64) + "1" + String(repeating: ")", count: 64)
        #expect(try CalcParser.parse(calls).rendered == calls)
        let powers = "2" + String(repeating: "^2", count: 64)
        _ = try CalcParser.parse(powers)
        // Leading plus signs leave no node and do not nest.
        #expect(try CalcParser.parse(String(repeating: "+", count: 900) + "1").rendered == "1")
    }

    static let deepCases: [(String, Int)] = [
        (String(repeating: "(", count: 65) + "1" + String(repeating: ")", count: 65), 65),
        (String(repeating: "-", count: 65) + "1", 65),
        (String(repeating: "-(", count: 32) + "-1" + String(repeating: ")", count: 32), 65),
        (String(repeating: "abs(", count: 65) + "1" + String(repeating: ")", count: 65), 257),
        ("2" + String(repeating: "^2", count: 65), 130),
        (String(repeating: "(", count: 400) + "1" + String(repeating: ")", count: 400), 65),
    ]

    @Test(arguments: CalcParserTests.deepCases)
    func nestingDeeperThan64IsRefused(expression: String, position: Int) {
        let text = message(expression)
        #expect(text.contains("nests deeper than 64 levels at character \(position) of"), "\(text.prefix(200))")
    }

    /// Far beyond the length limit, the depth guard still stops the parser before the stack runs out.
    @Test func hugeNestingGetsTheErrorNotACrash() {
        let n = 100_000
        let inputs = [
            String(repeating: "(", count: n) + "1" + String(repeating: ")", count: n),
            String(repeating: "-", count: n) + "1",
            String(repeating: "\u{2212}(", count: n) + "1",
            String(repeating: "abs(", count: n) + "1" + String(repeating: ")", count: n),
            "2" + String(repeating: "^2", count: n),
            "2" + String(repeating: "**-2", count: n),
        ]
        for input in inputs {
            #expect(message(input).contains("characters; calc takes at most 1000"))
            let lifted = message(input, maximumLength: .max)
            #expect(lifted.contains("nests deeper than 64 levels"), "\(lifted.prefix(200))")
        }
        // Plus signs do not nest: even 100,000 of them parse.
        #expect(throws: Never.self) { try CalcParser.parse(String(repeating: "+", count: n) + "1", maximumLength: .max) }
    }

    // MARK: Round trip

    /// parse(render(tree)) gives the tree again, over random trees with a fixed seed.
    @Test func roundTripOverRandomTrees() throws {
        var random = SplitMix64(seed: 0x00ca_1c07)
        for _ in 0..<3000 {
            let tree = try randomTree(depth: 6, using: &random)
            let read = tree.rendered
            let parsed = try CalcParser.parse(read)
            #expect(shape(parsed) == shape(tree), "\(read)")
            #expect(parsed.rendered == read)
        }
    }

    /// The same trees written with the other spellings, literals as written, extra parentheses and random
    /// whitespace read as the same tree.
    @Test func otherSpellingsOfRandomTreesReadTheSame() throws {
        var random = SplitMix64(seed: 0x5be1_1ed)
        for _ in 0..<3000 {
            let tree = try randomTree(depth: 5, using: &random)
            let written = variant(tree, using: &random)
            guard written.count <= CalcParser.maximumLength else { continue }
            let parsed = try CalcParser.parse(written)
            #expect(shape(parsed) == shape(tree), "\(written)")
        }
    }

    // MARK: Helpers

    private func message(_ expression: String, maximumLength: Int = CalcParser.maximumLength) -> String {
        do {
            let tree = try CalcParser.parse(expression, maximumLength: maximumLength)
            return "(no error: \(tree.rendered))"
        } catch {
            return error.message
        }
    }
}

/// The tree without positions and literals, written independently of `rendered`.
private func shape(_ expression: CalcExpression) -> String {
    switch expression.node {
    case .number(let value, _): value.description
    case .tally(let name, let field): field == .count ? "{\(name):count}" : "{\(name)}"
    case .negation(let operand): "(neg \(shape(operand)))"
    case .binary(let op, let left, let right): "(\(op.rawValue) \(shape(left)) \(shape(right)))"
    case .call(let function, let arguments): "(\(function.rawValue)" + arguments.map { " " + shape($0) }.joined() + ")"
    }
}

private let tallyNames = ["errors-k3f9", "requests-p2x7", "2026-11-08", "a", "builds.total", "x_y", "0"]

private func randomLiteral(using random: inout SplitMix64) -> String {
    let digits = "0123456789"
    func run(_ count: Int, _ random: inout SplitMix64) -> String {
        String((0..<count).map { _ in digits.randomElement(using: &random)! })
    }
    var literal = run(Int.random(in: 1...6, using: &random), &random)
    switch Int.random(in: 0..<6, using: &random) {
    case 0: literal += "." + run(Int.random(in: 1...4, using: &random), &random)
    case 1: literal = "." + run(Int.random(in: 1...3, using: &random), &random)
    case 2: literal += "e" + ["", "+", "-", "\u{2212}"].randomElement(using: &random)! + String(Int.random(in: 0...20, using: &random))
    case 3: literal += ["k", "K", "M", "G", "T"].randomElement(using: &random)!
    default: break
    }
    return literal
}

private func randomTree(depth: Int, using random: inout SplitMix64) throws -> CalcExpression {
    if depth == 0 || Int.random(in: 0..<10, using: &random) < 3 {
        if Bool.random(using: &random) {
            let literal = randomLiteral(using: &random)
            return CalcExpression(position: 0, node: .number(try NumberReader.read(.string(literal)), literal: literal))
        }
        let field: CalcTallyField = Bool.random(using: &random) ? .value : .count
        return CalcExpression(position: 0, node: .tally(name: tallyNames.randomElement(using: &random)!, of: field))
    }
    switch Int.random(in: 0..<10, using: &random) {
    case 0, 1:
        return CalcExpression(position: 0, node: .negation(try randomTree(depth: depth - 1, using: &random)))
    case 2, 3:
        let function = CalcFunction.allCases.randomElement(using: &random)!
        let count = switch function {
        case .abs: 1
        case .round: 2
        case .min, .max: Int.random(in: 1...3, using: &random)
        }
        var arguments: [CalcExpression] = []
        for _ in 0..<count { arguments.append(try randomTree(depth: depth - 1, using: &random)) }
        return CalcExpression(position: 0, node: .call(function, arguments))
    default:
        let op = CalcOperator.allCases.randomElement(using: &random)!
        let left = try randomTree(depth: depth - 1, using: &random)
        let right = try randomTree(depth: depth - 1, using: &random)
        return CalcExpression(position: 0, node: .binary(op, left, right))
    }
}

/// The tree written another way: other operator spellings, literals as written, a redundant `+` or parentheses
/// here and there, random whitespace between tokens.
private func variant(_ expression: CalcExpression, using random: inout SplitMix64) -> String {
    func space(_ random: inout SplitMix64) -> String {
        ["", "", " ", "  ", "\t"].randomElement(using: &random)!
    }
    func operand(_ child: CalcExpression, _ random: inout SplitMix64) -> String {
        let text = variant(child, using: &random)
        switch child.node {
        case .binary, .negation: return "(" + space(&random) + text + space(&random) + ")"
        default: return Bool.random(using: &random) ? text : "(" + text + ")"
        }
    }
    switch expression.node {
    case .number(_, let literal):
        return literal
    case .tally(let name, let field):
        let inner = space(&random) + name + space(&random)
        switch field {
        case .count: return "{" + inner + ":" + space(&random) + "count" + space(&random) + "}"
        case .value: return "{" + inner + (Bool.random(using: &random) ? ":value" : "") + "}"
        }
    case .negation(let child):
        let sign = ["-", "\u{2212}", "+-", "-+"].randomElement(using: &random)!
        return sign + space(&random) + operand(child, &random)
    case .binary(let op, let left, let right):
        let spelling = switch op {
        case .add: "+"
        case .subtract: ["-", "\u{2212}"].randomElement(using: &random)!
        case .multiply: ["*", "\u{00D7}", "\u{00B7}"].randomElement(using: &random)!
        case .divide: ["/", "\u{00F7}"].randomElement(using: &random)!
        case .power: ["^", "**"].randomElement(using: &random)!
        }
        // "·" directly between two digits is refused (a raised decimal point?), so it gets spaces.
        if spelling == "\u{00B7}" { return operand(left, &random) + " · " + operand(right, &random) }
        return operand(left, &random) + space(&random) + spelling + space(&random) + operand(right, &random)
    case .call(let function, let arguments):
        // A comma that separates arguments is followed by a space, or a digit could follow it directly.
        let list = arguments.map { space(&random) + variant($0, using: &random) + space(&random) }
        return function.rawValue + space(&random) + "(" + list.joined(separator: ", ") + ")"
    }
}

/// SplitMix64: a small, seedable generator, so a failure can be replayed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
