import Darwin
import Foundation

/// A folder of small files that several processes read and change (ADR-0003).
///
/// - Every access holds a `flock` on the lock file `.lock` in the folder: exclusive to change files, shared to
///   read them. Each access opens the lock file anew, so accesses from threads of one process exclude each
///   other just as accesses from different processes do (`flock` belongs to the open file description).
/// - Writes go to a temporary file in the same folder, which is then renamed over the target: a reader sees the
///   old file or the new one, never half of one.
/// - Folders are created with mode 0700 and files with 0600: state is private to the user.
///
/// Names starting with `.` belong to the folder itself (the lock file, temporary files) and are never listed.
struct LockedFolder: Sendable {
    enum LockMode: Sendable {
        case shared
        case exclusive
    }

    static let lockFileName = ".lock"

    let url: URL

    init(_ url: URL) {
        self.url = url
    }

    /// Runs `body` while holding the folder's lock.
    ///
    /// With `createFolder: false` a missing folder is not created: `body` then sees an empty folder, without a
    /// lock (there is nothing to protect), and must not write. That keeps reads, and changes that need an
    /// existing file, from leaving folders behind.
    func withLock<T>(
        _ mode: LockMode,
        createFolder: Bool,
        _ body: (Contents) throws(ToolError) -> T
    ) throws(ToolError) -> T {
        if createFolder {
            try Self.makeFolder(url)
        } else if !Self.isFolder(url) {
            return try body(Contents(url: url, exists: false, writable: false))
        }
        let lock = try acquireLock(mode)
        defer { close(lock) }  // closing the descriptor releases the lock
        return try body(Contents(url: url, exists: true, writable: mode == .exclusive))
    }

    /// The folder's files, as seen while the lock is held. Only valid inside `withLock`.
    struct Contents {
        let url: URL
        /// False when the folder does not exist (and `withLock` was told not to create it).
        let exists: Bool
        /// True under an exclusive lock.
        let writable: Bool

        /// The file's bytes, or nil if there is no such file.
        func read(_ fileName: String) throws(ToolError) -> Data? {
            guard exists else { return nil }
            let path = url.appendingPathComponent(fileName).path
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                throw LockedFolder.failure("read", path)
            }
            defer { close(descriptor) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    data.append(contentsOf: buffer[0..<count])
                } else if count == 0 {
                    return data
                } else if errno != EINTR {
                    throw LockedFolder.failure("read", path)
                }
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
            guard descriptor >= 0 else { throw LockedFolder.failure("write", temporary) }
            let problem = LockedFolder.writeAll(data, to: descriptor, path: temporary)
            close(descriptor)
            if let problem {
                unlink(temporary)
                throw problem
            }
            guard rename(temporary, target) == 0 else {
                let problem = LockedFolder.failure("replace", target)
                unlink(temporary)
                throw problem
            }
        }

        /// Deletes the file; false if there was none.
        @discardableResult
        func remove(_ fileName: String) throws(ToolError) -> Bool {
            precondition(writable, "LockedFolder: deleting needs an exclusive lock on an existing folder")
            let path = url.appendingPathComponent(fileName).path
            if unlink(path) == 0 { return true }
            if errno == ENOENT { return false }
            throw LockedFolder.failure("delete", path)
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

    private func acquireLock(_ mode: LockMode) throws(ToolError) -> Int32 {
        let path = url.appendingPathComponent(Self.lockFileName).path
        // The lock file is never written, so after three days the system's clean-up may delete it, possibly
        // while another process holds it. A lock on a deleted file excludes nobody: after locking, check that
        // the file is still the one at the path, and start over if it is not.
        for _ in 0..<8 {
            let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Self.failure("open the lock file", path) }
            var result: Int32
            repeat {
                result = flock(descriptor, mode == .exclusive ? LOCK_EX : LOCK_SH)
            } while result != 0 && errno == EINTR
            guard result == 0 else {
                let problem = Self.failure("lock", path)
                close(descriptor)
                throw problem
            }
            var locked = stat(), current = stat()
            if fstat(descriptor, &locked) == 0, stat(path, &current) == 0,
               locked.st_dev == current.st_dev, locked.st_ino == current.st_ino {
                return descriptor
            }
            close(descriptor)
        }
        throw ToolError("Cannot lock \(path): the lock file keeps being replaced. Try again.")
    }

    // MARK: - Helpers

    /// Creates the folder and any missing parents, each with mode 0700. An existing folder is left as it is.
    static func makeFolder(_ url: URL) throws(ToolError) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ToolError(
                    "\(url.path) exists but is not a folder, so abakus cannot keep state there. Move it away, or set \(StateDirectory.environmentVariable) to a folder abakus may write."
                )
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path {
            try makeFolder(parent)
        }
        if mkdir(url.path, 0o700) != 0 {
            if errno == EEXIST, isFolder(url) { return }  // created by someone else meanwhile
            throw failure("create the folder", url.path)
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
        guard fchmod(descriptor, 0o600) == 0 else { return failure("write", path) }
        let problem: ToolError? = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return failure("write", path)
                }
            }
            return nil
        }
        if let problem { return problem }
        guard fsync(descriptor) == 0 else { return failure("write", path) }
        return nil
    }

    static func failure(_ action: String, _ path: String, code: Int32 = errno) -> ToolError {
        ToolError(
            "Cannot \(action) \(path): \(String(cString: strerror(code))). If the folder is not writable, set \(StateDirectory.environmentVariable) to a folder abakus may write."
        )
    }

    private static func randomTag() -> String {
        String(UInt64.random(in: .min ... .max), radix: 36)
    }
}
