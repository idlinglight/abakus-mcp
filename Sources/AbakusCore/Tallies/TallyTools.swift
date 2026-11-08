import Foundation

/// Tally tools (ADR-0004): tally_create, tally_add, tally_set, tally_list, tally_drop.
public enum TallyTools {
    public static let all: [any Tool] = [TallyCreate(), TallyAdd(), TallySet(), TallyList(), TallyDrop()]
}

// MARK: - tally_create

struct TallyCreate: Tool {
    let name = "tally_create"

    let description = """
        Create a tally: an exact value plus a count of additions, kept outside your context so it survives long \
        work and compaction. For counting work against a budget, a checkpoint every N items, or summing numbers \
        that arrive one at a time. Every tally gets a random suffix (items becomes items-k3f9), so each session \
        counts its own; use the name in the response from then on. Pass shared: true only for a tally several \
        sessions are meant to add to: the name is then used exactly, and creating fails if it exists. Leave other \
        sessions' tallies alone unless you coordinate with them. Optional thresholds watch the value (default) or \
        the count: limit (a ceiling), at (marks), every (a period); they inform and never block. Returns the new \
        tally's state. \(NumberReader.rulesInBrief)
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.name,
            "shared": [
                "type": "boolean",
                "default": false,
                "description": "Use the name exactly, without a suffix, for a tally several sessions are meant to add to. Refused if the name exists. Leave it out to count your own work.",
            ],
            "thresholds": TallySchema.thresholds,
            "decimal": DecimalMark.schema,
        ],
        "required": ["name"],
        "additionalProperties": false,
    ]

    let annotations = ToolAnnotations(title: "Create tally", readOnly: false, destructive: false, idempotent: false)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        var args = try TallyArguments(
            arguments, allowed: ["name", "shared", "thresholds", "decimal"],
            // `unique: true` was the opt-in for the suffix in 0.1.0; agents may still have it in their prompts.
            hints: ["unique": "Leave unique out: tally_create always appends a random suffix now, unless shared: true is passed."]
        )
        let requested = try args.name()
        let shared = try args.bool("shared") ?? false
        try TallyName.validate(requested, suffixed: !shared)
        let thresholds = try args.thresholds() ?? []
        let now = Tally.timestamp(context.now())
        let reads = args.reads

        return try TallyStore(context).change(creatingFolder: true) { files throws(ToolError) in
            let name: String
            if shared {
                if let existing = try files.load(requested) { throw TallyErrors.exists(existing) }
                name = requested
            } else {
                name = try TallyName.suffixed(requested) { candidate throws(ToolError) in files.contains(candidate) }
            }
            let tally = Tally(name: name, thresholds: thresholds, created: now, updated: now)
            try files.save(tally)
            return TallyResponse.state(tally, reads: reads)
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
        \(NumberReader.rulesInBrief) A string's reading is shown under read. An unknown name is an error, never a \
        new tally: the name may be misspelled, lack the suffix tally_create gave it, or have expired (unchanged \
        for about three days); tally_list shows what exists.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "name": TallySchema.existingName,
            "amount": TallySchema.number(
                "What to add, default 1. Negative subtracts. A JSON number or a string like \"410k\" or \"1,234.5\".",
                default: 1
            ),
            "decimal": DecimalMark.schema,
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

        // Every error below is raised before the file is replaced, so a failed add never changed the tally.
        // Thresholds cannot make it fail: one that cannot be evaluated gets a `problem` note, and the addition
        // counts (thresholds inform, they never block).
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
            try files.save(after)
            return TallyResponse.state(
                after, added: amount, reads: reads, crossed: TallyResponse.crossings(from: before, to: after)
            )
        }
    }
}

// MARK: - tally_set

struct TallySet: Tool {
    let name = "tally_set"

    let description = """
        Correct a tally: set its value and/or count, or replace its thresholds (an empty list removes them). For \
        fixing a miscount or changing a budget; normal counting is tally_add. Reports no crossings; returns the \
        full state. \(NumberReader.rulesInBrief) An unknown name is an error.
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
            "decimal": DecimalMark.schema,
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
            try files.save(tally)
            return TallyResponse.state(tally, reads: reads)
        }
    }
}

// MARK: - tally_list

struct TallyList: Tool {
    let name = "tally_list"

    let description = """
        List tallies sorted by name, each with its full state; with prefix, only names starting with it. Also \
        returns the folder they are kept in. Use it to see what exists or to find a name you lost, such as the \
        suffix tally_create gave it.
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
                // Only loading decides "unreadable". A readable tally is always listed with its state; a
                // threshold whose status cannot be computed carries its own `problem` note.
                let loaded: TallyStore.Files.Loaded
                do throws(ToolError) {
                    loaded = try files.inspect(name)
                } catch {
                    unreadable.append(["name": .string(name), "problem": .string(error.message)])
                    continue
                }
                switch loaded {
                case .tally(let tally):
                    tallies.append(.object(TallyResponse.state(tally)))
                case .unreadable(let problem):
                    unreadable.append(["name": .string(name), "problem": .string(problem)])
                case .missing:
                    break
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
                try files.delete(name)
                return TallyResponse.state(tally, dropped: true)
            case .unreadable(let problem):
                // A file this version cannot read must not block its name forever: delete it, say what was wrong.
                try files.delete(name)
                return ["name": .string(name), "dropped": true, "unreadable": .string(problem)]
            }
        }
    }
}

// MARK: - Schema parts

/// Schema parts of the tally tools. Number strings and `decimal` use `NumberReader.rulesInBrief` and
/// `DecimalMark.schema`, so every tool describes and reads them the same way.
enum TallySchema {
    static let namePattern = "^[a-z0-9][a-z0-9._-]{0,63}$"

    static let name: JSONValue = [
        "type": "string",
        "pattern": .string(namePattern),
        "description": "Lowercase letters, digits, '.', '_' and '-', starting with a letter or digit, at most 59 characters, since a suffix like -k3f9 is appended (64 with shared: true). E.g. \"review-items\".",
    ]

    static let existingName: JSONValue = [
        "type": "string",
        "pattern": .string(namePattern),
        "description": "The tally's name as tally_create returned it, including any suffix.",
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
