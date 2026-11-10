import Foundation

/// Reads a calc expression into a `CalcExpression` (ADR-0007), by this grammar:
///
/// ```
/// expression := term (("+" | "-") term)*
/// term       := unary (("*" | "/") unary)*
/// unary      := ("-" | "+") unary | power
/// power      := primary ("^" unary)?
/// primary    := number | "{" name [":count" | ":value"] "}" | function "(" arguments ")" | "(" expression ")"
/// ```
///
/// So `-2^2` is -(2^2), `2^3^2` is 2^(3^2), and `2^-1` and `2 * -3` are allowed. Also accepted: `−` (U+2212) for
/// minus, `×` and `·` for `*`, `÷` for `/`, `**` for `^`; whitespace between tokens is ignored.
///
/// Every error is a `ToolError` that says what was found, at which character (counted from 1), and what to write
/// instead. The expression has at most 1000 characters, checked before anything else, and nests at most 64 deep:
/// parentheses, function calls, powers and leading minus signs each add a level while they wait for their end.
///
/// The parser does not recurse: it reads operators by precedence with explicit stacks, so no input can exhaust the
/// thread's stack (a recursive descent took about 6 KB per level of parentheses in a debug build, too much for 64
/// levels on a 512 KB thread). The depth limit bounds the tree for whatever walks it later.
struct CalcParser {
    static let maximumLength = 1000
    static let maximumDepth = 64

    /// Parses `expression`. `maximumLength` exists for tests, which lift it to reach the depth guard with
    /// inputs far beyond the length limit.
    static func parse(
        _ expression: String, maximumLength: Int = CalcParser.maximumLength
    ) throws(ToolError) -> CalcExpression {
        let source = Array(expression)
        if source.count > maximumLength {
            throw ToolError(
                "The expression has \(source.count) characters; calc takes at most \(maximumLength). Work out parts of "
                    + "it in separate calls and combine their results in a shorter expression."
            )
        }
        var parser = CalcParser(expression, source: source)
        if source.allSatisfy(\.isCalcWhitespace) {
            throw ToolError(
                "The expression is \(expression.isEmpty ? "empty" : "only whitespace"). Write a calculation such as "
                    + "{errors-k3f9} / {requests-p2x7} * 100 or 1250 * 1.19."
            )
        }
        parser.token = try parser.scanToken()
        return try parser.parseExpression()
    }

    private let expression: String
    private let source: [Character]
    /// Where the lexer continues, an index into `source`.
    private var index = 0
    /// The token the parser looks at; scanned one ahead, so errors come in the order of the text.
    private var token: Token
    /// The token consumed last.
    private var previous: Token?
    /// The nesting level: open parentheses and calls, and waiting leading minus signs and powers.
    private var depth = 0

    private init(_ expression: String, source: [Character]) {
        self.expression = expression
        self.source = source
        token = Token(kind: .end, start: 0, end: 0)
    }

    private struct Token {
        enum Kind {
            /// A number or a tally reference, as the node it becomes.
            case leaf(CalcExpression.Node)
            case function(CalcFunction)
            case plus, minus, times, divide, power
            case open, close, comma
            case end
        }

        var kind: Kind
        /// The index of the token's first character in `source`.
        var start: Int
        /// The index after its last character.
        var end: Int

        var position: Int { start + 1 }

        var startsOperand: Bool {
            switch kind {
            case .leaf, .function, .open: true
            default: false
            }
        }

        var isNumber: Bool {
            if case .leaf(.number) = kind { return true }
            return false
        }

        var binaryOperator: CalcOperator? {
            switch kind {
            case .plus: .add
            case .minus: .subtract
            case .times: .multiply
            case .divide: .divide
            case .power: .power
            default: nil
            }
        }
    }

    // MARK: Parsing

    /// An operator waiting for its right operand.
    private struct Waiting {
        enum Kind {
            case negation
            case binary(CalcOperator)
        }

        var kind: Kind
        var position: Int

        /// How tightly it binds, from the grammar: `+ -`, then `* /`, then a leading minus, then `^`.
        var precedence: Int {
            switch kind {
            case .binary(.add), .binary(.subtract): 1
            case .binary(.multiply), .binary(.divide): 2
            case .negation: 3
            case .binary(.power): 4
            }
        }

        /// A leading minus and `^` add a nesting level while they wait; in the grammar, their operand is a
        /// recursion (`unary` in both).
        var nests: Bool { precedence >= 3 }
    }

    /// The expression being read at one nesting level: the whole of it, a group in parentheses, or the current
    /// argument of a function call.
    private struct Level {
        enum Kind {
            case whole
            case group(open: Int)
            case call(CalcFunction, name: Int, open: Int)
        }

