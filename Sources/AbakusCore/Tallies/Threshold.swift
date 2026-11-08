import Foundation

/// A threshold on a tally (ADR-0004). It watches the value or the count and informs; it never blocks.
///
/// Crossing: an addition crosses a mark `m` when `before < m <= after`, upward only. A mark is reported by every
/// addition that takes the tally from below it to it or past it, so a tally that goes back below a mark (a
/// negative amount, `tally_set`) reports it again on the way up. `every p` has the marks p, 2p, 3p, ...
struct Threshold: Sendable, Equatable {
    enum Measure: String, Sendable, CaseIterable {
        case value
        case count
    }

    enum Rule: Sendable, Equatable {
        /// A ceiling. Its crossing is reported once; the status of every response says whether it is reached.
        case limit(Decimal)
        /// Marks, ascending and without duplicates.
        case at([Decimal])
        /// A period, greater than 0.
        case every(Decimal)
    }

    var rule: Rule
    var of: Measure

    init(_ rule: Rule, of: Measure = .value) {
        if case .at(let marks) = rule {
            self.rule = .at(Self.ascendingUnique(marks))
        } else {
            self.rule = rule
        }
        self.of = of
    }

    /// Up to this many `every` marks crossed by one addition are listed; beyond it, a crossing gives a count.
    static let listedMarks = 10

    static let example = #"[{"limit": 20}, {"every": 5, "of": "count"}]"#

    private static func ascendingUnique(_ marks: [Decimal]) -> [Decimal] {
        var result: [Decimal] = []
        for mark in marks.sorted() where result.last != mark {
            result.append(mark)
        }
        return result
    }
}

// MARK: - Reading the argument

extension Threshold {
    /// Reads the `thresholds` argument: a list of objects with exactly one of `limit`, `at` or `every`, and
    /// optionally `of`.
    static func parseList(_ value: JSONValue, numbers: inout NumberReading) throws(ToolError) -> [Threshold] {
        guard let items = value.arrayValue else {
            throw ToolError("thresholds must be a list, for example \(example). Pass [] for none.")
        }
        var result: [Threshold] = []
        for (index, item) in items.enumerated() {
            result.append(try parse(item, label: "thresholds[\(index)]", numbers: &numbers))
        }
        return result
    }

    static func parse(_ value: JSONValue, label: String, numbers: inout NumberReading) throws(ToolError) -> Threshold {
        let shape = #"exactly one of limit (a ceiling), at (a list of marks) or every (a period), and optionally of: "value" (the default) or "count""#
        guard let object = value.objectValue else {
            throw ToolError("\(label) must be an object with \(shape), e.g. {\"every\": 5, \"of\": \"count\"}.")
        }
        for key in object.keys where !["limit", "at", "every", "of"].contains(key) {
            throw ToolError("\(label) has an unknown key \"\(key)\". A threshold has \(shape).")
        }
        let kinds = ["limit", "at", "every"].filter { object[$0].map { !$0.isNull } ?? false }
        guard kinds.count == 1, let kind = kinds.first, let given = object[kind] else {
            let found = kinds.isEmpty ? "none" : kinds.joined(separator: " and ")
            throw ToolError("\(label) has \(found); a threshold has \(shape). Give each threshold its own item, e.g. \(example).")
        }

        let of: Measure
        switch object["of"] {
        case nil, .null?:
            of = .value
        case .string(let text)? where Measure(rawValue: text) != nil:
            of = Measure(rawValue: text)!
        default:
            throw ToolError("\(label).of must be \"value\" or \"count\"; leave it out to watch the value.")
        }

        let rule: Rule
        switch kind {
        case "limit":
            rule = .limit(try numbers.read(given, as: "\(label).limit"))
        case "at":
            guard let items = given.arrayValue, !items.isEmpty else {
                throw ToolError("\(label).at must be a non-empty list of numbers, e.g. [10, 50].")
            }
            var marks: [Decimal] = []
            for (index, item) in items.enumerated() {
                marks.append(try numbers.read(item, as: "\(label).at[\(index)]"))
            }
            rule = .at(marks)
        default:
            let period = try numbers.read(given, as: "\(label).every")
            guard period > 0 else {
                throw ToolError("\(label).every must be greater than 0.")
            }
            rule = .every(period)
        }

        let threshold = Threshold(rule, of: of)
        if of == .count, !threshold.numbers.allSatisfy(\.isWhole) {
            throw ToolError("\(label) watches the count, which is a whole number of additions, so its numbers must be whole numbers too.")
        }
        return threshold
    }

    private var numbers: [Decimal] {
        switch rule {
        case .limit(let limit): [limit]
        case .at(let marks): marks
        case .every(let period): [period]
        }
    }
}

