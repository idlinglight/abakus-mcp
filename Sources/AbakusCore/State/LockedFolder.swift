import Darwin
import Foundation

/// A folder of small files that several processes read and change (ADR-0003).
///
/// - Every access holds a `flock` on the folder itself, through a read-only descriptor of the directory:
///   exclusive to change files, shared to read them. There is no lock file, which the system's three-day
///   clean-up could delete while it is in use. Each access opens the folder anew, so accesses from threads
///   of one process exclude each other just as accesses from different processes do (`flock` belongs to the
///   open file description).
/// - Writes go to a temporary file in the same folder, which is then renamed over the target: a reader sees the
///   old file or the new one, never half of one.
/// - Folders are created with mode 0700 and files with 0600: state is private to the user.
///
/// Names starting with `.` belong to the folder itself (temporary files) and are never listed.
struct LockedFolder: Sendable {
    enum LockMode: Sendable {
        case shared
        case exclusive
    }

    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// Runs `body` while holding the folder's lock.
    ///
    /// With `createFolder: false` a missing folder is not created: `body` then sees an empty folder, without a
    /// lock (there is nothing to protect), and must not write. That keeps reads, and changes that need an
    /// existing file, from leaving folders behind. "Missing" includes a folder that disappears while the lock
    /// is being taken.
    func withLock<T>(
        _ mode: LockMode,
        createFolder: Bool,
        _ body: (Contents) throws(ToolError) -> T
    ) throws(ToolError) -> T {
        for _ in 0..<8 {
            if createFolder {
                try Self.makeFolder(url)
            }
            switch try acquireLock(mode) {
            case .locked(let descriptor):
                defer { close(descriptor) }  // closing the descriptor releases the lock
                return try body(Contents(url: url, exists: true, writable: mode == .exclusive))
            case .missing:
                if !createFolder {
                    return try body(Contents(url: url, exists: false, writable: false))
                }
                // Created a moment ago and gone again: create it once more.
            case .replaced:
                continue
            }
        }
        throw ToolError("Cannot lock the folder \(url.path): it keeps disappearing or being replaced. Try again.")
    }

    /// The folder's files, as seen while the lock is held. Only valid inside `withLock`.
    struct Contents {
        let url: URL
        /// False when the folder does not exist (and `withLock` was told not to create it).
        let exists: Bool
        /// True under an exclusive lock.
        let writable: Bool

        /// The file's bytes, or nil if there is no such file. Reading by path is safe: under the lock, nobody
        /// renames a new file into place.
        func read(_ fileName: String) throws(ToolError) -> Data? {
            guard exists else { return nil }
            let file = url.appendingPathComponent(fileName)
            do {
                return try Data(contentsOf: file)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            } catch {
                throw ToolError(
                    "Cannot read \(file.path): \(error.localizedDescription) If the folder is not readable, set \(StateDirectory.environmentVariable) to a folder abakus may use."
                )
            }
        }

        func contains(_ fileName: String) -> Bool {
            guard exists else { return false }
            var info = stat()
            return lstat(url.appendingPathComponent(fileName).path, &info) == 0
        }

        /// Replaces the file (or creates it, mode 0600) by writing a temporary file next to it and renaming it.
        func write(_ data: Data, to fileName: String) throws(ToolError) {
            precondition(writable, "LockedFolder: writing needs an exclusive lock on an existing folder")
            let target = url.appendingPathComponent(fileName).path
            let temporary = url.appendingPathComponent(".\(fileName).\(LockedFolder.randomTag()).tmp").path
            let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LockedFolder.failure("write", temporary, code: errno) }
            let problem = LockedFolder.writeAll(data, to: descriptor, path: temporary)
            close(descriptor)
            if let problem {
                unlink(temporary)
                throw problem
            }
            guard rename(temporary, target) == 0 else {
                let problem = LockedFolder.failure("replace", target, code: errno)
                unlink(temporary)
                throw problem
            }
        }