        var kind: Kind
        var operands: [CalcExpression] = []
        var waiting: [Waiting] = []
        /// A call's arguments read so far.
        var arguments: [CalcExpression] = []
        /// Where the current argument of a call starts, an index into `source`.
        var argumentStart = 0
        /// Where the first argument is written, for round's message.
        var firstArgument: Range<Int>?
    }

    private mutating func advance() throws(ToolError) {
        previous = token
        token = try scanToken()
    }

    private mutating func nest(at position: Int) throws(ToolError) {
        depth += 1
        if depth > Self.maximumDepth { throw tooDeep(at: position) }
    }

    /// Reads the whole expression: in operand position leading signs and an operand, in operator position a binary
    /// operator or the end of the current level (`)`, `,` or the end of the text).
    private mutating func parseExpression() throws(ToolError) -> CalcExpression {
        var levels = [Level(kind: .whole)]
        var expectingOperand = true
        while true {
            if expectingOperand {
                let position = token.position
                switch token.kind {
                case .minus:
                    try nest(at: position)
                    levels[levels.count - 1].waiting.append(Waiting(kind: .negation, position: position))
                    try advance()
                case .plus:
                    try advance()
                case .leaf(let node):
                    levels[levels.count - 1].operands.append(
                        CalcExpression(position: position, node: node, written: token.start..<token.end)
                    )
                    try advance()
                    expectingOperand = false
                case .open:
                    try nest(at: position)
                    try advance()
                    if case .close = token.kind { throw emptyParentheses(at: position) }
                    levels.append(Level(kind: .group(open: position)))
                case .function(let function):
                    try advance()
                    guard case .open = token.kind else { throw missingParenthesis(after: function, at: position) }
                    let open = token.position
                    try nest(at: position)
                    try advance()
                    // Every function takes at least one argument.
                    if case .close = token.kind { throw arityError(function, 0, firstArgument: nil, at: position) }
                    levels.append(Level(kind: .call(function, name: position, open: open), argumentStart: token.start))
                default:
                    throw expectedOperand(in: levels[levels.count - 1].kind)
                }
                continue
            }

            try refuseAdjacentOperand()
            if let op = token.binaryOperator {
                let waiting = Waiting(kind: .binary(op), position: token.position)
                reduce(&levels[levels.count - 1], before: waiting)
                if waiting.nests { try nest(at: waiting.position) }
                levels[levels.count - 1].waiting.append(waiting)
                try advance()
                expectingOperand = true
                continue
            }

            // The current level's expression is complete; what follows decides what it was.
            var level = levels.removeLast()
            reduce(&level, before: nil)
            let value = level.operands[0]
            switch (level.kind, token.kind) {
            case (.whole, .end):
                return value
            case (.group(let open), .close):
                depth -= 1
                var grouped = value
                grouped.outerSpan = (open - 1)..<token.end
                levels[levels.count - 1].operands.append(grouped)
                try advance()
            case (.call, .comma):
                level.firstArgument = level.firstArgument ?? level.argumentStart..<(previous?.end ?? level.argumentStart)
                level.arguments.append(value)
                level.operands = []
                try advance()
                level.argumentStart = token.start
                levels.append(level)
                expectingOperand = true
            case (.call(let function, let name, _), .close):
                level.firstArgument = level.firstArgument ?? level.argumentStart..<(previous?.end ?? level.argumentStart)
                level.arguments.append(value)
                if !function.arity.contains(level.arguments.count) {
                    throw arityError(function, level.arguments.count, firstArgument: level.firstArgument, at: name)
                }
                depth -= 1
                levels[levels.count - 1].operands.append(
                    CalcExpression(position: name, node: .call(function, level.arguments), written: (name - 1)..<token.end)
                )
                try advance()
            case (.group(let open), .end):
                throw unclosed(at: open, of: nil)
            case (.call(let function, _, let open), .end):
                throw unclosed(at: open, of: function)
            default:
                throw unexpectedAfterOperand()
            }
        }
    }

    /// Applies the waiting operators of `level` from the top, as long as they bind more tightly than `next`, or
    /// as tightly when `next` groups from the left (all but `^`); with `next` nil, all of them.
    private mutating func reduce(_ level: inout Level, before next: Waiting?) {
        while let top = level.waiting.last {
            if let next {
                let groupsFromLeft = next.precedence != 4
                guard top.precedence > next.precedence || (top.precedence == next.precedence && groupsFromLeft) else {
                    return
                }
            }
            level.waiting.removeLast()
            let right = level.operands.removeLast()
            switch top.kind {
            case .negation:
                level.operands.append(CalcExpression(
                    position: top.position, node: .negation(right), written: (top.position - 1)..<right.outerSpan.upperBound
                ))
            case .binary(let op):
                let left = level.operands.removeLast()
                level.operands.append(CalcExpression(
                    position: top.position, node: .binary(op, left, right),
                    written: left.outerSpan.lowerBound..<right.outerSpan.upperBound
                ))
            }
            if top.nests { depth -= 1 }
        }
    }