// MARK: - Status and crossings

extension Threshold {
    /// The threshold as responses show it, e.g. `{"every": 5, "of": "count"}`.
    var spec: JSONObject {
        var object = JSONObject()
        switch rule {
        case .limit(let limit): object["limit"] = .decimal(limit)
        case .at(let marks): object["at"] = .array(marks.map(JSONValue.decimal))
        case .every(let period): object["every"] = .decimal(period)
        }
        object["of"] = .string(of.rawValue)
        return object
    }

    func measure(_ tally: Tally) -> Decimal {
        switch of {
        case .value: tally.value
        case .count: Decimal(tally.count)
        }
    }

    /// The spec plus where the tally stands: a limit says whether it is reached and what remains or how far
    /// past it the tally is; `at` and `every` give the next mark above the current value (`at` none when all
    /// marks are passed).
    func status(of tally: Tally) throws(ToolError) -> JSONObject {
        var object = spec
        let current = measure(tally)
        switch rule {
        case .limit(let limit):
            let reached = current >= limit
            let distance = reached ? try DecimalMath.subtract(current, limit) : try DecimalMath.subtract(limit, current)
            object["reached"] = .bool(reached)
            object[reached ? "over" : "remaining"] = .decimal(distance.value)
            if !distance.exact { object["exact"] = false }
        case .at(let marks):
            if let next = marks.first(where: { $0 > current }) {
                object["next"] = .decimal(next)
            }
        case .every(let period):
            let passed = try Self.multiples(upTo: current, of: period)
            object["next"] = .decimal(try DecimalMath.multiply(passed + 1, period).value)
        }
        return object
    }

    /// What going from `before` to `after` crossed, or nil if nothing:
    /// `{"limit": 20, "of": "value"}`, `{"at": [10], "of": "value"}` (the marks crossed), or
    /// `{"every": 5, "of": "count", "at": [10]}`; for more than `listedMarks` multiples
    /// `{"every": 1, "of": "value", "times": 250, "first": 1, "last": 250}`.
    func crossing(from before: Tally, to after: Tally) throws(ToolError) -> JSONObject? {
        let old = measure(before), new = measure(after)
        guard new > old else { return nil }
        switch rule {
        case .limit(let limit):
            return old < limit && limit <= new ? spec : nil
        case .at(let marks):
            let crossed = marks.filter { old < $0 && $0 <= new }
            if crossed.isEmpty { return nil }
            return ["at": .array(crossed.map(JSONValue.decimal)), "of": .string(of.rawValue)]
        case .every(let period):
            let low = try Self.multiples(upTo: old, of: period)
            let high = try Self.multiples(upTo: new, of: period)
            guard high > low else { return nil }
            var object: JSONObject = ["every": .decimal(period), "of": .string(of.rawValue)]
            let times = high - low
            if times <= Decimal(Self.listedMarks) {
                var marks: [JSONValue] = []
                var multiple = low + 1
                while multiple <= high {
                    marks.append(.decimal(try DecimalMath.multiply(multiple, period).value))
                    multiple += 1
                }
                object["at"] = .array(marks)
            } else {
                object["times"] = .decimal(times)
                object["first"] = .decimal(try DecimalMath.multiply(low + 1, period).value)
                object["last"] = .decimal(try DecimalMath.multiply(high, period).value)
            }
            return object
        }
    }

    /// How many of the marks `period`, 2·`period`, ... are at most `x`: floor(x / period), and 0 below `period`.
    static func multiples(upTo x: Decimal, of period: Decimal) throws(ToolError) -> Decimal {
        guard x >= period else { return 0 }
        var count = try DecimalMath.divide(x, period).value.roundedDown
        // The quotient is rounded to 38 digits, which can put the floor one off; check against the products.
        // (Two steps at most each way: near 10^38, `count ± 1` may itself round.)
        var steps = 0
        while steps < 2, try DecimalMath.multiply(count, period).value > x {
            count -= 1
            steps += 1
        }
        steps = 0
        while steps < 2, try DecimalMath.multiply(count + 1, period).value <= x {
            count += 1
            steps += 1
        }
        return count
    }
}

// fileprivate, so these never clash with helpers other areas add to Decimal.
extension Decimal {
    /// Rounded toward negative infinity to a whole number.
    fileprivate var roundedDown: Decimal {
        var source = self, result = Decimal()
        NSDecimalRound(&result, &source, 0, .down)
        return result
    }

    fileprivate var isWhole: Bool {
        var source = self, result = Decimal()
        NSDecimalRound(&result, &source, 0, .plain)
        return result == self
    }
}
