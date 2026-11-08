@testable import AbakusCore
import Darwin
import Foundation
import Testing

@Suite struct StateLockedFolderTests {
    /// A fresh folder below the temporary folder for each test, removed afterwards; never the real state.
    private final class Scratch {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abakus-tests-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func permissions(_ url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    /// A read-modify-write of a counter file from many tasks. Each access opens the lock file itself, so the
    /// tasks contend through separate open file descriptions, as separate processes would.
    @Test func changesUnderTheLockLoseNothing() async throws {
        let scratch = Scratch()
        let folder = LockedFolder(scratch.url)
        try folder.withLock(.exclusive, createFolder: true) { contents throws(ToolError) in
            try contents.write(Data("0".utf8), to: "counter")
        }
        let failures = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var failures: [String] = []
                    for _ in 0..<50 {
                        do throws(ToolError) {
                            try folder.withLock(.exclusive, createFolder: false) { contents throws(ToolError) in
                                let text = try contents.read("counter").map { String(decoding: $0, as: UTF8.self) } ?? ""
                                guard let value = Int(text) else { throw ToolError("counter holds \"\(text)\"") }
                                try contents.write(Data(String(value + 1).utf8), to: "counter")
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
        let final = try folder.withLock(.shared, createFolder: false) { contents throws(ToolError) in
            try contents.read("counter").map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(final == "400")
    }

    @Test func createsPrivateFoldersAndFiles() throws {
        let scratch = Scratch()
        let folder = LockedFolder(scratch.url.appendingPathComponent("a/b", isDirectory: true))
        try folder.withLock(.exclusive, createFolder: true) { contents throws(ToolError) in
            try contents.write(Data("one".utf8), to: "x.json")
            try contents.write(Data("two".utf8), to: "x.json")
        }
        #expect(Self.permissions(scratch.url) == 0o700)
        #expect(Self.permissions(scratch.url.appendingPathComponent("a")) == 0o700)
        #expect(Self.permissions(folder.url) == 0o700)
        #expect(Self.permissions(folder.url.appendingPathComponent("x.json")) == 0o600)
        // Only the file remains: no lock file (the folder itself is locked), no temporary files.
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(entries == ["x.json"])
        let text = try folder.withLock(.shared, createFolder: false) { contents throws(ToolError) in
            try contents.read("x.json").map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(text == "two")
    }

    @Test func leavesAnExistingFoldersModeAlone() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try LockedFolder(scratch.url).withLock(.exclusive, createFolder: true) { contents throws(ToolError) in
            try contents.write(Data("1".utf8), to: "x.json")
        }
        #expect(Self.permissions(scratch.url) == 0o755)
    }

    @Test func aMissingFolderIsNotCreatedWithoutBeingAsked() throws {
        let scratch = Scratch()
        let folder = LockedFolder(scratch.url)
        let seen = try folder.withLock(.exclusive, createFolder: false) { contents throws(ToolError) in
            (contents.exists, try contents.read("x.json"), try contents.fileNames(), contents.contains("x.json"))
        }
        #expect(seen.0 == false)
        #expect(seen.1 == nil)
        #expect(seen.2 == [])
        #expect(seen.3 == false)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path))
    }

    @Test func removeAndListSkipTheFoldersOwnFiles() throws {
        let scratch = Scratch()
        let folder = LockedFolder(scratch.url)
        let (listed, removed, removedAgain, remaining) = try folder.withLock(.exclusive, createFolder: true) {
            contents throws(ToolError) in
            try contents.write(Data("1".utf8), to: "a.json")
            try contents.write(Data("2".utf8), to: "b.json")
            return (try contents.fileNames().sorted(), try contents.remove("a.json"), try contents.remove("a.json"), try contents.fileNames())
        }
        #expect(listed == ["a.json", "b.json"])
        #expect(removed == true)
        #expect(removedAgain == false)
        #expect(remaining == ["b.json"])
    }

    @Test func aFileWhereTheFolderShouldBeIsAnError() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let blocked = scratch.url.appendingPathComponent("tallies")
        try Data().write(to: blocked)
        for createFolder in [true, false] {
            let error = try #require(throws: ToolError.self) {
                try LockedFolder(blocked).withLock(.shared, createFolder: createFolder) { _ throws(ToolError) in }
            }
            #expect(error.message.contains("is not a folder"))
            #expect(error.message.contains("ABAKUS_STATE_DIR"))
        }
        // A file above the folder, as with ABAKUS_STATE_DIR pointing at a file.
        let below = LockedFolder(blocked.appendingPathComponent("tallies", isDirectory: true))
        let error = try #require(throws: ToolError.self) {
            try below.withLock(.shared, createFolder: false) { _ throws(ToolError) in }
        }
        #expect(error.message.contains("is not a folder"))
    }

    /// The folder can vanish (the clean-up removes an old empty one) between two calls; the next call then
    /// sees no folder, just as if it had never existed.
    @Test func aFolderThatVanishedCountsAsMissing() throws {
        let scratch = Scratch()
        let folder = LockedFolder(scratch.url)
        try folder.withLock(.exclusive, createFolder: true) { _ throws(ToolError) in }
        try FileManager.default.removeItem(at: scratch.url)
        let exists = try folder.withLock(.exclusive, createFolder: false) { contents throws(ToolError) in contents.exists }
        #expect(exists == false)
    }

    @Test func readingADirectoryWhereAFileShouldBeIsAnError() throws {
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.url.appendingPathComponent("x.json"), withIntermediateDirectories: true)
        let error = try #require(throws: ToolError.self) {
            try LockedFolder(scratch.url).withLock(.shared, createFolder: false) { contents throws(ToolError) in
                _ = try contents.read("x.json")
            }
        }
        #expect(error.message.contains("Cannot read"))
    }
}
