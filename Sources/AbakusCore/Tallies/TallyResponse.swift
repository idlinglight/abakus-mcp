import Foundation

/// How tally tools answer: the tally's state as an ordered JSON object, plus what the call itself did. Each
/// threshold shows its status; an `at` threshold by how many marks it has, not the marks, so the response stays the
/// same size however many there are (ADR-0004, amendment of 2026-11-10; ADR-0008).
///
///     {"name": "review-k3f9", "value": 7, "count": 5, "added": 2,
///      "crossed": [{"every": 5, "of": "count", "at": [5]}],
///      "thresholds": [{"limit": 20, "of": "value", "reached": false, "remaining": 13},
///                     {"marks": 50, "of": "value", "passed": 2, "next": 10},
///                     {"every": 5, "of": "count", "next": 10}],
///      "created": "2026-11-08T09:12:00Z", "updated": "2026-11-08T09:40:31Z"}
enum TallyResponse {
    /// - `dropped`: the tally was just deleted (`tally_drop`).
    /// - `added`, `crossed`: what a `tally_add` added and crossed (`crossed` is present, possibly empty, on adds).
    /// - `reads`: numbers that came as strings, and how they were read: `read`, a detail of the tools that take
    ///   numbers (the command line prints it, an MCP result leaves it out).
    /// - `note`: tally_create's note on an existing name; `decimalNote`: the decimal note, under `notes` like sum's.
    ///
    /// Never fails: thresholds only inform (ADR-0004), so one whose status cannot be computed (arithmetic
    /// beyond Decimal's range) carries a `problem` note instead of taking the response down with it.
    static func state(
        _ tally: Tally,
        dropped: Bool = false,
        added: Decimal? = nil,
        reads: [NumberRead] = [],
        crossed: [JSONObject]? = nil,
        note: String? = nil,
        decimalNote: String? = nil
    ) -> JSONObject {
        var object: JSONObject = ["name": .string(tally.name)]
        if dropped { object["dropped"] = true }
        object["value"] = .decimal(tally.value)
        if !tally.exact { object["exact"] = false }
        object["count"] = .number(String(tally.count))
        if let added { object["added"] = .decimal(added) }
        if !reads.isEmpty {
            object["read"] = .array(reads.map { ["input": .string($0.input), "value": .decimal($0.value)] })
        }
        if let crossed { object["crossed"] = .array(crossed.map(JSONValue.object)) }
        object["thresholds"] = .array(tally.thresholds.map { .object(status($0, of: tally)) })
        object["created"] = .string(tally.created)
        object["updated"] = .string(tally.updated)
        if let note { object["note"] = .string(note) }
        if let decimalNote { object["notes"] = [.string(decimalNote)] }
        return object
    }

    static func status(_ threshold: Threshold, of tally: Tally) -> JSONObject {
        do throws(ToolError) {
            return try threshold.status(of: tally)
        } catch {
            var object = threshold.spec
            object["problem"] = .string("Its status cannot be computed: \(error.message)")
            return object
        }
    }

    /// What going from `before` to `after` crossed, threshold by threshold. Never fails: a threshold whose
    /// crossing cannot be computed is listed with a `problem` note, and the addition still counts.
    static func crossings(from before: Tally, to after: Tally) -> [JSONObject] {
        var crossed: [JSONObject] = []
        for threshold in after.thresholds {
            do throws(ToolError) {
                if let crossing = try threshold.crossing(from: before, to: after) {
                    crossed.append(crossing)
                }
            } catch {
                var object = threshold.spec
                object["problem"] = .string("Whether this addition crossed one of its marks cannot be computed: \(error.message)")
                crossed.append(object)
            }
        }
        return crossed
    }

    /// The `note` on a tally_create response when a tally with exactly the given name exists, typically one that
    /// tally_create returned earlier and the agent gave again (after compaction, say) to continue it.
    static func recreatedNote(_ requested: String, as name: String) -> String {
        "A tally named \"\(requested)\" already exists, and tally_create always makes a new tally: this one is \"\(name)\". If you meant to continue \"\(requested)\", add to it with tally_add and drop this new one with tally_drop."
    }

