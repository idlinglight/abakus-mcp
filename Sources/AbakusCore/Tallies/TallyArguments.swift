import Foundation

/// A number that came as a string, and how it was read. The command line prints these under `read` (ADR-0005);
/// an MCP result leaves them out, since they grow with the input, and has the decimal note instead (ADR-0008).
struct NumberRead: Sendable, Equatable {
    var input: String
    var value: Decimal
}

/// Reads number arguments with one decimal mark and remembers which strings it read, and whether one of them reads
/// differently with the other mark (`otherReadings`, for the decimal note).
struct NumberReading {
    let decimal: DecimalMark
    private(set) var reads: [NumberRead] = []
    private(set) var otherReadings: OtherDecimalReadings

    init(decimal: DecimalMark = .point) {
        self.decimal = decimal
        otherReadings = OtherDecimalReadings(decimal: decimal)
    }

    /// `label` names the argument in errors and in the decimal note, e.g. `amount` or `thresholds[1].every`.
    /// `wholeNumber`: the argument takes whole numbers only (a count, a threshold on the count).
    mutating func read(_ value: JSONValue, as label: String, wholeNumber: Bool = false) throws(ToolError) -> Decimal {
        let number: Decimal
        do throws(ToolError) {
            number = try NumberReader.read(value, decimal: decimal)
        } catch {
            throw ToolError("\(label): \(error.message)", details: error.details)
        }
        if case .string(let text) = value {
            reads.append(NumberRead(input: text, value: number))
            otherReadings.check(text, label: label, value: number, wholeNumber: wholeNumber)
        }
        return number
    }
}

/// The arguments of one tally tool call. Keys the tool's schema does not list are refused (`UnknownArguments`),
/// so a typo (`amout`) fails loudly instead of being ignored, and JSON null counts as absent.
struct TallyArguments {
    private let raw: JSONObject
    private(set) var numbers: NumberReading

    var reads: [NumberRead] { numbers.reads }
    var otherReadings: OtherDecimalReadings { numbers.otherReadings }

    /// `hints` adds a sentence to the error for particular unknown keys, such as an argument that was removed.
    init(_ raw: JSONObject, for tool: some Tool, hints: [String: UnknownArguments.Hint] = [:]) throws(ToolError) {
        try UnknownArguments.refuse(raw, for: tool, hints: hints)
        self.raw = raw
        numbers = NumberReading(decimal: try DecimalMark.argument(raw["decimal"]))  // read as every tool reads it
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

    mutating func number(_ key: String, wholeNumber: Bool = false) throws(ToolError) -> Decimal? {
        guard let value = self[key] else { return nil }
        return try numbers.read(value, as: key, wholeNumber: wholeNumber)
    }

    /// A count: a whole number, 0 or more (`Tally.checkedCount`, the rule files follow too).
    mutating func count(_ key: String) throws(ToolError) -> Int? {
        guard let number = try number(key, wholeNumber: true) else { return nil }
        return try Tally.checkedCount(number, label: key)
    }

    mutating func thresholds() throws(ToolError) -> [Threshold]? {
        guard let value = self["thresholds"] else { return nil }
        return try Threshold.parseList(value, numbers: &numbers)
    }
}
