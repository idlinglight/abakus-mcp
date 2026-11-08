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
    static func state(
        _ tally: Tally,
        dropped: Bool = false,
        added: Decimal? = nil,
        reads: [NumberRead] = [],
        crossed: [JSONObject]? = nil
    ) throws(ToolError) -> JSONObject {
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
        var thresholds: [JSONValue] = []
        for threshold in tally.thresholds {
            thresholds.append(.object(try threshold.status(of: tally)))
        }
        object["thresholds"] = .array(thresholds)
        object["created"] = .string(tally.created)
        object["updated"] = .string(tally.updated)
        return object
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
        let state = (try? TallyResponse.state(tally)) ?? ["name": .string(tally.name)]
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
