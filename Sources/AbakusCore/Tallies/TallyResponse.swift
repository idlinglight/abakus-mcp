import Foundation

/// How tally tools answer: the tally's full state as an ordered JSON object, plus what the call itself did.
///
///     {"name": "review-k3f9", "value": 7, "count": 5, "added": 2,
///      "crossed": [{"every": 5, "of": "count", "at": [5]}],
///      "thresholds": [{"limit": 20, "of": "value", "reached": false, "remaining": 13},
///                     {"every": 5, "of": "count", "next": 10}],
///      "created": "2026-11-08T09:12:00Z", "updated": "2026-11-08T09:40:31Z"}
enum TallyResponse {
    /// - `dropped`: the tally was just deleted (`tally_drop`).
    /// - `added`, `crossed`: what a `tally_add` added and crossed (`crossed` is present, possibly empty, on adds).
    /// - `reads`: numbers that came as strings, and how they were read.
    ///
    /// Never fails: thresholds only inform (ADR-0004), so one whose status cannot be computed (arithmetic
    /// beyond Decimal's range) carries a `problem` note instead of taking the response down with it.
    static func state(
        _ tally: Tally,
        dropped: Bool = false,
        added: Decimal? = nil,
        reads: [NumberRead] = [],
        crossed: [JSONObject]? = nil
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
}

/// Errors that name a tally, written for the agent that has to recover from them.
enum TallyErrors {
    /// At most this many existing names go into an error's details.
    static let listedNames = 20

    static func unknown(_ name: String, existing names: [String]) -> ToolError {
        // A name created with unique: true carries a suffix, which an agent may have lost (e.g. to compaction).
        let suffixed = names.filter { $0.hasPrefix("\(name)-") }
        var message = "There is no tally named \"\(name)\". It may never have been created (check the spelling), or it may have expired: macOS deletes tallies that have not changed for about three days."
        if !suffixed.isEmpty {
            let candidates = suffixed.prefix(3).map { "\"\($0)\"" }.joined(separator: " or ")
            message += " Names created with unique: true carry a suffix; did you mean \(candidates)?"
        }
        message += names.isEmpty
            ? " No tallies exist right now. Create it with tally_create; nothing is ever created by adding."
            : " details.existing lists the tallies that exist. To start over, create it with tally_create."
        let shown = suffixed + names.filter { !suffixed.contains($0) }
        var details: JSONObject = ["name": .string(name), "existing": .array(shown.prefix(listedNames).map(JSONValue.string))]
        if names.count > listedNames {
            details["existing_total"] = .number(String(names.count))
        }
        return ToolError(message, details: details)
    }

    static func exists(_ tally: Tally) -> ToolError {
        let state = TallyResponse.state(tally)
        return ToolError(
            "A tally named \"\(tally.name)\" already exists (details.existing shows its state); another session may be using it. To count on your own, call tally_create with unique: true, which appends a random suffix. To share this tally on purpose, add to it with tally_add. To start over, tally_drop it first.",
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
