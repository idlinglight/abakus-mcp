import Foundation

/// Where abakus keeps state (ADR-0003): `ABAKUS_STATE_DIR` if set, otherwise `abakus/` in the per-user
/// temporary folder. That folder comes from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, not from `$TMPDIR`, so every
/// process of the user (each session's MCP server, the CLI) finds the same one even when their environments
/// differ. Resolving creates nothing; whoever writes creates the folder (mode 0700).
public enum StateDirectory {
    public static let environmentVariable = "ABAKUS_STATE_DIR"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(ToolError) -> URL {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try userTemporaryDirectory().appendingPathComponent("abakus", isDirectory: true)
    }

    static func userTemporaryDirectory() throws(ToolError) -> URL {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else {
            throw ToolError("Cannot find the per-user temporary folder. Set \(environmentVariable) to a folder for abakus state.")
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else {
            throw ToolError("Cannot find the per-user temporary folder. Set \(environmentVariable) to a folder for abakus state.")
        }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
