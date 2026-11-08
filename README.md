# abakus

Small, exact helpers for AI agents, served over the [Model Context Protocol](https://modelcontextprotocol.io)
and from the command line: named tallies that keep a count across many turns and say when a threshold is
reached, exact sums of numbers given as text, and the time between two dates.

The idea: some small tasks are done better by a small program than by a language model, yet are rarely
worth writing ad-hoc tooling for. abakus is the pocket calculator for those.

Status: under construction, not yet usable.

## Tools

| Tool | What it does |
|---|---|
| `tally_create` | Create a named tally, optionally with a unique suffix and thresholds |
| `tally_add` | Add an amount (default 1); says when a threshold is crossed |
| `tally_set` | Change a tally's value, count or thresholds |
| `tally_list` | Show tallies |
| `tally_drop` | Delete a tally |
| `sum` | Add a list of numbers exactly |
| `date_diff` | Time between two dates or times, in calendar units and in totals |

## State

Tallies live in `abakus/` in the per-user temporary folder (`/var/folders/…/T/abakus/`), one file per tally,
shared by every session of the same user. macOS deletes files there that have not been touched for three days.
`ABAKUS_STATE_DIR` points abakus at a different folder. See [ADR-0003](docs/adr/0003-state-in-user-temp-folder.md).

## Requirements

- macOS 15 or later, Swift 6.2 or later (Xcode 27 or the matching command line tools).

## Build and test

```sh
swift build
swift test
```

## Decisions

Architecture decisions are recorded in [`docs/adr/`](docs/adr/):

- [ADR-0001](docs/adr/0001-one-package-one-binary.md): One Swift package, one binary, MCP first
- [ADR-0002](docs/adr/0002-own-mcp-server.md): Own MCP server instead of the Swift SDK
- [ADR-0003](docs/adr/0003-state-in-user-temp-folder.md): State: one file per tally in the per-user temporary folder
- [ADR-0004](docs/adr/0004-tallies.md): Tallies: named values with a count, created explicitly, with thresholds that inform
- [ADR-0005](docs/adr/0005-numbers.md): Numbers: exact decimals, read by stated rules

## License

[0BSD](LICENSE)
