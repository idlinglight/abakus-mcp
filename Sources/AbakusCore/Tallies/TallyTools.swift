import Foundation

/// Tally tools (ADR-0004): tally_create, tally_add, tally_set, tally_list, tally_drop.
public enum TallyTools {
    public static let all: [any Tool] = [TallyCreate(), TallyAdd(), TallySet(), TallyList(), TallyDrop()]
}

// MARK: - tally_create

struct TallyCreate: Tool {
    let name = "tally_create"

    let description = """
        Create a named tally: an exact value plus a count of additions, kept outside your context so it survives \
        long work and compaction. Use it to count work against a budget, to get a checkpoint every N items, or to \
        sum numbers that arrive one at a time. Names are shared by all sessions of this user: when counting your \
        own work, pass unique: true, which appends a random suffix (items becomes items-k3f9), and use the \
        returned name from then on. Optional thresholds watch the value (default) or the count: limit (a ceiling), \
        at (marks), every (a period); they inform and never block. Fails if the name exists. Returns the new \
        tally's state. \(TallySchema.numbersSentence)
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.name,
            "unique": [
                "type": "boolean",
                "default": false,
                "description": "Append a random suffix (items becomes items-k3f9) and return the name to use. Use it when counting your own work.",
            ],
            "thresholds": TallySchema.thresholds,
            "decimal": TallySchema.decimal,
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    let annotations = ToolAnnotations(title: "Create tally", readOnly: false, destructive: false, idempotent: false)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        var args = try TallyArguments(arguments, allowed: ["name", "unique", "thresholds", "decimal"])
        let requested = try args.name()
        let unique = try args.bool("unique") ?? false
        try TallyName.validate(requested, unique: unique)
        let thresholds = try args.thresholds() ?? []
        let now = Tally.timestamp(context.now())
        let reads = args.reads

        return try TallyStore(context).change(creatingFolder: true) { files throws(ToolError) in
            let name: String
            if unique {
                name = try TallyName.unique(base: requested) { candidate throws(ToolError) in files.contains(candidate) }
            } else {
                if let existing = try files.load(requested) { throw TallyErrors.exists(existing) }
                name = requested
            }
            let tally = Tally(name: name, thresholds: thresholds, created: now, updated: now)
            let response = try TallyResponse.state(tally, reads: reads)
            try files.save(tally)
            return response
        }
    }
}

// MARK: - tally_add

struct TallyAdd: Tool {
    let name = "tally_add"

    let description = """
        Add an amount to a tally (default 1, so a plain call counts one item) and get its full state back: value, \
        count, added, crossed (what this addition reached or passed: marks of at and every, a limit reached for \
        the first time; [] if nothing) and thresholds with their status (a limit says reached plus remaining or \
        over, in every response). Thresholds never block. Negative amounts subtract. \
        \(TallySchema.numbersSentence) A string's reading is shown under read. An unknown name is an error, never \
        a new tally: the name may be misspelled or expired (unchanged for about three days); tally_list shows \
        what exists.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.existingName,
            "amount": TallySchema.number(
                "What to add, default 1. Negative subtracts. A JSON number or a string like \"410k\" or \"1,234.5\".",
                default: 1
            ),
            "decimal": TallySchema.decimal,
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    let annotations = ToolAnnotations(title: "Add to tally", readOnly: false, destructive: false, idempotent: false)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        var args = try TallyArguments(arguments, allowed: ["name", "amount", "decimal"])
        let name = try args.name()
        try TallyName.validate(name)
        let amount = try args.number("amount") ?? 1
        let now = Tally.timestamp(context.now())
        let reads = args.reads

        return try TallyStore(context).change { files throws(ToolError) in
            let before = try files.existing(name)
            var after = before
            let sum: DecimalMath.Result
            do throws(ToolError) {
                sum = try DecimalMath.add(before.value, amount)
            } catch {
                throw ToolError("Cannot add \(amount) to \"\(name)\": \(error.message) The tally is unchanged.")
            }
            let (count, overflow) = before.count.addingReportingOverflow(1)
            guard !overflow else {
                throw ToolError("The count of \"\(name)\" cannot grow any further. Set it lower with tally_set. The tally is unchanged.")
            }
            after.value = sum.value
            after.exact = before.exact && sum.exact
            after.count = count
            after.updated = now
            var crossed: [JSONObject] = []
            for threshold in after.thresholds {
                if let crossing = try threshold.crossing(from: before, to: after) {
                    crossed.append(crossing)
                }
            }
            let response = try TallyResponse.state(after, added: amount, reads: reads, crossed: crossed)
            try files.save(after)
            return response
        }
    }
}

// MARK: - tally_set

struct TallySet: Tool {
    let name = "tally_set"

