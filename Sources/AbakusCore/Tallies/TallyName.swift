/// Tally names (ADR-0004): lowercase letters, digits, `.`, `_` and `-`, starting with a letter or digit, at most
/// 64 characters. Lowercase only, because the file system ignores case and `Items` and `items` would share a file.
enum TallyName {
    static let maxLength = 64
    static let suffixLength = 4
    static let suffixAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    /// How often `suffixed` draws a new suffix when the drawn one is taken.
    static let suffixAttempts = 32

    static let rule = "a tally name uses lowercase letters, digits, '.', '_' and '-', starts with a letter or digit, and has at most 64 characters"

    static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maxLength, isLetterOrDigit(first) else { return false }
        return bytes.allSatisfy(isAllowed)
    }

    /// Throws an error that states the rule and, where one exists, a valid name close to the given one.
    /// With `suffixed`, the name must leave room for the suffix (`-` and four characters).
    static func validate(_ name: String, suffixed: Bool = false) throws(ToolError) {
        guard isValid(name) else {
            var message = "\"\(name)\" is not a valid tally name: \(rule)."
            var details: JSONObject = ["name": .string(name)]
            if let suggestion = suggestion(for: name) {
                message += " Try \"\(suggestion)\"."
                details["suggestion"] = .string(suggestion)
            }
            throw ToolError(message, details: details)
        }
        let room = maxLength - suffixLength - 1
        if suffixed, name.utf8.count > room {
            throw ToolError(
                "\"\(name)\" is too long: tally_create appends a random suffix like \"-k3f9\", so the name may have at most \(room) characters.",
                details: ["name": .string(name)]
            )
        }
    }

    /// A valid name close to an invalid one (`My Items` becomes `my-items`), or nil if there is none.
    static func suggestion(for name: String) -> String? {
        var characters = name.lowercased().unicodeScalars.map { scalar -> Character in
            guard scalar.isASCII, isAllowed(UInt8(scalar.value)) else { return "-" }
            return Character(scalar)
        }
        while let first = characters.first, !(first.asciiValue.map(isLetterOrDigit) ?? false) {
            characters.removeFirst()
        }
        let candidate = String(characters.prefix(maxLength))
        return candidate.isEmpty || candidate == name || !isValid(candidate) ? nil : candidate
    }

    /// `base` plus `-` and a random suffix that `isTaken` does not report as taken.
    static func suffixed(
        _ base: String,
        isTaken: (String) throws(ToolError) -> Bool,
        suffix: () -> String = randomSuffix
    ) throws(ToolError) -> String {
        for _ in 0..<suffixAttempts {
            let candidate = "\(base)-\(suffix())"
            if try !isTaken(candidate) { return candidate }
        }
        throw ToolError("Could not find a free name for \"\(base)\" with a random suffix after \(suffixAttempts) attempts. Try a different name.")
    }

    static func randomSuffix() -> String {
        String((0..<suffixLength).map { _ in suffixAlphabet.randomElement()! })
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        isLetterOrDigit(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
}
