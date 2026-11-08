import Foundation

/// A tally (ADR-0004): a named `value`, the exact sum of the amounts added, and a `count` of additions.
struct Tally: Sendable, Equatable {
    var name: String
    var value: Decimal = 0
    var count: Int = 0
    /// False once any addition had to be rounded (ADR-0005). Setting the value makes it true again.
    var exact: Bool = true
    var thresholds: [Threshold] = []
    /// ISO 8601 in UTC, whole seconds.
    var created: String
    var updated: String

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// The rule for a count, from an argument or from a tally file: a whole number of additions, 0 or more.
    static func checkedCount(_ number: Decimal, label: String) throws(ToolError) -> Int {
        // `Decimal.description` of a whole number is its digits (no exponent, no ".0"), so Int(_:) is exact here
        // and refuses fractions and numbers too large to be a count.
        guard let count = Int(number.description), count >= 0 else {
            throw ToolError("\(label) must be a whole number, 0 or more (it counts additions); got \(number).")
        }
        return count
    }
}

// MARK: - File format

/// The file `tallies/<name>.json` (ADR-0003). Decimals are JSON strings, so no binary floating point is
/// involved on the way to disk and back; `format` lets a later version change the layout.
///
///     {"count": 7, "created": "...", "exact": true, "format": 1, "name": "items",
///      "thresholds": [{"limit": "20", "of": "value"}], "updated": "...", "value": "12.5"}
private struct TallyFile: Codable {
    var format: Int
    var name: String
    var value: String
    var count: Int
    var exact: Bool
    var thresholds: [ThresholdFile]
    var created: String
    var updated: String
}

/// One threshold in the file, in the shape of the argument: exactly one of `limit`, `at`, `every`.
private struct ThresholdFile: Codable {
    var limit: String?
    var at: [String]?
    var every: String?
    var of: String
}

private struct FormatProbe: Decodable {
    var format: Int
}

extension Tally {
    static let fileFormat = 1

    func fileData() throws(ToolError) -> Data {
        let file = TallyFile(
            format: Self.fileFormat,
            name: name,
            value: value.description,
            count: count,
            exact: exact,
            thresholds: thresholds.map { threshold in
                switch threshold.rule {
                case .limit(let limit):
                    ThresholdFile(limit: limit.description, of: threshold.of.rawValue)
                case .at(let marks):
                    ThresholdFile(at: marks.map(\.description), of: threshold.of.rawValue)
                case .every(let period):
                    ThresholdFile(every: period.description, of: threshold.of.rawValue)
                }
            },
            created: created,
            updated: updated
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(file)
        } catch {
            throw ToolError("Cannot encode the tally \"\(name)\": \(error.localizedDescription)")
        }
    }

    /// Reads a tally file. Throws a plain description of what is wrong (a clause, no final period); the caller
    /// adds which file it was. The name comes from the file name, which is what the tally is found by.
    ///
    /// A file has to meet the same rules as arguments (`Threshold.checked`, `Tally.checkedCount`): whatever
    /// fails them is unreadable, not half-trusted.
    init(fileData data: Data, name: String) throws(ToolError) {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(FormatProbe.self, from: data) else {
            throw ToolError("it is not a tally file (no format version)")
        }
        guard probe.format >= 1 else {
            throw ToolError("it has an invalid file format version (\(probe.format))")
        }
        guard probe.format <= Self.fileFormat else {
            throw ToolError("it was written by a newer version of abakus (file format \(probe.format); this version reads \(Self.fileFormat))")
        }
        let file: TallyFile
        do {
            file = try decoder.decode(TallyFile.self, from: data)
        } catch {
            throw ToolError("it is damaged (\(error.localizedDescription))")
        }
        var thresholds: [Threshold] = []
        for (index, item) in file.thresholds.enumerated() {
            let label = "thresholds[\(index)]"
            guard let of = Threshold.Measure(rawValue: item.of) else {
                throw ToolError("it has a threshold on \"\(item.of)\", which is neither value nor count")
            }
            let rule: Threshold.Rule
            switch (item.limit, item.at, item.every) {
            case (let limit?, nil, nil):
                rule = .limit(try Self.decimal(limit))
            case (nil, let marks?, nil):
                var values: [Decimal] = []
                for mark in marks { values.append(try Self.decimal(mark)) }
                rule = .at(values)
            case (nil, nil, let period?):
                rule = .every(try Self.decimal(period))
            default:
                throw ToolError("it has a threshold without exactly one of limit, at and every")
            }
            do throws(ToolError) {
                thresholds.append(try Threshold.checked(rule, of: of, label: label))
            } catch {
                throw ToolError("it has an invalid threshold (\(Self.clause(error.message)))")
            }
        }
        let count: Int
        do throws(ToolError) {
            count = try Self.checkedCount(Decimal(file.count), label: "count")
        } catch {
            throw ToolError("it has an invalid count (\(Self.clause(error.message)))")
        }
        self.init(
            name: name,
            value: try Self.decimal(file.value),
            count: count,
            exact: file.exact,
            thresholds: thresholds,
            created: file.created,
            updated: file.updated
        )
    }

    /// A sentence as a clause to embed: without its final period.
    private static func clause(_ sentence: String) -> String {
        sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }

    /// Decimals in files are written by `Decimal.description`: plain notation, `.` as the decimal mark, which is
    /// a JSON number literal. They are read back exactly, by the rules arguments follow; a stored value that
    /// does not read (malformed, more than 38 significant digits, out of range) makes the file unreadable.
    private static func decimal(_ text: String) throws(ToolError) -> Decimal {
        do throws(ToolError) {
            return try NumberReader.read(.number(text))
        } catch {
            throw ToolError("it holds \"\(text)\" where a number belongs (\(clause(error.message)))")
        }
    }
}
