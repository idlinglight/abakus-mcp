# ADR-0002: Own MCP server instead of the Swift SDK

Status: accepted, 2026-11-08

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
