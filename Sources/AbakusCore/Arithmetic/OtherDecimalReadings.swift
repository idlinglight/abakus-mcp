import Foundation

/// Strings that the other `decimal` setting reads as a different number: `"1,234"` is 1234 with ".", 1.234 with
/// ",". Such a string contains "." or "," and the other setting reads it as well; the two values then always
/// differ, since the mark is the decimal mark in one reading and groups thousands in the other (and grouping
/// excludes a leading 0, so `0.000` is not a case). ADR-0008, section "sum"; the tally tools use it too.
///
/// A string with a mark that only the current setting reads (`"12.50"`, `"1,234.5"` with ".") shows how the call's
/// numbers are written: then there is no note, since calling again with the other mark would fail on that string.
/// The same holds for a string whose other reading the argument refuses: a fraction where only whole numbers go
/// (a count, a threshold on the count).
struct OtherDecimalReadings: Sendable {
    /// The first string that reads differently with the other mark.
    struct Reading: Sendable, Equatable {
        /// Where the string was, as errors name it: `numbers[2]`, `amount`, `thresholds[0].at[2]`.
        var label: String
        var text: String
        var value: Decimal
        /// What the other setting reads.
        var other: Decimal
    }

    let decimal: DecimalMark
    private(set) var count = 0
    /// A string that the other setting cannot read, or reads as something the argument refuses, was seen. Later
    /// strings need no second reading.
    private(set) var ruledOut = false
    private(set) var first: Reading?

    init(decimal: DecimalMark) {
        self.decimal = decimal
    }

    /// `wholeNumber`: the argument takes whole numbers only, so an other reading with a fraction rules the other
    /// mark out.
    mutating func check(_ text: String, label: String, value: Decimal, wholeNumber: Bool = false) {
        guard !ruledOut, text.contains(where: { $0 == "." || $0 == "," }) else { return }
        guard let other = NumberReader.value(of: text, decimal: decimal.other),
              !wholeNumber || DecimalMath.isInteger(other)
        else {
            ruledOut = true
            return
        }
        count += 1
        if first == nil { first = Reading(label: label, text: text, value: value, other: other) }
    }

    /// The first string that reads differently, or nil when there is none or the other mark is ruled out.
    var noted: Reading? { ruledOut ? nil : first }

    /// The advice of a read-only or idempotent tool (sum, tally_set): calling again with the other mark corrects it.
    var callAgain: String {
        decimal == .point
            ? #"If the numbers use a decimal comma, call again with decimal: ","."#
            : "If the numbers use a decimal point, call again without decimal."
    }

    /// The other setting as an argument: `decimal: ","` or `decimal: "." (the default)`.
    var otherSetting: String {
        decimal == .point ? #"decimal: ",""# : #"decimal: "." (the default)"#
    }

    /// A note of fixed size, however many such strings there are: how many, the first one with both readings, and
    /// `advice`, what to do, which depends on the tool (a tool that changes state cannot be called again blindly).
    /// nil when there are none, or when a string rules the other mark out.
    func note(advice: String) -> String? {
        guard let first = noted else { return nil }
        let string = "\(first.text.quotedForMessage) (\(first.label))"
        let reading = "was read as \(first.value); with \(otherSetting) it would be \(first.other)."
        if count == 1 {
            return "\(string) \(reading) \(advice)"
        }
        return "\(count) strings read differently with the other decimal mark. The first, \(string), \(reading) \(advice)"
    }
}
