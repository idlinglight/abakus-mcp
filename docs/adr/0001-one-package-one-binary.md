# ADR-0001: One Swift package, one binary, MCP first

Status: accepted, 2026-11-08

## Context

abakus offers agents small things they do worse than a small program: keeping a count across many turns,
adding numbers exactly, telling the time between two dates. Each of these is a few lines of code, but an
agent that needs one has to decide between doing it in its head and writing ad-hoc tooling. A ready tool
removes that decision.

How an agent learns that a tool exists matters as much as the tool. An MCP server's tools show up in the
agent's tool list by name (with deferred loading, often only by name until the agent loads one), and the
server's instructions reach the system prompt. A command line tool needs a line in a CLAUDE.md or a skill
before an agent knows of it. People, scripts and tests are better served by a command line.

## Decision

- One SwiftPM package with one executable, `abakus`. `abakus mcp` serves MCP over stdio; other subcommands
  offer the same operations on the command line.
- Three targets: `AbakusCore` holds all behaviour, with every tool defined once (`Tool`, `Catalog`);
  `AbakusMCP` is the protocol layer ([ADR-0002](0002-own-mcp-server.md)); `abakus` wires both to the
  command line. Tests use Swift Testing.
- Dependencies only from the `apple` and `swiftlang` GitHub organisations, versions published at least three
  days before they are taken. Currently one: swift-argument-parser.
- macOS 15 or later.

## Consequences

- Tool behaviour is tested in the core without any protocol; the MCP server and the CLI stay thin.
- Nothing else consumes the core, so there is no separate library package or repository.
- macOS only: the state location depends on it ([ADR-0003](0003-state-in-user-temp-folder.md)). Another
  platform would revisit that ADR first.