        /// Deletes the file; false if there was none.
        @discardableResult
        func remove(_ fileName: String) throws(ToolError) -> Bool {
            precondition(writable, "LockedFolder: deleting needs an exclusive lock on an existing folder")
            let path = url.appendingPathComponent(fileName).path
            guard unlink(path) != 0 else { return true }
            let code = errno
            if code == ENOENT { return false }
            throw LockedFolder.failure("delete", path, code: code)
        }

        /// Names of the files in the folder, unsorted, without the folder's own (those starting with `.`).
        func fileNames() throws(ToolError) -> [String] {
            guard exists else { return [] }
            do {
                return try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }
            } catch {
                throw ToolError("Cannot list the folder \(url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Locking

    private enum Lock {
        case locked(Int32)
        /// The folder does not exist (any more).
        case missing
        /// The folder at the path is no longer the one that was locked.
        case replaced
    }

    private func acquireLock(_ mode: LockMode) throws(ToolError) -> Lock {
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return .missing
            case ENOTDIR: throw Self.notAFolder(path)
            default: throw Self.failure("open the folder", path, code: code)
            }
        }
        var result: Int32
        var code: Int32 = 0
        repeat {
            result = flock(descriptor, mode == .exclusive ? LOCK_EX : LOCK_SH)
            if result != 0 { code = errno }
        } while result != 0 && code == EINTR
        guard result == 0 else {
            close(descriptor)
            throw Self.failure("lock the folder", path, code: code)
        }
        // A folder that was empty and untouched for three days may be removed by the system's clean-up (and
        // then created again by someone else) while we waited. A lock on a removed folder excludes nobody, so
        // check that the folder at the path is still the one we hold.
        var locked = stat(), current = stat()
        guard fstat(descriptor, &locked) == 0, stat(path, &current) == 0 else {
            close(descriptor)
            return .missing
        }
        guard locked.st_dev == current.st_dev, locked.st_ino == current.st_ino else {
            close(descriptor)
            return .replaced
        }
        return .locked(descriptor)
    }

    // MARK: - Helpers

    /// Creates the folder and any missing parents, each with mode 0700. An existing folder is left as it is.
    static func makeFolder(_ url: URL) throws(ToolError) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw notAFolder(url.path) }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path {
            try makeFolder(parent)
        }
        guard mkdir(url.path, 0o700) == 0 else {
            let code = errno  // before anything else can change it
            if code == EEXIST, isFolder(url) { return }  // created by someone else meanwhile
            throw failure("create the folder", url.path, code: code)
        }
        chmod(url.path, 0o700)  // in case the umask took bits away
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Writes all bytes, sets mode 0600 whatever the umask did, and flushes, so the rename that follows never
    /// puts an incomplete file in place.
    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) -> ToolError? {
        guard fchmod(descriptor, 0o600) == 0 else { return failure("write", path, code: errno) }
        let problem: ToolError? = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if written < 0, code == EINTR { continue }
                return failure("write", path, code: written == 0 ? EIO : code)
            }
            return nil
        }
        if let problem { return problem }
        guard fsync(descriptor) == 0 else { return failure("write", path, code: errno) }
        return nil
    }

    /// An error for a failed system call. `code` is the `errno` the caller saved right after the call, since
    /// almost anything in between (Foundation included) may change it.
    static func failure(_ action: String, _ path: String, code: Int32) -> ToolError {
        ToolError(
            "Cannot \(action) \(path): \(String(cString: strerror(code))). If the folder is not writable, set \(StateDirectory.environmentVariable) to a folder abakus may write."
        )
    }

    private static func notAFolder(_ path: String) -> ToolError {
        ToolError(
            "\(path) is not a folder (it, or a folder above it, is a file), so abakus cannot keep state there. Move the file away, or set \(StateDirectory.environmentVariable) to a folder abakus may write."
        )
    }

    private static func randomTag() -> String {
        String(UInt64.random(in: .min ... .max), radix: 36)
    }
}
