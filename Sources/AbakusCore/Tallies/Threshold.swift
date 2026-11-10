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

    /// Up to this many marks of one threshold (`at` or `every`) crossed by one addition are listed; beyond it, a
    /// crossing gives a count with the first and the last (ADR-0008: a list of a fixed length, then a count).
    static let listedMarks = 10

    /// tally_create and tally_set take at most this many thresholds. An `at` threshold takes any number of marks:
    /// its status shows how many, not the marks (ADR-0004, amendment of 2026-11-10). The cap keeps responses small;
    /// it does not make a threshold invalid, so a tally file written before it, with more, still loads.
    static let maximumPerTally = 5

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
        do throws(ToolError) {
            try checkCount(items.count)
        } catch {
            throw ToolError(
                "\(error.message) Pass at most \(maximumPerTally): one at threshold takes any number of marks, so marks on the value (or on the count) fit in one, e.g. {\"at\": [10, 50, 100]}. To watch more, create a second tally with the others and add to both."
            )
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
            rule = .limit(try numbers.read(given, as: "\(label).limit", wholeNumber: of == .count))
        case "at":
            guard let items = given.arrayValue else {
                throw ToolError("\(label).at must be a non-empty list of numbers, e.g. [10, 50].")
            }
            var marks: [Decimal] = []
            for (index, item) in items.enumerated() {
                marks.append(try numbers.read(item, as: "\(label).at[\(index)]", wholeNumber: of == .count))
            }
            rule = .at(marks)
        default:
            rule = .every(try numbers.read(given, as: "\(label).every", wholeNumber: of == .count))
        }
        return try checked(rule, of: of, label: label)
    }

    /// The cap on how many thresholds an argument may give (`maximumPerTally`). Tally files are not held to it.
    static func checkCount(_ count: Int) throws(ToolError) {
        guard count <= maximumPerTally else {
            throw ToolError("thresholds has \(count) items, and a tally takes at most \(maximumPerTally).")
        }
    }

    /// The rules every threshold follows, whether it comes from an argument or from a tally file: `at` has at
    /// least one mark, `every` is greater than 0, and a threshold on the count uses whole numbers only.
    static func checked(_ rule: Rule, of: Measure, label: String) throws(ToolError) -> Threshold {
        switch rule {
        case .limit:
            break
        case .at(let marks):
            guard !marks.isEmpty else {
                throw ToolError("\(label).at must be a non-empty list of numbers, e.g. [10, 50].")
            }
        case .every(let period):
            guard period > 0 else {
                throw ToolError("\(label).every must be greater than 0.")
            }
        }
        let threshold = Threshold(rule, of: of)
        if of == .count, !threshold.numbers.allSatisfy(DecimalMath.isInteger) {
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
    /// The threshold as responses show it, e.g. `{"every": 5, "of": "count"}`: its kind and what it watches. An
    /// `at` threshold shows how many marks it has, not the marks (`{"marks": 50, "of": "value"}`), so a response
    /// does not grow with them (ADR-0008); the tally file keeps them all. Statuses and crossings start with this.
    var spec: JSONObject {
        var object = JSONObject()
        switch rule {
        case .limit(let limit): object["limit"] = .decimal(limit)
        case .at(let marks): object["marks"] = .number(String(marks.count))
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
    /// past it the tally is; `at` says how many of its marks are passed (at or below the current value or count)
    /// and the next one, none when all are passed; `every` gives the next mark above the current value.
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
            // Ascending, so the marks passed come first and the next one follows them.
            let passed = Self.marksReached(by: current, in: marks)
            object["passed"] = .number(String(passed))
            if passed < marks.count {
                object["next"] = .decimal(marks[passed])
            }
        case .every(let period):
            let passed = try Self.multiples(upTo: current, of: period)
            let following = try DecimalMath.add(passed, 1)
            let next = try DecimalMath.multiply(following.value, period)
            object["next"] = .decimal(next.value)
            // Near 38 significant digits, the next mark may not be representable.
            if !(following.exact && next.exact && next.value > current) { object["exact"] = false }
        }
        return object
    }

    /// What going from `before` to `after` crossed, or nil if nothing. It starts with the spec, as the status does:
    /// `{"limit": 20, "of": "value"}`, `{"marks": 50, "of": "value", "at": [10]}` (the marks crossed), or
    /// `{"every": 5, "of": "count", "at": [10]}`. For more than `listedMarks` marks crossed, a count with the first
    /// and the last: `{"marks": 400, "of": "value", "times": 250, "first": 1, "last": 250}`, or
    /// `{"every": 1, "of": "value", "times": 250, "first": 1, "last": 250}`, which also serves when neighbouring
    /// multiples cannot be told apart in 38 digits (then with `"exact": false`).
    func crossing(from before: Tally, to after: Tally) throws(ToolError) -> JSONObject? {
        let old = measure(before), new = measure(after)
        guard new > old else { return nil }
        switch rule {
        case .limit(let limit):
            return old < limit && limit <= new ? spec : nil
        case .at(let marks):
            // The marks crossed are the ones in (old, new]: a range of the ascending marks, found by two searches.
            let crossed = Self.marksReached(by: old, in: marks)..<Self.marksReached(by: new, in: marks)
            guard !crossed.isEmpty else { return nil }
            var object = spec
            if crossed.count <= Self.listedMarks {
                object["at"] = .array(marks[crossed].map(JSONValue.decimal))
            } else {
                object["times"] = .number(String(crossed.count))
                object["first"] = .decimal(marks[crossed.lowerBound])
                object["last"] = .decimal(marks[crossed.upperBound - 1])
            }
            return object
        case .every(let period):
            let low = try Self.multiples(upTo: old, of: period)
            let high = try Self.multiples(upTo: new, of: period)
            guard high > low else { return nil }
            var object: JSONObject = ["every": .decimal(period), "of": .string(of.rawValue)]
            let times = try DecimalMath.subtract(high, low)
            if times.exact, let count = Int(times.value.description), (1...Self.listedMarks).contains(count),
               let marks = try Self.marks(after: low, count: count, period: period, above: old, upTo: new) {
                object["at"] = .array(marks.map(JSONValue.decimal))
            } else {
                let firstMultiple = try DecimalMath.add(low, 1)
                let first = try DecimalMath.multiply(firstMultiple.value, period)
                let last = try DecimalMath.multiply(high, period)
                object["times"] = .decimal(times.value)
                object["first"] = .decimal(first.value)
                object["last"] = .decimal(last.value)
                let exact = times.exact && firstMultiple.exact && first.exact && last.exact
                    && old < first.value && first.value <= last.value && last.value <= new
                if !exact { object["exact"] = false }
            }
            return object
        }
    }

    /// The marks (low + 1)·period, …, (low + count)·period, each computed from its integer index, or nil if
    /// rounding to 38 digits makes them anything but strictly increasing within (old, new]. The loop runs over
    /// an `Int`: near 10^38, `low + 1` can equal `low`, so stepping a `Decimal` might never get anywhere.
    private static func marks(
        after low: Decimal, count: Int, period: Decimal, above old: Decimal, upTo new: Decimal
    ) throws(ToolError) -> [Decimal]? {
        var marks: [Decimal] = []
        for index in 1...count {
            let multiple = try DecimalMath.add(low, Decimal(index))
            let mark = try DecimalMath.multiply(multiple.value, period)
            guard multiple.exact, mark.exact, mark.value > (marks.last ?? old), mark.value <= new else { return nil }
            marks.append(mark.value)
        }
        return marks
    }

    /// How many of the ascending `marks` are at or below `x`, which is also the index of the first mark above it.
    /// A binary search: an `at` threshold may have any number of marks.
    static func marksReached(by x: Decimal, in marks: [Decimal]) -> Int {
        var low = 0, high = marks.count
        while low < high {
            let middle = low + (high - low) / 2
            if marks[middle] <= x {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// How many of the marks `period`, 2·`period`, ... are at most `x`: floor(x / period), and 0 below `period`.
    /// The floor of the exact quotient: rounding the quotient to 38 digits first could put it one too high
    /// (39999999999999999999999999999999999999 / 2 would round to 2e37).
    static func multiples(upTo x: Decimal, of period: Decimal) throws(ToolError) -> Decimal {
        guard x >= period else { return 0 }
        return try DecimalMath.divide(x, period, toPlaces: 0, .down).value
    }
}