    // MARK: The decimal note

    // sum's note (ADR-0008, `OtherDecimalReadings`), with advice that fits each tool: by the time the agent reads
    // it, the call has changed the tally, so only an idempotent tool can simply be called again.

    /// tally_create: the tally exists, its thresholds read one way. Creating again would make a second tally, so
    /// the correction is tally_set with the thresholds and the other mark.
    static func decimalNote(_ readings: OtherDecimalReadings, created name: String) -> String? {
        let (numbers, mark) = readings.decimal == .point
            ? ("a decimal comma", #"with decimal: ",""#)
            : ("a decimal point", "without decimal")
        return readings.note(
            advice: "If the numbers use \(numbers), replace the thresholds with tally_set on \"\(name)\", passing them again \(mark); calling tally_create again would make a second tally."
        )
    }

    /// tally_add: the addition has counted with the reading it got, and adding again would count it twice. The
    /// correction is tally_set with the value the other reading gives, which keeps the count: it was one addition
    /// either way. A negative amount would correct the value but count a second addition, which throws off a
    /// checkpoint every N items.
    static func decimalNote(_ readings: OtherDecimalReadings, addedTo before: Tally) -> String? {
        guard let first = readings.noted else { return nil }
        let correction: String
        if let corrected = try? DecimalMath.add(before.value, first.other), corrected.exact {
            correction = "correct the value with tally_set {\"name\": \"\(before.name)\", \"value\": \(corrected.value)}, which keeps the count"
        } else {
            correction = "set the value with tally_set to the value before this addition plus \(first.other), which keeps the count"
        }
        return readings.note(
            advice: "The addition counted as \(first.value). If you meant \(first.other), \(correction); adding again would count a second time."
        )
    }

    /// tally_set: idempotent, so calling again with the other mark corrects it, as in sum.
    static func decimalNote(_ readings: OtherDecimalReadings) -> String? {
        readings.note(advice: readings.callAgain)
    }
}

/// Errors that name a tally, written for the agent that has to recover from them.
enum TallyErrors {
    /// At most this many existing names go into an error's details.
    static let listedNames = 20
    /// At most this many tallies that may be the asked-for name plus a suffix go into an error's message.
    static let describedMatches = 3

    /// What the caller meant to do with a name that has no tally: the advice in the error depends on it.
    enum UnknownNameUse {
        /// tally_add, tally_set: the agent wants to keep counting, so creating a tally is the way forward.
        case change
        /// tally_drop: nothing to create; a repeated drop ends here too, and a tally that may be another
        /// session's is better left to expire.
        case drop
        /// calc: a reference in an expression. Creating a tally would not give the value the formula needs, so
        /// the error never suggests it; it says that nothing was computed.
        case read

        /// Why the name may have no tally, before the expiry that applies to every use.
        var causes: String {
            switch self {
            case .change: "It may never have been created (check the spelling), or it may have expired"
            case .drop: "It may already have been dropped (a repeated tally_drop ends here), it may never have been created (check the spelling), or it may have expired"
            case .read: "It may never have been created (check the spelling), it may have been dropped, or it may have expired"
            }
        }

        /// The advice when no tally has the name plus a suffix.
        func withoutMatches(noTallies: Bool) -> String {
            switch (self, noTallies) {
            case (.change, true): "No tallies exist right now. Create it with tally_create; nothing is ever created by adding."
            case (.change, false): "details.existing lists the tallies that exist. To start over, create it with tally_create."
            case (.drop, true): "No tallies exist right now, so there is nothing to drop."
            case (.drop, false): "details.existing lists the tallies that exist. Nothing was dropped."
            case (.read, true): "No tallies exist right now. Nothing was computed."
            case (.read, false): "details.existing lists the tallies that exist. Nothing was computed."
            }
        }