    private func tooDeep(at position: Int) -> ToolError {
        ToolError(
            "The expression nests deeper than \(Self.maximumDepth) levels \(at(position)): parentheses, function calls, "
                + "powers and leading minus signs each add a level. Remove parentheses or minus signs that are not "
                + "needed, or work out the inner part in a separate call."
        )
    }

    private func emptyParentheses(at position: Int) -> ToolError {
        ToolError("Empty parentheses \(at(position)): put an expression inside, or remove them.")
    }

    /// A `(` still open at the end of the expression.
    private func unclosed(at position: Int, of function: CalcFunction?) -> ToolError {
        if let function {
            return ToolError(
                "The \"(\" of \(function.rawValue) \(at(position)) is never closed: add \")\" after the last argument."
            )
        }
        return ToolError("The \"(\" \(at(position)) is never closed: add \")\" where the group ends, or remove the \"(\".")
    }

    private func missingParenthesis(after function: CalcFunction, at position: Int) -> ToolError {
        ToolError(
            "Expected \"(\" after \(function.rawValue) \(at(position)): a function's arguments go in parentheses, as "
                + "in \(function.usage)."
        )
    }

    private func arityError(
        _ function: CalcFunction, _ count: Int, firstArgument: Range<Int>?, at position: Int
    ) -> ToolError {
        let given = switch count {
        case 0: "none was given"
        case 1: "1 was given"
        default: "\(count) were given"
        }
        switch function {
        case .abs:
            return ToolError("abs takes 1 argument, but \(given) \(at(position)). Write abs(x).")
        case .round:
            // The first argument as written, when it is short enough to repeat.
            let x = firstArgument.map { text($0.lowerBound, $0.upperBound) }.flatMap { $0.unicodeScalars.count <= 40 ? $0 : nil }
                ?? "x"
            return ToolError(
                "round takes 2 arguments, the value and the decimal places, but \(given) \(at(position)). Write "
                    + "round(\(x), 0) to round to a whole number, or round(\(x), 2) for two decimal places."
            )
        case .min, .max:
            return ToolError(
                "\(function.rawValue) takes at least 1 argument, but \(given) \(at(position)). Write \(function.usage)."
            )
        }
    }