    let description = """
        Correct a tally: set its value and/or count, or replace its thresholds (an empty list removes them). For \
        fixing a miscount or changing a budget; normal counting is tally_add. Reports no crossings; returns the \
        full state. \(TallySchema.numbersSentence) An unknown name is an error.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.existingName,
            "value": TallySchema.number("The new value. A JSON number or a string like \"410k\" or \"1,234.5\"."),
            "count": [
                "type": ["integer", "string"],
                "minimum": 0,
                "description": "The new count of additions, a whole number, 0 or more.",
            ],
            "thresholds": TallySchema.thresholds,
            "decimal": TallySchema.decimal,
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    let annotations = ToolAnnotations(title: "Set tally", readOnly: false, destructive: true, idempotent: true)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        var args = try TallyArguments(arguments, allowed: ["name", "value", "count", "thresholds", "decimal"])
        let name = try args.name()
        try TallyName.validate(name)
        let value = try args.number("value")
        let count = try args.count("count")
        let thresholds = try args.thresholds()
        guard value != nil || count != nil || thresholds != nil else {
            throw ToolError("Nothing to set: pass value, count or thresholds (or several). To add, use tally_add.")
        }
        let now = Tally.timestamp(context.now())
        let reads = args.reads

        return try TallyStore(context).change { files throws(ToolError) in
            var tally = try files.existing(name)
            if let value {
                tally.value = value
                tally.exact = true  // the value is now the one given, whatever was rounded before
            }
            if let count { tally.count = count }
            if let thresholds { tally.thresholds = thresholds }
            tally.updated = now
            let response = try TallyResponse.state(tally, reads: reads)
            try files.save(tally)
            return response
        }
    }
}

// MARK: - tally_list

struct TallyList: Tool {
    let name = "tally_list"

    let description = """
        List tallies sorted by name, each with its full state; with prefix, only names starting with it. Also \
        returns the folder they are kept in. Use it to see what exists or to find a name you lost, such as the \
        suffix of a unique name.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "prefix": [
                "type": "string",
                "description": "Only tallies whose names start with this, e.g. \"items\" for items-k3f9.",
            ],
        ],
        "additionalProperties": false,
    ]

    let annotations = ToolAnnotations(title: "List tallies", readOnly: true, destructive: false, idempotent: true)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        let args = try TallyArguments(arguments, allowed: ["prefix"])
        let prefix = try args.string("prefix") ?? ""
        let store = TallyStore(context)

        return try store.read { files throws(ToolError) in
            var tallies: [JSONValue] = []
            var unreadable: [JSONValue] = []
            for name in try files.names() where name.hasPrefix(prefix) {
                do throws(ToolError) {
                    if let tally = try files.load(name) {
                        tallies.append(.object(try TallyResponse.state(tally)))
                    }
                } catch {
                    unreadable.append(["name": .string(name), "problem": .string(error.message)])
                }
            }
            var response: JSONObject = ["folder": .string(store.folder.url.path), "tallies": .array(tallies)]
            if !unreadable.isEmpty { response["unreadable"] = .array(unreadable) }
            return response
        }
    }
}

// MARK: - tally_drop

struct TallyDrop: Tool {
    let name = "tally_drop"

    let description = """
        Delete a tally you no longer need and get its final state back. An unknown name is an error. Also \
        removes a tally whose file cannot be read.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.existingName,
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    // Dropping a dropped tally changes nothing more (it fails as unknown), hence idempotent.
    let annotations = ToolAnnotations(title: "Drop tally", readOnly: false, destructive: true, idempotent: true)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        let args = try TallyArguments(arguments, allowed: ["name"])
        let name = try args.name()
        try TallyName.validate(name)

        return try TallyStore(context).change { files throws(ToolError) in
            switch try files.inspect(name) {
            case .missing:
                throw TallyErrors.unknown(name, existing: try files.names())
            case .tally(let tally):
                let response = try TallyResponse.state(tally, dropped: true)
                try files.delete(name)
                return response
            case .unreadable(let problem):
                // A file this version cannot read must not block its name forever: delete it, say what was wrong.
                try files.delete(name)
                return ["name": .string(name), "dropped": true, "unreadable": .string(problem)]
            }
        }
    }
}

// MARK: - Schema parts

enum TallySchema {
    static let numbersSentence = """
        Numbers are JSON numbers or strings like "410k" or "1,234.5" (with decimal: "," for a decimal comma).
        """

    static let namePattern = "^[a-z0-9][a-z0-9._-]{0,63}$"

    static let name: JSONValue = [
        "type": "string",
        "pattern": .string(namePattern),
        "description": "Lowercase letters, digits, '.', '_' and '-', starting with a letter or digit, at most 64 characters (59 with unique). E.g. \"review-items\".",
    ]

    static let existingName: JSONValue = [
        "type": "string",
        "pattern": .string(namePattern),
        "description": "The tally's name as tally_create returned it, including any suffix.",
    ]

    static let decimal: JSONValue = [
        "type": "string",
        "enum": [".", ","],
        "default": ".",
        "description": "The decimal mark in number strings. With \",\", \"1.234,5\" is 1234.5.",
    ]

    static func number(_ description: String, default value: JSONValue? = nil) -> JSONValue {
        var schema: JSONObject = ["type": ["number", "string"]]
        if let value { schema["default"] = value }
        schema["description"] = .string(description)
        return .object(schema)
    }

    static let numberOrString: JSONValue = ["type": ["number", "string"]]

    static let thresholds: JSONValue = [
        "type": "array",
        "description": .string(
            "What to watch. Each item has exactly one of limit (a ceiling: every response says whether it is reached and what remains), at (a list of marks) or every (a period: marks at every multiple), and optionally of: \"value\" (default) or \"count\". An addition reports each mark it reaches or passes going up. E.g. \(Threshold.example)."
        ),
        "items": [
            "type": "object",
            "properties": [
                "limit": numberOrString,
                "at": ["type": "array", "items": numberOrString, "minItems": 1],
                "every": numberOrString,
                "of": ["type": "string", "enum": ["value", "count"], "default": "value"],
            ],
            "oneOf": [
                ["required": ["limit"]],
                ["required": ["at"]],
                ["required": ["every"]],
            ],
            "additionalProperties": false,
        ],
    ]
}
