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
        rounded half away from zero to six more decimal places than the most precise input has, and \
        mean_exact: false is added. Without these flags, total and mean are exact.
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

    /// How many more decimal places than the most precise input a rounded mean shows: its rounding error then
    /// stays below a millionth of the inputs' last place.
    static let extraMeanPlaces = 6

    public func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        if let unknown = arguments.keys.first(where: { !["numbers", "decimal"].contains($0) }) {
            throw ToolError("Unknown argument \"\(unknown)\". sum takes numbers (required) and decimal.")
        }
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
            let mean = try self.mean(exactTotal, count: values.count, places: meanPlaces(values))
            result["mean"] = .decimal(mean.value)
            if !mean.exact { result["mean_exact"] = false }
        }
        if !read.isEmpty { result["read"] = .array(read) }
        return result
    }

    private func meanPlaces(_ values: [Decimal]) -> Int {
        values.map { ExactDecimal($0).fractionDigits }.max()! + Self.extraMeanPlaces
    }

    /// The mean of the exact total (not of the rounded one): exact when it fits, otherwise rounded to `places`.
    /// A mean too close to zero to show is 0, inexact, rather than an error for the whole call.
    private func mean(_ total: ExactDecimal, count: Int, places: Int) throws(ToolError) -> DecimalMath.Result {
        let divisor = BigUInt(UInt64(count))
        do {
            let full = try total.rounded(dividingBy: divisor)
            if full.exact { return DecimalMath.Result(value: full.value, exact: true) }
            let rounded = try total.rounded(dividingBy: divisor, maxPlaces: places)
            return DecimalMath.Result(value: rounded.value, exact: false)
        } catch {
            // The mean is never larger than the total, which did not overflow.
            throw DecimalMath.overflow
        }
    }
}
