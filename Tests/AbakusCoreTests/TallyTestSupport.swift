@testable import AbakusCore
import Darwin
import Foundation
import Synchronization

/// A fresh state folder for one test, removed when the test ends. Never the real state (CLAUDE.md): the folder
/// does not exist until a tool creates it, so tests can also check what gets created.
final class TallyTestState {
    let url: URL
    let clock = TallyTestClock()

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abakus-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var context: ToolContext {
        let clock = clock
        return ToolContext(stateDirectory: url, now: { clock.now })
    }

    var tallies: URL { url.appendingPathComponent("tallies", isDirectory: true) }

    func file(_ name: String) -> URL { tallies.appendingPathComponent("\(name).json") }

    @discardableResult
    func call(_ tool: String, _ arguments: JSONObject = [:]) throws(ToolError) -> JSONObject {
        guard let found = TallyTools.all.first(where: { $0.name == tool }) else {
            throw ToolError("test: no tool \(tool)")
        }
        return try found.call(arguments, in: context)
    }

    /// The error a call fails with, or nil if it succeeds.
    func failure(_ tool: String, _ arguments: JSONObject = [:]) -> ToolError? {
        do {
            try call(tool, arguments)
            return nil
        } catch {
            return error
        }
    }

    /// Writes a file into the tallies folder as is, e.g. to plant a damaged one.
    func plant(_ fileName: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: tallies, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: tallies.appendingPathComponent(fileName))
    }
}

/// A clock tests can move. Starts at 2026-11-08T09:30:00Z.
final class TallyTestClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_794_130_200)
    private let current = Mutex(TallyTestClock.start)

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

/// Small helpers, in a namespace so they cannot clash with other test files.
enum TallyTest {
    /// The permission bits of a file or folder, e.g. 0o700.
    static func permissions(_ url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    static func decimal(_ text: String) -> Decimal {
        try! NumberReader.read(.number(text))  // exact, unlike Decimal(string:), which truncates past 38 digits
    }

    /// The `name` of each object in the array under `key`.
    static func names(_ object: JSONObject, in key: String) -> [String] {
        (object[key]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
    }

    static func tally(_ name: String, value: String = "0", count: Int = 0, exact: Bool = true, thresholds: [Threshold] = []) -> Tally {
        let now = Tally.timestamp(TallyTestClock.start)
        return Tally(name: name, value: decimal(value), count: count, exact: exact, thresholds: thresholds, created: now, updated: now)
    }
}
