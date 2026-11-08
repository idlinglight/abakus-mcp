@testable import AbakusCore
import Foundation
import Testing

@Suite struct TallyConcurrencyTests {
    /// 8 tasks × 50 calls. Each call opens the lock file itself, so the calls contend through separate open file
    /// descriptions, as calls from separate MCP server processes would.
    @Test func concurrentAddsLoseNothing() async throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
        let context = state.context
        let failures = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var failures: [String] = []
                    for _ in 0..<50 {
                        do throws(ToolError) {
                            _ = try TallyAdd().call(["name": "items"], in: context)
                        } catch {
                            failures.append(error.message)
                        }
                    }
                    return failures
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.first ?? "")")
        let tally = try #require(try state.call("tally_list")["tallies"]?.arrayValue?.first?.objectValue)
        #expect(tally["count"] == 400)
        #expect(tally["value"] == 400)
    }

    @Test func listsNeverSeeHalfWrittenFiles() async throws {
        let state = TallyTestState()
        try state.call("tally_create", ["name": "items", "shared": true])
        let context = state.context
        let failures = await withTaskGroup(of: [String].self) { group in
            for task in 0..<8 {
                group.addTask {
                    var failures: [String] = []
                    for _ in 0..<30 {
                        do throws(ToolError) {
                            if task.isMultiple(of: 2) {
                                _ = try TallyAdd().call(["name": "items", "amount": .number("0.5")], in: context)
                            } else {
                                let listed = try TallyList().call([:], in: context)
                                if listed["unreadable"] != nil || listed["tallies"]?.arrayValue?.count != 1 {
                                    failures.append("unexpected list: \(listed)")
                                }
                            }
                        } catch {
                            failures.append(error.message)
                        }
                    }
                    return failures
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.first ?? "")")
        #expect(try state.call("tally_list")["tallies"]?.arrayValue?.first?.objectValue?["value"] == 60)
    }
}
