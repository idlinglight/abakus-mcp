import Foundation

/// Tally tools (ADR-0004): tally_create, tally_add, tally_set, tallies_info, tally_drop.
public enum TallyTools {
    public static let all: [any Tool] = [TallyCreate(), TallyAdd(), TallySet(), TalliesInfo(), TallyDrop()]

    /// How many thresholds tally_create and tally_set take, for the command line's help.
    public static let maximumThresholds = Threshold.maximumPerTally
}

// MARK: - tally_create

struct TallyCreate: TallyStateTool {
    let name = "tally_create"

    let detailKeys = TallySchema.detailKeys

    let description = """
        Create a tally: an exact value plus a count of additions, kept outside your context so it survives long \
        work and compaction. For counting work against a budget, a checkpoint every N items, or summing numbers \
        that arrive one at a time. Every tally gets a random suffix (items becomes items-k3f9), so each session \
        counts its own; use the name in the response from then on, and tally_add to continue it: tally_create \
        always makes a new tally (with a note when the name given exists). Pass shared: true only for a tally \
        several sessions are meant to add to: the name is then used exactly, and creating fails if it exists. \
        Leave other sessions' tallies alone unless you coordinate with them. Optional thresholds, at most \
        \(Threshold.maximumPerTally), watch the value (default) or the count: limit (a ceiling), at (marks, any \
        number of them), every (a period); they inform and never block. Returns the new tally's state, each \
        threshold with its status; an at threshold shows marks_total, passed (how many are reached) and ahead \
        (the next marks, up to \(Threshold.marksAhead)). \(NumberReader.rulesInBrief) \(TallySchema.readingsInBrief)
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

    /// `unique` was the opt-in for the suffix in 0.1.0; agents may still have it in their prompts. What to do
    /// instead depends on what it asked for.
    static let uniqueHint: UnknownArguments.Hint = { value in
        switch value.boolValue {
        case true?: "Leave unique out: tally_create appends a random suffix by default now."
        case false?: "To use the name exactly, without a suffix, pass shared: true instead; the name must not exist yet."
        case nil: nil
        }
    }

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        var args = try TallyArguments(arguments, for: self, hints: ["unique": Self.uniqueHint])
        let requested = try args.name()
        let shared = try args.bool("shared") ?? false
        try TallyName.validate(requested, suffixed: !shared)
        let thresholds = try args.thresholds() ?? []
        let now = Tally.timestamp(context.now())
        let reads = args.reads
        let readings = args.otherReadings

        return try TallyStore(context).change(creatingFolder: true) { files throws(ToolError) in
            let name: String
            var note: String?
            if shared {
                if let existing = try files.load(requested) { throw TallyErrors.exists(existing) }
                name = requested
            } else {
                name = try TallyName.suffixed(requested) { candidate throws(ToolError) in files.contains(candidate) }
                // Typically a name tally_create returned earlier, given again after compaction. Creating never
                // blocks on a name that may be someone else's (ADR-0004); the note says how to continue instead.
                if files.contains(requested) { note = TallyResponse.recreatedNote(requested, as: name) }
            }
            let tally = Tally(name: name, thresholds: thresholds, created: now, updated: now)
            try files.save(tally)
            return TallyResponse.state(
                tally, reads: reads, note: note, decimalNote: TallyResponse.decimalNote(readings, created: name)
            )
        }
    }
}

// MARK: - tally_add

struct TallyAdd: TallyStateTool {
    let name = "tally_add"

    let detailKeys = TallySchema.detailKeys

    let description = """
        Add an amount to a tally (default 1, so a plain call counts one item) and get its state back: value, \
        count, added, crossed and thresholds. crossed lists what this addition reached or passed going up: a \
        limit reached from below (again after the tally went back below it), marks of at and every (up to \
        \(Threshold.listedMarks) per threshold; beyond that, how \
        many as times, with the first and the last); [] if nothing. thresholds gives each one's status: a limit \
        says reached plus remaining or over; an at threshold says marks_total, passed (how many are reached) and \
        ahead (the next marks, up to \(Threshold.marksAhead)); every says next. Thresholds never block. Negative amounts subtract. \
        \(NumberReader.rulesInBrief) \(TallySchema.readingsInBrief) An unknown name is an error, never a new \
        tally: the name may be misspelled, lack the suffix tally_create gave it, or have expired (unchanged for \
        about three days). If tallies whose names start with the name you gave exist, the error shows them with \
        when each was created.
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
        var args = try TallyArguments(arguments, for: self)
        let name = try args.name()
        try TallyName.validate(name)
        let amount = try args.number("amount") ?? 1
        let now = Tally.timestamp(context.now())
        let reads = args.reads
        let readings = args.otherReadings

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
                after, added: amount, reads: reads, crossed: TallyResponse.crossings(from: before, to: after),
                decimalNote: TallyResponse.decimalNote(readings, addedTo: before)
            )
        }
    }
}

// MARK: - tally_set

struct TallySet: TallyStateTool {
    let name = "tally_set"

