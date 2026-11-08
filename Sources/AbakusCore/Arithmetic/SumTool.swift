import Foundation

/// `sum`: adds a list of numbers exactly and reports how each string was read (ADR-0005).
public struct SumTool: Tool {
    public init() {}

    public let name = "sum"

    public let description = """
        Adds numbers exactly, in decimal arithmetic, and returns the total, the count and the mean. Use it instead \
        of adding in your head or with a binary floating point tool (bc, awk, a quick script) whenever the total \
        matters, and for numbers written as text (410k, 1,234.5, 1.234,5).

        Arguments: numbers, a list of JSON numbers or number strings (an empty list gives total 0 and mean null); \
        decimal, "." (default) or ",", the decimal mark in the strings.

        \(NumberReader.rulesSummary)

        Response: {"total", "count", "mean", "read"}. read lists how each string was read, as \
        [{"index": 0, "input": "410k", "value": 410000}]; check it when an input could be read two ways. JSON \
        numbers are not listed. The total is exact unless it has more than 38 significant digits; then it is \
        rounded and total_exact: false is added. The mean is exact when it fits in 38 digits; otherwise it is \
        rounded half away from zero to 15 significant digits (to whole units when the integer part is longer; \
        1/3 shows as 0.333333333333333), and mean_exact: false is added. Without these flags, total and mean are \
        exact.
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
                    "The mean, \(total.value) / \(values.count), is below 10^-128, too close to zero for exact decimal "
                        + "arithmetic. The total itself is \(total.exact ? "exact" : "rounded"): \(total.value)."
                )
            }
            result["mean"] = .decimal(mean.value)
            if !mean.exact { result["mean_exact"] = false }
        }
        if !read.isEmpty { result["read"] = .array(read) }
        return result
    }
}
