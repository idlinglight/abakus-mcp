import Foundation

/// Where tallies are kept (ADR-0003): `<state folder>/tallies/<name>.json`, one file per tally, in a
/// `LockedFolder`. Changes run under the exclusive lock, reads under the shared one.
struct TallyStore: Sendable {
    static let folderName = "tallies"

    let folder: LockedFolder

    init(stateDirectory: URL) {
        folder = LockedFolder(stateDirectory.appendingPathComponent(Self.folderName, isDirectory: true))
    }

    init(_ context: ToolContext) {
        self.init(stateDirectory: context.stateDirectory)
    }

    func read<T>(_ body: (Files) throws(ToolError) -> T) throws(ToolError) -> T {
        try folder.withLock(.shared, createFolder: false) { contents throws(ToolError) in
            try body(Files(contents: contents))
        }
    }

    /// A read-modify-write under the exclusive lock. Only `tally_create` creates the folder; every other change
    /// needs an existing tally, and a missing folder simply has none.
    func change<T>(creatingFolder: Bool = false, _ body: (Files) throws(ToolError) -> T) throws(ToolError) -> T {
        try folder.withLock(.exclusive, createFolder: creatingFolder) { contents throws(ToolError) in
            try body(Files(contents: contents))
        }
    }

    /// The tallies as seen under the lock.
    struct Files {
        let contents: LockedFolder.Contents

        enum Loaded {
            case missing
            case tally(Tally)
            /// The file exists but is not a tally this version can read; `problem` says why.
            case unreadable(problem: String)
        }

        /// What the file for `name` holds. Throws only when the file cannot be accessed at all.
        func inspect(_ name: String) throws(ToolError) -> Loaded {
            guard let data = try contents.read(Self.fileName(name)) else { return .missing }
            do throws(ToolError) {
                return .tally(try Tally(fileData: data, name: name))
            } catch {
                return .unreadable(problem: error.message)
            }
        }

        /// The tally, or nil if there is none by that name. A file that cannot be read is an error.
        func load(_ name: String) throws(ToolError) -> Tally? {
            switch try inspect(name) {
            case .missing: return nil
            case .tally(let tally): return tally
            case .unreadable(let problem): throw TallyErrors.unreadable(name, path: path(name), problem: problem)
            }
        }

        /// The tally; an unknown name is an error that lists the tallies there are.
        func existing(_ name: String) throws(ToolError) -> Tally {
            guard let tally = try load(name) else {
                throw TallyErrors.unknown(name, existing: try names())
            }
            return tally
        }

        func contains(_ name: String) -> Bool {
            contents.contains(Self.fileName(name))
        }

        func save(_ tally: Tally) throws(ToolError) {
            try contents.write(try tally.fileData(), to: Self.fileName(tally.name))
        }

        func delete(_ name: String) throws(ToolError) {
            try contents.remove(Self.fileName(name))
        }

        /// The names of all tallies, sorted. Files that are not named like a tally are ignored.
        func names() throws(ToolError) -> [String] {
            try contents.fileNames()
                .filter { $0.hasSuffix(".json") }
                .map { String($0.dropLast(".json".count)) }
                .filter(TallyName.isValid)
                .sorted()
        }

        func path(_ name: String) -> String {
            contents.url.appendingPathComponent(Self.fileName(name)).path
        }

        static func fileName(_ name: String) -> String {
            "\(name).json"
        }
    }
}