    /// After an operand only an operator, `)`, `,` (in a call) or the end can follow; an operand there is a
    /// missing operator.
    private func refuseAdjacentOperand() throws(ToolError) {
        guard token.startsOperand, let previous else { return }
        var message = "Missing operator \(at(token.position)): calc does not multiply implicitly."
        // Scalars, not characters: the rest of the text is not read yet, and one character can carry any number of
        // combining marks.
        if expression.unicodeScalars.count <= 60 {
            let corrected = (text(0, previous.end) + " * " + text(token.start, source.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            message += " Write * where the multiplication goes: \(corrected)."
        } else {
            message += " Write * before character \(token.position) where a multiplication is meant."
        }
        // Two runs of digits (1 234) may be one number with a space; joined, they must still be a number calc reads.
        // Anything else joined as text (1.5 .5, 1k 500, 1e3 5) would be a different number, or none.
        let joined = text(previous.start, previous.end) + text(token.start, token.end)
        let digits = joined.compactMap(\.calcDigit)
        if previous.isNumber && token.isNumber && digits.count == joined.count,
            (try? NumberReader.build(NumberReader.Parts(negative: false, digits: digits, exponent: 0))) != nil
        {
            message += " If \(text(previous.start, token.end)) is one number, write it without spaces: \(joined)."
        }
        throw ToolError(message)
    }

    /// A `)` or `,` where it closes nothing or separates nothing.
    private func unexpectedAfterOperand() -> ToolError {
        let found = "Unexpected \(quoted(token)) \(at(token.position))"
        switch token.kind {
        case .close:
            return ToolError("\(found): there is no \"(\" for it to close. Remove it, or add the missing \"(\".")
        case .comma:
            return ToolError(
                "\(found): a comma separates the arguments of a function call, such as max(1, 2); plain parentheses "
                    + "hold one expression, and numbers take no thousands separators."
            )
        default:
            return ToolError("\(found): \(Self.vocabulary)")
        }
    }

    /// No operand where one has to come; `level` is what is being read there.
    private func expectedOperand(in level: Level.Kind) -> ToolError {
        let operand = "a number, a tally like {errors-k3f9}, a function call or \"(\""
        guard let previous else {
            return ToolError("Unexpected \(quoted(token)) \(at(token.position)): the expression has to start with \(operand).")
        }
        if case .end = token.kind {
            return ToolError("The expression ends after \(quoted(previous)) \(at(previous.position)): \(operand) has to follow.")
        }
        let found = "Unexpected \(quoted(token)) \(at(token.position))"
        switch (previous.kind, token.kind) {
        case (.open, .comma):
            if case .group = level {
                return ToolError(
                    "\(found): nothing comes before it in the parentheses. Commas only separate the arguments of a "
                        + "function call, such as max(1, 2), and numbers take no thousands separators."
                )
            }
            return ToolError("\(found): a function argument is missing. Remove the extra comma, or write the argument.")
        case (.comma, .close), (.comma, .comma):
            return ToolError("\(found): a function argument is missing. Remove the extra comma, or write the argument.")
        case (.times, .times):
            return ToolError(
                "\(found): two operators in a row. For a power, write ^, or ** without a space between the stars."
            )
        default:
            return ToolError("\(found): \(operand) has to follow \(quoted(previous)).")
        }
    }

    // MARK: Tokens

    private static let vocabulary = "calc reads numbers, the operators + - * / ^, parentheses, tallies in braces "
        + "like {errors-k3f9}, and the functions abs, round, min and max."

    private mutating func scanToken() throws(ToolError) -> Token {
        while let c = char(at: index), c.isCalcWhitespace { index += 1 }
        guard let c = char(at: index) else { return Token(kind: .end, start: source.count, end: source.count) }
        if c.calcDigit != nil || (c == "." && digit(at: index + 1) != nil) { return try scanNumber() }
        switch c {
        case "{": return try scanTally()
        case "(": return single(.open)
        case ")": return single(.close)
        case ",": return single(.comma)
        case "+": return single(.plus)
        case "-", "\u{2212}": return single(.minus)
        case "*":
            if char(at: index + 1) == "*" {
                index += 2
                return Token(kind: .power, start: index - 2, end: index)
            }
            return single(.times)
        case "\u{00B7}" where digit(at: index - 1) != nil && digit(at: index + 1) != nil:
            throw raisedDot(at: index)
        case "\u{00D7}", "\u{00B7}": return single(.times)
        case "/", "\u{00F7}": return single(.divide)
        case "^": return single(.power)
        default: break
        }
        if c.isASCIILetter { return try scanWord() }
        throw unexpectedCharacter(c, at: index)
    }

    private mutating func single(_ kind: Token.Kind) -> Token {
        index += 1
        return Token(kind: kind, start: index - 1, end: index)
    }

    /// `·` directly between two digits: a raised decimal point in some notations (1·5 for 1.5), a multiplication
    /// in others. Read either way, it could be off by far, so it is refused.
    private func raisedDot(at index: Int) -> ToolError {
        // The number before it ends at the dot; the one after it starts there.
        let left = previous.map { text($0.start, $0.end) } ?? text(index - 1, index)
        let right = text(index + 1, literalEnd(from: index + 1))
        var readings = "\(left) * \(right) for a multiplication"
        if left.allSatisfy({ $0.calcDigit != nil }) && !right.contains(".") {
            readings = "\(left).\(right) for a decimal, or " + readings
        }
        return ToolError(
            "A \"·\" between two digits \(at(index + 1)) can be a raised decimal point or a multiplication. Write "
                + "\(readings)."
        )
    }

    private func unexpectedCharacter(_ c: Character, at index: Int) -> ToolError {
        let found = "Unexpected \(String(c).quotedForMessage) \(at(index + 1))"
        return switch c {
        case "%":
            ToolError(
                "\(found): there is no % operator, and it is not modulo either. For a percentage, multiply by 100 "
                    + "(37 / 1250 * 100); to add 10%, multiply by 1.1."
            )
        case "=":
            ToolError("\(found): leave out the \"=\"; calc works out the expression and returns its result.")
        case "}":
            ToolError("\(found): there is no \"{\" for it to close. A tally is written as {name}, like {errors-k3f9}.")
        case ".":
            ToolError("\(found): a decimal mark needs digits after it, as in 0.5 or .5.")
        case "[", "]":
            ToolError("\(found): group with parentheses ( and ) instead.")
        case "\u{2013}", "\u{2014}":
            ToolError("\(found): for a minus, write - (or −).")
        default:
            ToolError("\(found): \(Self.vocabulary)")
        }
    }

    // MARK: Numbers

    /// Digits with an optional fraction (`.5` too, `5.` not), then an optional exponent or one suffix. The form is
    /// checked here, the range by `NumberReader.build`, with errors written for expressions.
    private mutating func scanNumber() throws(ToolError) -> Token {
        let start = index
        var digits: [UInt8] = []
        var fractionDigits = 0
        while let d = digit(at: index) {
            digits.append(d)
            index += 1
        }
        if char(at: index) == "." {
            guard digit(at: index + 1) != nil else {
                let number = text(start, index).cutForMessage
                throw ToolError(
                    "The number \(number). ends in a decimal mark \(at(index + 1)): write digits after the \".\" "
                        + "(\(number).0), or leave it out (\(number))."
                )
            }
            index += 1
            while let d = digit(at: index) {
                digits.append(d)
                fractionDigits += 1
                index += 1
            }
            if char(at: index) == "." {
                throw ToolError(
                    "Unexpected \".\" \(at(index + 1)): a number has at most one decimal mark, and calc takes no "
                        + "thousands separators. Write digits with one \".\", such as 1234.5."
                )
            }
        }

        var exponent = 0
        var hasExponent = false
        if let e = char(at: index), e == "e" || e == "E" {
            var next = index + 1
            var exponentNegative = false
            if let sign = char(at: next), sign.isSign {
                exponentNegative = sign != "+"
                next += 1
            }
            if digit(at: next) != nil {
                hasExponent = true
                index = next
                while let d = digit(at: index) {
                    // Beyond a million the value is out of range anyway (unless it is zero); this keeps Int safe.
                    exponent = min(exponent * 10 + Int(d), 1_000_000)
                    index += 1
                }
                if exponentNegative { exponent = -exponent }
            } else if !(next == index + 1 && char(at: next)?.isASCIILetter == true) {
                throw ToolError(
                    "The exponent after \"\(e)\" \(at(index + 1)) needs digits, as in 2.5e3; calc has no constant e."
                )
            }
            // Otherwise a letter follows the "e" directly: a unit, refused below.
        }

        if char(at: index) == ",", digit(at: index + 1) != nil, digit(at: index - 1) != nil {
            throw thousandsSeparator(numberStart: start, comma: index)
        }
        if char(at: index) == "_" {
            var end = index
            while let c = char(at: end), c == "_" || c == "." || c.calcDigit != nil { end += 1 }
            throw ToolError(
                "Unexpected \"_\" \(at(index + 1)): numbers take no separators. Write "
                    + "\(text(start, end).replacingOccurrences(of: "_", with: "").cutForMessage)."
            )
        }

        let lettersStart = index
        while char(at: index)?.isASCIILetter == true { index += 1 }
        if index > lettersStart {
            let letters = text(lettersStart, index)
            let number = text(start, lettersStart).cutForMessage
            if letters.count == 1, let power = letters.first?.suffixPower {
                if hasExponent {
                    throw ToolError(
                        "The number \(text(start, index).cutForMessage) \(at(start + 1)) has both an exponent and a suffix: use one "
                            + "or the other, as in 2.5e3 or 2.5k."
                    )
                }
                exponent += power
            } else if letters == "m" {
                throw ToolError(milli(number: number, at: lettersStart + 1))
            } else if isWordOfItsOwn(at: lettersStart) {
                // 2abs(-3), 2pi, 2sqrt(4): the number ends here, and the word gets its own message (a missing *,
                // no constants, no roots).
                index = lettersStart
            } else {
                var message = "Unexpected \(letters.quotedForMessage) after the number \(number) \(at(lettersStart + 1)): "
                    + "calc takes no units; write the bare number (\(number))."
                if letters == "x" || letters == "X" {
                    message += " For a multiplication, write * (\(number) * 3)."
                } else {
                    message += " A number may end in one suffix: k or K (thousand), M, G or T."
                }
                throw ToolError(message)
            }
        }

        if let c = char(at: index), c.calcDigit != nil || c == "." || c == "_" {
            throw ToolError(
                "Unexpected \(String(c).quotedForMessage) after the number \(text(start, index).cutForMessage) \(at(index + 1)): a "
                    + "number is digits with at most one \".\", then an optional exponent (2.5e3) or suffix (410k)."
            )
        }

        let literal = text(start, index)
        do {
            let value = try NumberReader.build(
                NumberReader.Parts(negative: false, digits: digits, exponent: exponent - fractionDigits)
            )
            return Token(kind: .leaf(.number(value, literal: literal)), start: start, end: index)
        } catch {
            throw rangeError(error, literal: literal, at: start + 1)
        }
    }

    private static let roots: Set<String> = ["sqrt", "root", "cbrt"]
    private static let constants: Set<String> = ["pi", "e", "tau", "phi", "inf", "infinity", "nan"]

    /// Whether the letters at `start`, right after a number, are better read as a word than as a unit: a function
    /// name (in any case), a root, a constant, or any word followed by `(`.
    private func isWordOfItsOwn(at start: Int) -> Bool {
        var end = start
        while let c = char(at: end), c.isASCIILetter || c.calcDigit != nil || c == "_" { end += 1 }
        let word = text(start, end).lowercased()
        if CalcFunction(rawValue: word) != nil || Self.roots.contains(word) || Self.constants.contains(word) {
            return true
        }
        while let c = char(at: end), c.isCalcWhitespace { end += 1 }
        return char(at: end) == "("
    }

    private func milli(number: String, at position: Int) -> String {
        "A lowercase \"m\" after \(number) \(at(position)) could mean milli or million: write \(number)M for million; "
            + "calc takes no units."
    }

    private func rangeError(_ problem: NumberReader.Problem, literal: String, at position: Int) -> ToolError {
        let found = "The number \(literal.cutForMessage) \(at(position))"
        return switch problem {
        case .tooLarge:
            ToolError(
                "\(found) is too large: calc reads numbers below 10^\(ExactDecimal.overflowExponent). Values on the way "
                    + "to the result may be larger, so a large factor that is divided again can be written as a "
                    + "product (1e100 * 1e100)."
            )
        case .tooManyDigits(let count):
            ToolError(
                "\(found) has \(count) significant digits: calc reads at most \(ExactDecimal.precision) and never rounds "
                    + "a number it is given. Round it to \(ExactDecimal.precision) significant digits or fewer."
            )
        case .tooSmall:
            ToolError(
                "\(found) has digits below 10^\(ExactDecimal.minimumExponent), the finest step calc reads, and calc "
                    + "never rounds a number it is given. Round it to \(-ExactDecimal.minimumExponent) decimal places "
                    + "or fewer."
            )
        case .format(let problem):
            ToolError("\(found) cannot be read: \(problem)")
        }
    }

    /// A comma directly between two digits: a thousands separator, a decimal comma, or arguments without a space.
    /// Each rewrite offered keeps the value of the reading it names, suffix and exponent included (`1,5k` is 1.5k
    /// with a decimal comma, never 15); where no rewrite keeps it, the message only says what to change.
    private func thousandsSeparator(numberStart: Int, comma: Int) -> ToolError {
        // The literals the commas join: 1,234.5e3 is "1" and "234.5e3"; 1e3,5 is "1e3" and "5".
        var pieces: [String] = []
        var start = numberStart
        while true {
            let end = literalEnd(from: start)
            pieces.append(text(start, end))
            guard char(at: end) == ",", digit(at: end - 1) != nil, digit(at: end + 1) != nil else { break }
            start = end + 1
        }
        let written = pieces.joined(separator: ",")
        guard written.unicodeScalars.count <= String.messageLimit else {
            // Rewrites of a long number would repeat it in full (ADR-0008): say what to change instead.
            return ToolError(
                "A comma between two digits \(at(comma + 1)): calc takes no thousands separators, and its decimal mark "
                    + "is always \".\". Write a number without separators, with \".\" as the decimal mark, and separate "
                    + "arguments with a comma and a space."
            )
        }
        let isPlain = { (piece: String) in !piece.isEmpty && piece.allSatisfy { $0.calcDigit != nil } }
        let leadingDigits = { (piece: String) in piece.prefix { $0.calcDigit != nil }.count }

        // Thousands separators: a first group of one to three digits (not starting with 0, which reads as a decimal
        // comma), plain groups of three, and a last group of three digits that may carry a fraction, an exponent or
        // a suffix.
        let first = pieces[0]
        let grouped = isPlain(first) && first.count <= 3 && !first.hasPrefix("0")
            && pieces.dropFirst().dropLast().allSatisfy { isPlain($0) && $0.count == 3 }
            && leadingDigits(pieces[pieces.count - 1]) == 3
        // A decimal comma: plain digits, the comma, then digits that may carry an exponent or a suffix.
        let decimal = pieces.count == 2 && isPlain(first) && !pieces[1].contains(".")

        // Both readings by name, each with its own rewrite: an agent took "put a space after it: 1, 234.5" for the
        // way to write the number.
        let asOneNumber = switch (grouped, decimal) {
        case (true, true):
            "If \(written) is one number, write \(pieces.joined()), or \(first).\(pieces[1]) if the comma is a decimal mark."
        case (true, false):
            "If \(written) is one number, write \(pieces.joined())."
        case (false, true):
            "If \(written) is one number with a decimal comma, write \(first).\(pieces[1])."
        case (false, false):
            "If \(written) is one number, write it without separators and with \".\" as the decimal mark."
        }
        return ToolError(
            "A comma between two digits \(at(comma + 1)): calc takes no thousands separators, and its decimal mark is "
                + "always \".\". \(asOneNumber) If \(pieces.listedInProse) are separate arguments, write "
                + "\(pieces.joined(separator: ", "))."
        )
    }

    /// Where a literal starting at `start` ends, for messages: digits, an optional fraction, then an exponent or one
    /// suffix (a suffix only when no letter follows it).
    private func literalEnd(from start: Int) -> Int {
        var end = start
        while digit(at: end) != nil { end += 1 }
        if char(at: end) == ".", digit(at: end + 1) != nil {
            end += 1
            while digit(at: end) != nil { end += 1 }
        }
        if let e = char(at: end), e == "e" || e == "E" {
            var next = end + 1
            if char(at: next)?.isSign == true { next += 1 }
            if digit(at: next) != nil {
                end = next
                while digit(at: end) != nil { end += 1 }
                return end
            }
        }
        if char(at: end)?.suffixPower != nil, char(at: end + 1)?.isASCIILetter != true { end += 1 }
        return end
    }

    // MARK: Tally references

    private mutating func scanTally() throws(ToolError) -> Token {
        let start = index
        index += 1
        while let c = char(at: index), c != "}", c != "{" { index += 1 }
        guard let close = char(at: index) else {
            throw ToolError(
                "The \"{\" \(at(start + 1)) is never closed: a tally is written as {name}, with \"}\" right after the name."
            )
        }
        if close == "{" {
            throw ToolError(
                "The \"{\" \(at(start + 1)) is not closed before the next \"{\" at character \(index + 1): braces hold "
                    + "one tally name, like {errors-k3f9}, and do not nest."
            )
        }
        let content = text(start + 1, index)
        index += 1
        let (name, field) = try tallyReference(content, at: start + 1)
        return Token(kind: .leaf(.tally(name: name, of: field)), start: start, end: index)
    }

    /// The name and field inside braces. Whitespace around either is dropped.
    private func tallyReference(_ content: String, at position: Int) throws(ToolError) -> (String, CalcTallyField) {
        let parts = content.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if name.isEmpty {
            throw ToolError(
                "The tally reference {\(content)} \(at(position)) has no name: write the tally's full name in braces, "
                    + "as tally_create returned it, like {errors-k3f9}."
            )
        }
        let lowercased = name.lowercased()
        let shownName = TallyName.isValid(name) ? name : TallyName.isValid(lowercased) ? lowercased : "name"

        let field: CalcTallyField
        switch fieldText {
        case nil, "value": field = .value
        case "count": field = .count
        default:
            throw ToolError(
                "The tally reference {\(content)} \(at(position)) ends in an unknown \":\(fieldText ?? "")\": write "
                    + "{\(shownName):count} for the tally's count, or {\(shownName)} (or {\(shownName):value}) for its value."
            )
        }
        guard TallyName.isValid(name) else {
            if TallyName.isValid(lowercased) {
                let reference = field == .count ? "{\(lowercased):count}" : "{\(lowercased)}"
                throw ToolError(
                    "Tally names are lowercase: \(name.quotedForMessage) \(at(position)) cannot be one. Write \(reference)."
                )
            }
            throw ToolError(
                "\(name.quotedForMessage) \(at(position)) is not a tally name: \(TallyName.rule). Write the full name in "
                    + "braces, as tally_create returned it, like {errors-k3f9}."
            )
        }
        return (name, field)
    }

    // MARK: Words

    private mutating func scanWord() throws(ToolError) -> Token {
        let start = index
        while let c = char(at: index), c.isASCIILetter || c.calcDigit != nil || c == "_" { index += 1 }
        let word = text(start, index)
        if let function = CalcFunction(rawValue: word) {
            return Token(kind: .function(function), start: start, end: index)
        }
        throw unknownWord(word, at: start)
    }

    private func unknownWord(_ word: String, at start: Int) -> ToolError {
        let lowercased = word.lowercased()
        let found = "\(word.quotedForMessage) \(at(start + 1))"
        let known = "calc has the functions abs, round, min and max, reads tallies in braces like {errors-k3f9}, and "
            + "has no constants."
        // Written right after a number (2pi, 2sqrt(4)), the word also lacks the * of a multiplication.
        var star = ""
        if let previous, previous.isNumber, previous.end == start {
            star = " A multiplication also needs a * after \(text(previous.start, previous.end))."
        }
        if Self.roots.contains(lowercased) {
            return ToolError(
                "There is no square root in calc: \(found). This version has no roots and no fractional powers (^ "
                    + "takes whole-number exponents); the functions are abs, round, min and max." + star
            )
        }
        if word != lowercased, let function = CalcFunction(rawValue: lowercased) {
            return ToolError("Function names are lowercase: \(found) is not one. Write \(function.usage)." + star)
        }
        if Self.constants.contains(lowercased) {
            return ToolError(
                "Unknown name \(found): calc has no constants; write the value as a number. It has the functions abs, "
                    + "round, min and max, and reads tallies in braces like {errors-k3f9}." + star
            )
        }
        if word == "x" || word == "X" {
            return ToolError("Unexpected \(found): for a multiplication, write * (or ×).")
        }
        var afterWord = start + word.count
        while let c = char(at: afterWord), c.isCalcWhitespace { afterWord += 1 }
        if char(at: afterWord) == "(" {
            return ToolError("Unknown function \(found): calc has the functions abs, round, min and max." + star)
        }
        if let previous, case .leaf(.number(_, let written)) = previous.kind {
            let literal = written.cutForMessage
            if word.count == 1, word.first?.suffixPower != nil {
                return ToolError(
                    "Unexpected space before \(found): a suffix follows its number directly (write \(literal)\(word), "
                        + "not \(literal) \(word)); after a space, a letter reads like a unit."
                )
            }
            if word == "m" { return ToolError(milli(number: literal, at: start + 1)) }
            return ToolError(
                "Unexpected \(word.quotedForMessage) after the number \(literal) \(at(start + 1)): calc takes no units; "
                    + "write the bare number."
            )
        }

        // A tally name written without braces: the word with the `-` and `.` parts that follow it.
        var end = start
        while let c = char(at: end), c.isASCIILetter || c.calcDigit != nil || c == "_" || c == "-" || c == "." {
            end += 1
        }
        let candidate = text(start, end)
        var message = "Unknown name \(found): \(known)"
        if TallyName.isValid(candidate) {
            message += " If \(candidate) is a tally, write {\(candidate)}."
        } else if TallyName.isValid(candidate.lowercased()) {
            message += " If \(candidate) is a tally, write {\(candidate.lowercased())}: tally names are lowercase."
        }
        return ToolError(message)
    }

    // MARK: Text

    private func char(at index: Int) -> Character? {
        index >= 0 && index < source.count ? source[index] : nil
    }

    private func digit(at index: Int) -> UInt8? {
        char(at: index)?.calcDigit
    }

    private func text(_ start: Int, _ end: Int) -> String {
        String(source[start..<end])
    }

    private func quoted(_ token: Token) -> String {
        text(token.start, token.end).quotedForMessage
    }

    private func at(_ position: Int) -> String {
        Self.at(position, of: expression, source: source)
    }

    /// `at character N of "<expression>"`; a long expression is cut to an excerpt around the position. The calc
    /// tool uses it too, for errors found while evaluating, so that both read alike.
    static func at(_ position: Int, of expression: String) -> String {
        at(position, of: expression, source: Array(expression))
    }

    private static func at(_ position: Int, of expression: String, source: [Character]) -> String {
        "at character \(position) of \(excerpt(around: position, of: expression, source: source))"
    }

    /// The expression, or a window of 50 Unicode scalars around `position` when it has more than 60 (ADR-0008).
    /// Scalars, not characters: one character can carry any number of combining marks, and a window of characters
    /// would then grow with the input, or lose the position to the middle cut of `quotedForMessage`.
    private static func excerpt(around position: Int, of expression: String, source: [Character]) -> String {
        let scalars = Array(expression.unicodeScalars)
        guard scalars.count > 60 else { return expression.quotedForMessage }
        let width = 50
        // Where the character at `position` starts, counted in scalars.
        let index = source[..<min(max(position - 1, 0), source.count)].reduce(0) { $0 + $1.unicodeScalars.count }
        let end = min(scalars.count, max(index - width / 2, 0) + width)
        let start = max(0, end - width)
        var excerpt = String.UnicodeScalarView()
        if start > 0 { excerpt.append("…") }
        excerpt.append(contentsOf: scalars[start..<end])
        if end < scalars.count { excerpt.append("…") }
        return String(excerpt).quotedForMessage
    }
}

/// Digits, signs and suffixes by NumberReader's rules, so that both readers accept the same ones.
private extension Character {
    /// The character as one Unicode scalar, or nil when it is several (a digit with a combining mark, "\r\n").
    var onlyScalar: Unicode.Scalar? {
        let scalars = unicodeScalars
        return scalars.count == 1 ? scalars.first : nil
    }

    /// The value of an ASCII digit; other digits (`١`, `²`) are not digits.
    var calcDigit: UInt8? { onlyScalar.flatMap(NumberReader.digitValue) }

    /// The power of ten of a suffix: `k`/`K`, `M`, `G`, `T`.
    var suffixPower: Int? { onlyScalar.flatMap(NumberReader.suffixPower) }

    /// `+`, `-` or `−`.
    var isSign: Bool { onlyScalar.map(NumberReader.isSign) ?? false }

    /// Whitespace, decided per scalar: a space that carries combining marks is one character, but not whitespace.
    /// Taken for whitespace, it would let one character of an expression hold any amount of text, which messages
    /// then repeat.
    var isCalcWhitespace: Bool { unicodeScalars.allSatisfy(\.properties.isWhitespace) }

    var isASCIILetter: Bool {
        guard let ascii = asciiValue else { return false }
        return (65...90).contains(ascii) || (97...122).contains(ascii)
    }
}