        /// What to do with tallies that have the name plus a suffix and may be another session's: the advice after
        /// "It may belong to another session:" (or "They may belong to other sessions:"), with what to do if unsure.
        func withMatches(one: Bool) -> String {
            let compare = "(compare its created time with when you created yours)"
            return switch self {
            case .change: "use \(one ? "it" : "one") only if you know you created it \(compare). If unsure, create a new tally with tally_create."
            case .drop: "drop \(one ? "it" : "one") only if you know you created it \(compare). If unsure, leave \(one ? "it" : "them") to expire."
            case .read:
                one
                    ? "write its full name, suffix included, only if you know it is the one you mean \(compare). Nothing was computed."
                    : "write the full name, suffix included, only for the one you know you mean \(compare). Nothing was computed."
            }
        }
    }

    /// `matching`: the readable tallies among `names` that start with `name` and `-`, at most `listedNames`.
    static func unknown(
        _ name: String, existing names: [String], matching: [Tally], use: UnknownNameUse
    ) -> ToolError {
        // tally_create appends a suffix unless shared: true; an agent may have lost it (e.g. to compaction) or
        // used the name it asked for instead of the one it got. But every tally but a shared one has a suffix,
        // so a tally with the name plus a suffix is as likely another session's as this one's: the error shows
        // when each was created and leaves the choice to an agent that knows, instead of suggesting one.
        let suffixed = names.filter { $0.hasPrefix("\(name)-") }
        var message = "There is no tally named \"\(name)\". \(use.causes): macOS deletes tallies that have not changed for about three days."
        if matching.isEmpty {
            message += " " + use.withoutMatches(noTallies: names.isEmpty)
        } else {
            let described = matching.prefix(describedMatches).map {
                "\"\($0.name)\" (created \($0.created), value \($0.value), count \($0.count))"
            }
            let more = suffixed.count - described.count
            let list = more > 0 ? described.joined(separator: ", ") + " and \(more) more" : described.listedInProse
            let one = suffixed.count == 1
            let advice = use.withMatches(one: one)
            message += " tally_create adds a random suffix to every name unless shared: true is passed, and "
            message += one
                ? "a tally whose name starts with \"\(name)-\" exists: \(list). It may belong to another session: \(advice) details.matching shows it; details.existing lists the tallies that exist."
                : "tallies whose names start with \"\(name)-\" exist: \(list). They may belong to other sessions: \(advice) details.matching shows them; details.existing lists the tallies that exist."
        }
        var details: JSONObject = ["name": .string(name)]
        if !matching.isEmpty {
            details["matching"] = .array(matching.map { tally in
                ["name": .string(tally.name), "value": .decimal(tally.value), "count": .number(String(tally.count)), "created": .string(tally.created)]
            })
        }
        let shown = suffixed + names.filter { !suffixed.contains($0) }
        details["existing"] = .array(shown.prefix(listedNames).map(JSONValue.string))
        if names.count > listedNames {
            details["existing_total"] = .number(String(names.count))
        }
        return ToolError(message, details: details)
    }

    /// Only `shared: true` can run into an existing name; without it, tally_create picks a free suffix.
    static func exists(_ tally: Tally) -> ToolError {
        let state = TallyResponse.state(tally)
        return ToolError(
            "A tally named \"\(tally.name)\" already exists (details.existing shows its state) and may be in use by other sessions. Add to it with tally_add only if you are coordinating with whoever created it. To count your own work, call tally_create without shared: the tally then gets a random suffix and is yours alone.",
            details: ["existing": .object(state)]
        )
    }

    static func unreadable(_ name: String, path: String, problem: String) -> ToolError {
        ToolError(
            "The tally \"\(name)\" cannot be read: \(problem). Its file is \(path). tally_drop deletes it, after which tally_create can start it again.",
            details: ["name": .string(name), "file": .string(path)]
        )
    }
}
