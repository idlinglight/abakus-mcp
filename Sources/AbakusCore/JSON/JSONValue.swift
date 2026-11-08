import Foundation

/// A JSON value. Numbers are kept as their literal text, so no binary floating point is ever involved
/// (ADR-0005): `0.1` stays `"0.1"` from the request to the arithmetic and back.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A number as its JSON literal, e.g. `"0.1"`, `"-2"`, `"2.5e3"`. Must be a valid JSON number literal.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

extension JSONValue {
    /// A number in plain notation (no exponent), as responses carry them (ADR-0005).
    /// `Decimal.description` is locale independent and never uses an exponent. Never pass NaN.
    public static func decimal(_ value: Decimal) -> JSONValue {
        .number(value.description)
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The literal text of a number.
    public var numberLiteral: String? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// What the value is, for messages about an argument of the wrong kind: `null`, `true`, `false`, `a number`,
    /// `a string`, `a list`, `an object`.
    var kindForMessage: String {
        switch self {
        case .null: "null"
        case .bool(let flag): String(flag)
        case .number: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(String(value)) }
}

// No ExpressibleByFloatLiteral on purpose: a float literal is binary floating point. Write `.number("0.1")`.

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements))
    }
}

/// A JSON object that keeps its keys in insertion order, so responses read in a deliberate order
/// (`name`, `value`, `count`, ...). Equality ignores order, as JSON's does.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [(key: String, value: JSONValue)]

    public init() {
        entries = []
    }

    /// Later duplicates of a key replace the earlier value in its original position.
    public init(_ pairs: [(String, JSONValue)]) {
        entries = []
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    /// Setting a value for an existing key replaces it in place; setting `nil` removes the key.
    public subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            let index = entries.firstIndex { $0.key == key }
            switch (index, newValue) {
            case (let i?, let v?): entries[i].value = v
            case (let i?, nil): entries.remove(at: i)
            case (nil, let v?): entries.append((key, v))
            case (nil, nil): break
            }
        }
    }

    public var keys: [String] { entries.map(\.key) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.entries.allSatisfy { rhs[$0.key] == $0.value }
    }
}

extension JSONObject {
    /// Stores `entries` as they are, in linear time. The caller guarantees that no two keys are equal;
    /// `init(_:)` checks that itself and takes quadratic time for it. `JSONReader` uses this after its own
    /// duplicate check.
    init(uniqueEntries entries: [(key: String, value: JSONValue)]) {
        self.init()
        self.entries = entries
    }
}