    let detailKeys = TallySchema.detailKeys

    let description = """
        Correct a tally: set its value and/or count, or replace its thresholds (at most \
        \(Threshold.maximumPerTally); an empty list removes them). For fixing a miscount or changing a budget; \
        normal counting is tally_add. Reports no crossings; returns the state, each threshold with its status (an \
        at threshold shows marks_total, passed and ahead, the next marks). \(NumberReader.rulesInBrief) \
        \(TallySchema.readingsInBrief) An unknown name is an error, never a new tally. If tallies whose names \
        start with the name you gave exist, the error shows them with when each was created.
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
        var args = try TallyArguments(arguments, for: self)
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
        let readings = args.otherReadings

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
            // Idempotent, so calling again with the other mark corrects it, as in sum.
            return TallyResponse.state(tally, reads: reads, decimalNote: readings.note(advice: readings.callAgain))
        }
    }
}

// MARK: - tallies_info

/// Over MCP, the folder and how many tallies there are; the command line also prints every tally with its state.
/// The lists grow with the number of tallies, other sessions' included, so they are details (ADR-0008). The files
/// are no interface for agents: the description does not document them (ADR-0003, ADR-0004).
struct TalliesInfo: Tool {
    let name = "tallies_info"

    let detailKeys = ["tallies", "unreadable"]

    let description = """
        Count tallies and get the folder they are kept in: returns folder and tallies_found, the number of \
        tallies, plus unreadable_found, the number of tallies whose file cannot be read, when there are any. With \
        prefix, both count only tallies whose names start with it. It lists no names or states, so the result \
        stays small however many tallies other sessions keep. To look up a name you lost, such as items-k3f9 when \
        you remember items, call calc with {items}: calc never writes, and its error for an unknown name shows the \
        tallies named items plus a suffix (up to 20), with when each was created. If a tally is named exactly \
        items, calc returns its value instead, and it may be another session's. calc also reads one tally's value \
        or count: {name} or {name:count}. The abakus command line (abakus tallies info, the same program as this \
        server) prints the same JSON plus every tally with its full state (tallies) and each unreadable one with \
        what is wrong (unreadable). Tallies change only through the tally tools, which hold the lock on the \
        folder, never by changing files in it.
        """

    let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "prefix": [
                "type": "string",
                "description": "Count only tallies whose names start with this, e.g. \"items\" for items-k3f9.",
            ],
        ],
        "additionalProperties": false,
    ]

    // Over MCP it counts; the command line, which lists, has its own help text.
    let annotations = ToolAnnotations(title: "Count tallies", readOnly: true, destructive: false, idempotent: true)

    func call(_ arguments: JSONObject, in context: ToolContext) throws(ToolError) -> JSONObject {
        let args = try TallyArguments(arguments, for: self)
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
            // The counts first, then the lists: without the details, what remains is the start of the full result.
            var response: JSONObject = [
                "folder": .string(store.folder.url.path), "tallies_found": .number(String(tallies.count)),
            ]
            if !unreadable.isEmpty { response["unreadable_found"] = .number(String(unreadable.count)) }
            response["tallies"] = .array(tallies)
            if !unreadable.isEmpty { response["unreadable"] = .array(unreadable) }
            return response
        }
    }
}

// MARK: - tally_drop

struct TallyDrop: TallyStateTool {
    let name = "tally_drop"

    let description = """
        Delete a tally you no longer need and get its final state back; the abakus command line (the same program \
        as this server) also prints all the marks of an at threshold (marks). An unknown name is an error. Also \
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
        let args = try TallyArguments(arguments, for: self)
        let name = try args.name()
        try TallyName.validate(name)

        return try TallyStore(context).change { files throws(ToolError) in
            switch try files.inspect(name) {
            case .missing:
                throw try files.unknown(name, use: .drop)
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
    /// The detail keys of the tools that take numbers (ADR-0008): how each string was read grows with the input,
    /// so the command line prints it and an MCP result leaves it out.
    static let detailKeys = ["read"]

    /// What the tools that take numbers say about readings, in their descriptions.
    static let readingsInBrief = """
        A number string that also reads with the other decimal mark, as a different number ("1,234" is 1234 with \
        ".", 1.234 with ","), gets a short note under notes on how to correct it. The abakus command line (the \
        same program as this server) also prints read, how each string was read, and all the marks of an at \
        threshold (marks).
        """

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
            "What to watch, at most \(Threshold.maximumPerTally) thresholds. Each item has exactly one of limit (a ceiling: every response says whether it is reached and what remains), at (a list of marks, any number of them: every response gives marks_total, passed, how many are reached, and ahead, the next \(Threshold.marksAhead) at most) or every (a period: marks at every multiple), and optionally of: \"value\" (default) or \"count\". An addition reports each mark it reaches or passes going up, up to \(Threshold.listedMarks) per threshold; beyond that, how many as times, with the first and the last. E.g. \(Threshold.example)."
        ),
        "maxItems": .number(String(Threshold.maximumPerTally)),
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
