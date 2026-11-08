import Foundation

/// A number that came as a string, and how it was read. Responses list these (ADR-0005), so a misreading such
/// as `1,234` taken as 1234 is visible.
struct NumberRead: Sendable, Equatable {
    var input: String
    var value: Decimal
}

/// Reads number arguments with one decimal mark and remembers which strings it read.
struct NumberReading {
    let decimal: DecimalMark
    private(set) var reads: [NumberRead] = []

    init(decimal: DecimalMark = .point) {
        self.decimal = decimal
    }

    /// `label` names the argument in errors, e.g. `amount` or `thresholds[1].every`.
    mutating func read(_ value: JSONValue, as label: String) throws(ToolError) -> Decimal {
        let number: Decimal
        do throws(ToolError) {
            number = try NumberReader.read(value, decimal: decimal)
        } catch {
            throw ToolError("\(label): \(error.message)", details: error.details)
        }
        if case .string(let text) = value {
            reads.append(NumberRead(input: text, value: number))
        }
        return number
    }
}

/// The arguments of one tally tool call. Unknown keys are refused, so a typo (`amout`) fails loudly instead of
/// being ignored, and JSON null counts as absent.
struct TallyArguments {
    private let raw: JSONObject
    private(set) var numbers: NumberReading

    var reads: [NumberRead] { numbers.reads }

    init(_ raw: JSONObject, allowed: [String]) throws(ToolError) {
        for key in raw.keys where !allowed.contains(key) {
            throw ToolError(
                "Unknown argument \"\(key)\". This tool takes \(allowed.map { "\"\($0)\"" }.joined(separator: ", ")).",
                details: ["argument": .string(key)]
            )
        }
        self.raw = raw
        var mark = DecimalMark.point
        if let value = raw["decimal"], !value.isNull {
            guard let text = value.stringValue, let given = DecimalMark(rawValue: text) else {
                throw ToolError("decimal must be \".\" or \",\": the mark between the integer part and the fraction in number strings. Leave it out for \".\".")
            }
            mark = given
        }
        numbers = NumberReading(decimal: mark)
    }

    subscript(key: String) -> JSONValue? {
        guard let value = raw[key], !value.isNull else { return nil }
        return value
    }

    /// The `name` argument, required. Whether it is a valid name is checked separately (`TallyName.validate`).
    func name() throws(ToolError) -> String {
        guard let value = self["name"] else {
            throw ToolError("Missing argument \"name\": the tally's name.")
        }
        guard let text = value.stringValue else {
            throw ToolError("name must be a string, e.g. \"items\".")
        }
        return text
    }

    func string(_ key: String) throws(ToolError) -> String? {
        guard let value = self[key] else { return nil }
        guard let text = value.stringValue else { throw ToolError("\(key) must be a string.") }
        return text
    }

    func bool(_ key: String) throws(ToolError) -> Bool? {
        guard let value = self[key] else { return nil }
        guard let flag = value.boolValue else { throw ToolError("\(key) must be true or false.") }
        return flag
    }

    mutating func number(_ key: String) throws(ToolError) -> Decimal? {
        guard let value = self[key] else { return nil }
        return try numbers.read(value, as: key)
    }

    /// A count: a whole number, 0 or more (`Tally.checkedCount`, the rule files follow too).
    mutating func count(_ key: String) throws(ToolError) -> Int? {
        guard let number = try number(key) else { return nil }
        return try Tally.checkedCount(number, label: key)
    }

    mutating func thresholds() throws(ToolError) -> [Threshold]? {
        guard let value = self["thresholds"] else { return nil }
        return try Threshold.parseList(value, numbers: &numbers)
    }
}
