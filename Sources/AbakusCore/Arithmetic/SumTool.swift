import Foundation

/// `sum`: adds a list of numbers exactly (ADR-0005). How each string was read is a detail: the command line prints
/// it, an MCP result leaves it out (ADR-0008).
public struct SumTool: Tool {
    public init() {}

    public let name = "sum"

    public let detailKeys = ["read"]

    public let description = """
        Adds numbers exactly, in decimal arithmetic, and returns the total, the count and the mean. Use it instead \
        of adding in your head or with a binary floating point tool (bc, awk, a quick script) whenever the total \
        matters, and for numbers written as text (410k, 1,234.5, 1.234,5).

        Arguments: numbers, a list of JSON numbers or number strings (an empty list gives total 0 and mean null); \
        decimal, "." (default) or ",", the decimal mark in the strings.

        \(NumberReader.rulesSummary)

        Response: {"total", "count", "mean"}, plus notes when a string reads differently with the other decimal \
        mark ("1,234" is 1234 with decimal ".", 1.234 with ","): one sentence with the first such string, both \
        readings and what to do. The total is exact unless it has more than 38 significant digits; \
        then it is rounded and total_exact: false is added. The mean is exact when it fits in 38 digits; \
        otherwise it is rounded half away from zero to 15 significant digits (to whole units when the integer \
        part is longer; 1/3 shows as 0.333333333333333), and mean_exact: false is added. Without these flags, \
        total and mean are exact. To see how one string is read, sum it alone: {"numbers": ["410k"]}.

        The abakus command line (abakus sum, the same program as this server) prints the same result plus read, \
        how each string was read, as [{"index": 0, "input": "410k", "value": 410000}]; it also reads numbers \
        from stdin.
        """

    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "numbers": [
                "type": "array",
                "items": ["type": ["number", "string"]],
                "description": "The numbers to add: JSON numbers, or strings such as \"410k\" or \"1,234.5\".",
            ],
            "decimal": DecimalMark.schema,
        ],
        "required": ["numbers"],
        "additionalProperties": false,
    ]

    public let annotations = ToolAnnotations(title: "Exact sum", readOnly: true, destructive: false, idempotent: true)

    public func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        try UnknownArguments.refuse(arguments, for: self)
        let decimal = try DecimalMark.argument(arguments["decimal"])
        guard let numbers = arguments["numbers"], !numbers.isNull else {
            throw ToolError("numbers is missing: pass the numbers to add as a list, e.g. {\"numbers\": [12.5, \"410k\"]}.")
        }
        guard let items = numbers.arrayValue else {
            throw ToolError("numbers must be a list of numbers or number strings, e.g. [12.5, \"410k\"], not a single value.")
        }

        var values: [Decimal] = []
        var read: [JSONValue] = []
        var otherReadings = OtherDecimalReadings(decimal: decimal)
        for (index, item) in items.enumerated() {
            let value: Decimal
            do {
                value = try NumberReader.read(item, decimal: decimal)
            } catch {
                var details: JSONObject = ["index": .number(String(index))]
                for (key, detail) in error.details?.entries ?? [] { details[key] = detail }
                throw ToolError("numbers[\(index)]: \(error.message)", details: details)
            }
            values.append(value)
            if case .string(let text) = item {
                read.append(["index": .number(String(index)), "input": .string(text), "value": .decimal(value)])
                otherReadings.check(text, index: index, value: value)
            }
        }

        let exactTotal = try DecimalMath.exactSum(values)
        let total = try DecimalMath.round(exactTotal)
        var result: JSONObject = ["total": .decimal(total.value)]
        if !total.exact { result["total_exact"] = false }
        result["count"] = .number(String(values.count))
        if values.isEmpty {
            result["mean"] = .null
        } else {
            // From the exact total, not the rounded one.
            let mean: DecimalMath.Result
            do {
                mean = try DecimalMath.round(exactTotal, dividingBy: BigUInt(UInt64(values.count)), .readable)
            } catch {
                // Only an underflow is possible: the mean is never larger than the total.
                throw ToolError(
                    "The mean, \(total.value) / \(values.count), is below 10^\(ExactDecimal.minimumExponent), too close "
                        + "to zero for exact decimal arithmetic. The total itself is \(total.exact ? "exact" : "rounded"): \(total.value)."
                )
            }
            result["mean"] = .decimal(mean.value)
            if !mean.exact { result["mean_exact"] = false }
        }
        if let note = otherReadings.note { result["notes"] = [.string(note)] }
        if !read.isEmpty { result["read"] = .array(read) }
        return result
    }
}

/// Strings that the other `decimal` setting reads as a different number: `"1,234"` is 1234 with ".", 1.234 with
/// ",". Such a string contains "." or "," and the other setting reads it as well; the two values then always
/// differ, since the mark is the decimal mark in one reading and groups thousands in the other (ADR-0008).
struct OtherDecimalReadings {
    let decimal: DecimalMark
    private(set) var count = 0
    private var first: (index: Int, text: String, value: Decimal, other: Decimal)?

    init(decimal: DecimalMark) {
        self.decimal = decimal
    }

    mutating func check(_ text: String, index: Int, value: Decimal) {
        guard text.contains(where: { $0 == "." || $0 == "," }) else { return }
        let otherMark: DecimalMark = decimal == .point ? .comma : .point
        guard let other = try? NumberReader.read(.string(text), decimal: otherMark) else { return }
        count += 1
        if first == nil { first = (index, text, value, other) }
    }

    /// One sentence of fixed size, however many such strings there are: how many, the first one with both readings,
    /// and what to do. nil when there are none.
    var note: String? {
        guard let first else { return nil }
        let setting = decimal == .point ? #"decimal: ",""# : #"decimal: "." (the default)"#
        let advice = decimal == .point
            ? #"If the numbers use a decimal comma, call again with decimal: ","."#
            : "If the numbers use a decimal point, call again without decimal."
        let string = "\(first.text.quotedForMessage) (numbers[\(first.index)])"
        let reading = "was read as \(first.value); with \(setting) it would be \(first.other)."
        if count == 1 {
            return "\(string) \(reading) \(advice)"
        }
        return "\(count) strings read differently with the other decimal mark. The first, \(string), \(reading) \(advice)"
    }
}
