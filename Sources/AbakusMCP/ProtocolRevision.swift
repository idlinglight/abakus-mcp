/// The MCP revisions this server speaks (ADR-0002).
///
/// The specification calls 2026-07-28 and later *modern*: every request carries the protocol version and the
/// client's capabilities in `params._meta`, and there is no handshake. 2025-11-25 and earlier are *legacy*:
/// the client negotiates a version with `initialize` first.
public enum ProtocolRevision: String, CaseIterable, Sendable, Comparable {
    case v2026_07_28 = "2026-07-28"
    case v2025_11_25 = "2025-11-25"
    case v2025_06_18 = "2025-06-18"
    case v2025_03_26 = "2025-03-26"
    case v2024_11_05 = "2024-11-05"

    /// Every supported revision, newest first, as `server/discover` and the unsupported-version error list them.
    public static let supported: [ProtocolRevision] = allCases.sorted(by: >)

    /// What `initialize` answers when the client asks for a revision this server does not speak in the legacy
    /// way, and what requests without a version use before any `initialize`.
    public static let newestLegacy: ProtocolRevision = .v2025_11_25

    public static func < (lhs: ProtocolRevision, rhs: ProtocolRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Modern revisions: results carry `resultType`, list results carry cache hints, `ping` is gone.
    public var isModern: Bool { self >= .v2026_07_28 }

    /// `structuredContent` in tool results exists since 2025-06-18.
    var hasStructuredContent: Bool { self >= .v2025_06_18 }

    /// Tool annotations (`readOnlyHint` and so on) exist since 2025-03-26.
    var hasToolAnnotations: Bool { self >= .v2025_03_26 }

    /// Only 2025-03-26 has JSON-RPC batches: it added them, and 2025-06-18 removed them again.
    var hasBatches: Bool { self == .v2025_03_26 }
}
