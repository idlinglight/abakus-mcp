# ADR-0002: Own MCP server instead of the Swift SDK

Status: accepted, 2026-11-08; amended 2026-11-08 (supported revisions, batches, duplicate keys, error mapping)

## Context

The official Swift SDK (`modelcontextprotocol/swift-sdk`) exists. In autumn 2026 it is still before 1.0,
with API changes between minor versions, and it depends on packages from owners outside those
[ADR-0001](0001-one-package-one-binary.md) allows.

What abakus needs from MCP is small: the stdio transport, `tools/list`, `tools/call` and `ping`. Every tool
call stands on its own; nothing depends on an earlier request.

MCP revision 2026-07-28 made the protocol stateless: no `initialize` handshake, servers describe themselves
through `server/discover`, and every request carries the protocol version and client identity in
`params._meta`. The specification calls that revision and later ones *modern*, 2025-11-25 and earlier
*legacy*. Clients in use speak one or the other, or both.

## Decision

Write the server in this repository: newline-delimited JSON-RPC 2.0 on stdin and stdout, diagnostics on
stderr.

- It speaks both eras: it answers `server/discover` (modern, 2026-07-28) and `initialize` (legacy,
  2025-11-25 down to 2024-11-05). Since no request depends on another, `tools/list` and `tools/call` work
  with or without a handshake.
- It offers the `tools` capability only: no resources, prompts, completions, logging or subscriptions, and
  it never sends requests to the client.
- It sends `instructions` that tell agents what abakus is for and how to name their tallies
  ([ADR-0004](0004-tallies.md)).
- Tool results carry the tool's JSON object twice: as compact JSON text in `content`, which is what the
  model reads, and as `structuredContent` for clients on revisions that have it. A `ToolError` becomes a
  result with `isError: true` and its message; protocol mistakes become JSON-RPC errors.
- Its own JSON reader and writer keep number literals as text ([ADR-0005](0005-numbers.md)).

## Consequences

- Following the specification is our job. The specification lives in the GitHub repository
  `modelcontextprotocol/modelcontextprotocol`; a new revision means reading its changelog and amending this
  ADR with what is supported.
- No dependency for the protocol.
- Reasons to revisit: an HTTP transport, requests from server to client, or the protocol surface growing
  past "small".

## Amendment 2026-11-08: supported revisions and protocol details

Supported revisions: **2026-07-28** (modern) and **2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05**
(legacy). `server/discover` (`supportedVersions`) and the unsupported-version error (`data.supported`) list
all five, newest first, so a client that speaks another modern revision and a legacy one can still fall back
to `initialize`.

Which revision serves a request:

- `params._meta["io.modelcontextprotocol/protocolVersion"]` names it. For 2026-07-28, `_meta` must also
  carry `io.modelcontextprotocol/clientCapabilities`; a missing field is `-32602`. A version not in the list
  is `-32022` (`UnsupportedProtocolVersion`, with `supported` and `requested`).
- Otherwise the revision the last `initialize` negotiated: the requested one if it is a supported legacy
  revision, else 2025-11-25. Before any `initialize`, 2025-11-25. `server/discover` without `_meta` is
  `-32602`.
- `ping` exists in the legacy revisions only; 2026-07-28 removed it (`-32601`).

What the revision changes: `resultType: "complete"`, the cache hints (`ttlMs: 3600000`, `cacheScope:
"public"`, on `server/discover` and `tools/list`) and `_meta["io.modelcontextprotocol/serverInfo"]` appear
in modern results only; `structuredContent` from 2025-06-18; tool annotations from 2025-03-26.

Decisions:

- **Batches** are accepted only after `initialize` negotiated 2025-03-26, the one revision that has them
  (it requires receiving them; 2025-06-18 removed them). `initialize` inside a batch is refused. In every
  other case the whole array gets one `-32600` error.
- **Duplicate object keys** make the message unreadable (`-32700`), like any other invalid JSON. Readers
  disagree on which value wins, so accepting them would let client and server see different arguments.
- **Error mapping:** invalid JSON or UTF-8, or nesting deeper than 64 levels, `-32700`; a message that is
  not a valid request object (not an object, wrong `jsonrpc`, missing or non-string `method`, an id that is
  neither string nor number, `params` that is neither object nor array) `-32600`, as is a line longer than
  16 MiB, which is discarded; an unknown method `-32601`; malformed parameters (`params` as an array, a
  missing tool name, `arguments` not an object, a `cursor`, which this server never issues, missing modern
  `_meta` fields) `-32602`. When the id cannot be read, the error response has no `id` member, as MCP's
  schema has no `null` id. Notifications never get a response, and JSON-RPC responses from the client are
  ignored.
- **Tool calls:** missing or `null` `arguments` count as `{}`. A `ToolError` becomes `isError: true` with
  the message, followed by a line `Details: <compact JSON>` when it has details, and no `structuredContent`,
  which belongs to a tool's result.
- **Unknown tool:** `-32602`, "Unknown tool: …", in every revision; all five specify it as a protocol error.
