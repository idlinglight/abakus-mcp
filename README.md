# abakus

Small, exact helpers for AI agents, served over the [Model Context Protocol](https://modelcontextprotocol.io)
and from the command line:

- **tallies**: named counters and running sums that keep their state across many turns and say when a
  threshold is reached ("at most 20 items this session", "self-check every 5 items");
- **sum**: exact sums of numbers, including numbers written as text (`410k`, `1,234.5`, `1.234,5`);
- **calc**: one formula worked out with exact fractions, also over tallies
  (`{errors-k3f9} / {requests-p2x7} * 100`);
- **date_diff**: the time between two dates, in calendar units and in exact totals.

Some small tasks are done better by a small program than by a language model, yet are rarely worth writing
ad-hoc tooling for. abakus is the pocket calculator for those. Its arithmetic is exact decimal arithmetic:
`0.1 + 0.2` is `0.3`, and a result that had to be rounded says so.

macOS only. Status: early, version 0.3.0.

## Install

```sh
./install.zsh
```

builds a release binary, runs the end-to-end check (`dev/check.zsh`) against it, and only then installs
`~/.local/bin/abakus` and its zsh completion (`~/.local/share/zsh/site-functions/_abakus`). To offer the tools
to Claude Code in every project, register it once:

```sh
claude mcp add --scope user abakus -- ~/.local/bin/abakus mcp
```

Other MCP clients: the command is `abakus mcp` (stdio).

## Tools

| Tool | What it does |
|---|---|
| `tally_create` | Create a tally under a name with a random suffix (or exactly, with `shared`), optionally with thresholds |
| `tally_add` | Add an amount (default 1); says when a threshold is crossed |
| `tally_set` | Correct a tally's value, count or thresholds |
| `tally_list` | List tallies with their state |
| `tally_drop` | Delete a tally |
| `sum` | Add a list of numbers exactly |
| `calc` | Work out one expression exactly, also over tallies by name |
| `date_diff` | Time between two dates or times, in calendar units and in totals |

Every tool returns a JSON object. Errors say what happened and what to do next.

## Tallies

A tally is a named, exact `value` plus a `count` of additions, kept in a file so it survives long work and
context compaction. `tally_create` appends a random suffix to the name (`review` becomes `review-k3f9`), so
each session counts its own; the response has the name to use from then on. With `shared: true` the name is
used exactly, for a tally several sessions are meant to add to; that is refused if the name exists. All
sessions of the user see the same tallies (`tally_list` shows them all), so the tool descriptions tell agents
to leave other sessions' tallies alone unless they coordinate with them
([ADR-0004](docs/adr/0004-tallies.md)).

Names: lowercase letters, digits, `.`, `_`, `-`, starting with a letter or digit, at most 64 characters
including the suffix (so 59 as given, 64 with `shared: true`); a longer name is refused with a suggestion cut
to 59. Tallies untouched for about three days expire ([ADR-0003](docs/adr/0003-state-in-user-temp-folder.md)).

Every response is the tally's full state; numbers that came as strings are listed under `read`.

**Thresholds** are a list; each item has exactly one of `limit` (a ceiling), `at` (a list of marks) or
`every` (a period), and optionally `of: "value"` (default) or `"count"`. An addition crosses a mark when it
takes the tally from below the mark to the mark or past it; a tally that goes back down and up again reports
the mark again. Thresholds never block. Each threshold's status is in every response: a limit says
`reached` and `remaining` or `over`; `at` and `every` say the `next` mark.

`tally_create` `{name, shared?, thresholds?, decimal?}`

```json
{"name": "review", "thresholds": [{"limit": 20}, {"every": 5, "of": "count"}]}
→ {"name": "review-k3f9", "value": 0, "count": 0,
   "thresholds": [{"limit": 20, "of": "value", "reached": false, "remaining": 20},
                  {"every": 5, "of": "count", "next": 5}],
   "created": "2026-11-08T09:30:00Z", "updated": "2026-11-08T09:30:00Z"}
```

`tally_create` always makes a new tally. Given a name that exists exactly, typically one it returned earlier,
the new tally still gets a suffix, and the response adds a `note`: to continue the existing tally, add to it
with `tally_add` and drop the new one with `tally_drop`.

```json
{"name": "review-k3f9"}
→ {"name": "review-k3f9-p2x7", "value": 0, "count": 0, "thresholds": [],
   "created": "2026-11-08T09:31:00Z", "updated": "2026-11-08T09:31:00Z",
   "note": "A tally named \"review-k3f9\" already exists, and tally_create always makes a new tally: …"}
```

`tally_add` `{name, amount? (default 1), decimal?}` adds `added`, `crossed` (`[]` if nothing) and `read`:

```json
{"name": "review-k3f9", "amount": "6"}
→ {"name": "review-k3f9", "value": 21, "count": 6, "added": 6, "read": [{"input": "6", "value": 6}],
   "crossed": [{"limit": 20, "of": "value"}],
   "thresholds": [{"limit": 20, "of": "value", "reached": true, "over": 1},
                  {"every": 5, "of": "count", "next": 10}],
   "created": "2026-11-08T09:30:00Z", "updated": "2026-11-08T09:36:00Z"}
```

Crossings look like `{"limit": 20, "of": "value"}`, `{"at": [1000000], "of": "value"}` (the marks crossed)
or `{"every": 5, "of": "count", "at": [5]}`; past 10 multiples,
`{"every": 1, "of": "value", "times": 250, "first": 1, "last": 250}`. A tally that ever had to round says
`"exact": false`.

`tally_set` `{name, value?, count?, thresholds?, decimal?}` corrects a tally, reports no crossings;
`thresholds: []` removes them all.

`tally_list` `{prefix?}` lists tallies sorted by name, and the folder they are kept in:

```json
{"prefix": "bytes"}
→ {"folder": "/var/folders/…/T/abakus/tallies",
   "tallies": [{"name": "bytes", "value": 2490123.5, "count": 1,
                "thresholds": [{"at": [1000000, 5000000], "of": "value", "next": 5000000}],
                "created": "2026-11-08T09:36:00Z", "updated": "2026-11-08T09:36:00Z"}]}
```

`tally_drop` `{name}` deletes the tally and returns its final state with `"dropped": true`.

An unknown name is an error, never a new tally: the name may be misspelled, have expired, or lack its
suffix. `details.existing` lists the tallies that exist (at most 20), those whose names start with the name
and `-` first. Every tally but a shared one has a suffix, so those may belong to other sessions: they come
with their state under `details.matching` (the first three in the message too), and the error says to use one
only if you know you created it, and otherwise to create a new tally (`tally_drop` says to leave it instead:
tallies expire by themselves):

```text
tally_add {"name": "review"}
There is no tally named "review". It may never have been created (check the spelling), or it may have
expired: … a tally whose name starts with "review-" exists: "review-k3f9" (created 2026-11-08T09:30:00Z,
value 21, count 6). It may belong to another session: use it only if you know you created it (compare its
created time with when you created yours). If unsure, create a new tally with tally_create. …
Details: {"name": "review",
          "matching": [{"name": "review-k3f9", "value": 21, "count": 6, "created": "2026-11-08T09:30:00Z"}],
          "existing": ["review-k3f9", "bytes"]}
```

Creating a shared tally under an existing name shows that tally and says to add to it only in coordination
with whoever created it, or to leave `shared` out to count one's own work. An invalid name comes with a
suggestion (`"Review Items"` → `"review-items"`).

## Numbers

Every number argument takes a JSON number or a string. JSON numbers are read from their literal text, never
through binary floating point. Strings follow fixed rules ([ADR-0005](docs/adr/0005-numbers.md)):

- The decimal mark is `.`, or `,` when the call passes `"decimal": ","`. The other mark may only group
  thousands, in groups of three: `1,234,567.5` (or `1.234.567,5`).
- An optional sign (`+`, `-`, `−`), an optional exponent (`2.5e3`) or one suffix: `k`/`K` (thousand), `M`
  (million), `G` (billion), `T` (trillion). A lowercase `m` is refused, as are a suffix with an exponent and a
  space before the suffix (`410 k`). `.5` is 0.5; `5.` is refused. Whitespace around the number is ignored.
- Anything else (units, currency signs, `%`, spaces inside) is an error that names the input and says what is
  accepted. So are more than 38 significant digits, magnitudes of 10^165 or more and digits below 10^-128:
  input is never rounded.

Numbers inside a `calc` expression are not number strings: they take no grouping and no `decimal` argument
(see [calc](#calc)).

Arithmetic is exact, with 38 significant digits; `calc` computes with exact fractions. Values meant for reading
(the mean of `sum`, the totals of `date_diff`, the result of `calc`) are exact when they fit; otherwise they keep
15 significant digits, rounded half away from zero, and the response says so (`mean_exact: false`,
`exact: false`). A non-zero value never comes out as 0.

## sum

`{"numbers": [number | string, …], "decimal": "." | ","}`. `numbers` is required and may be empty.

The response has `total`, `count` and `mean` (null for an empty list). `total_exact: false` or
`mean_exact: false` appear when a value had to be rounded. `notes` appears when a string reads differently with
the other decimal mark (`"1,234"` is 1234 with `.`, 1.234 with `,`): one sentence, however many such strings
there are, with the first one, both readings and what to do.

The command line also prints `read`, how each string was read (`{"index", "input", "value"}`; left out when there
are no strings). Over MCP it is left out: it grows with the list, and an MCP result stays small
([ADR-0008](docs/adr/0008-small-mcp-results.md)). To see how one string is read, sum it alone.

```json
{"numbers": ["1.234,5", "410k", 8], "decimal": ","}
→ {"total": 411242.5, "count": 3, "mean": 137080.833333333, "mean_exact": false}

abakus call sum '{"numbers": ["1.234,5", "410k", 8], "decimal": ","}'
→ {"total": 411242.5, "count": 3, "mean": 137080.833333333, "mean_exact": false,
   "read": [{"index": 0, "input": "1.234,5", "value": 1234.5}, {"index": 1, "input": "410k", "value": 410000}]}
```

## calc

`{"expression": string}`. One expression, worked out with exact fractions and rounded once, at the end
([ADR-0007](docs/adr/0007-calc.md)):

- Numbers as in number strings, but without grouping: `12`, `0.5`, `.5`, `2.5e3`, `410k`, `1.5M`. The decimal
  mark is always `.`; a comma directly between two digits is refused as a thousands separator, so function
  arguments are separated by a comma and a space.
- `+`, `-`, `*` (or `×`), `/` (or `÷`), `^` (or `**`) with a whole-number exponent from -9999 to 9999,
  parentheses and a leading minus. `^` binds tighter than a leading minus and groups from the right: `-2^2` is
  -4, `(-2)^2` is 4, `2^3^2` is 512. No implicit multiplication (`2(3+4)` is an error that shows where the `*`
  goes), and no `%`: multiply by 100 for a percentage, or by 1.1 to add 10%.
- `abs(x)`, `round(x, places)` (half away from zero), `min(a, b, …)`, `max(a, b, …)`. No roots, constants or
  units.
- `{name}` is a tally's value, `{name:count}` its count: any tally, shared ones too, by its full name. All
  tallies an expression uses are read at the same moment; calc never changes them.
- At most 1000 characters, nesting at most 64 deep, and at most 2000 digits in the numerator and the
  denominator of any value on the way.

The response has `result` (a JSON number), `read` (the expression as it was understood: numbers written out,
parentheses around every operation but the outermost, except along a chain of `+` or of `*`: `1 + 2 + 3`) and
`tallies`, each tally reference once with the number used (`{"name", "of", "value"}`; left out when there are
none). A result that is a terminating decimal of at most 38 significant digits, with no digits below 10^-128, is
exact. Otherwise it is rounded half away from zero to 15 significant digits (to
whole units when the integer part is longer), and `exact: false` and `fraction`, the exact value as
`"numerator/denominator"`, are added; `fraction` is left out when its numerator or denominator has more than
100 digits. A tally whose value had to be rounded (`exact: false` in its state) makes the result
`exact: false` too, and its entry in `tallies` says `"exact": false`.

```json
{"expression": "{errors-k3f9} / {requests-p2x7} * 100"}
→ {"result": 2.96, "read": "({errors-k3f9} / {requests-p2x7}) * 100",
   "tallies": [{"name": "errors-k3f9", "of": "value", "value": 37},
               {"name": "requests-p2x7", "of": "value", "value": 1250}]}

{"expression": "{effort-a1b2} / {effort-a1b2:count}"}
→ {"result": 3.95833333333333, "exact": false, "fraction": "95/24", "read": "{effort-a1b2} / {effort-a1b2:count}",
   "tallies": [{"name": "effort-a1b2", "of": "value", "value": 47.5},
               {"name": "effort-a1b2", "of": "count", "value": 12}]}

{"expression": "round(1000 * 1.045^10, 2)"}
→ {"result": 1552.97, "read": "round(1000 * (1.045 ^ 10), 2)"}
```

An error gives the position (characters counted from 1) and the expression, says what happened and what to
write or do instead. An unknown tally is the tally tools' error (`details.existing`, `details.matching`) after
where the reference is, without any advice to create one, and nothing is computed. A result out of range says
by which power of ten to scale the expression. Errors found after the tallies were read show them:

```text
calc {"expression": "{errors-k3f9} / {queued}"}
Division by zero at character 15 of "{errors-k3f9} / {queued}": the divisor {queued} is 0. While the divisor
is 0, the result has no value: report that, or calculate again once something has been added to the tally
"queued".
Details: {"tallies": [{"name": "errors-k3f9", "of": "value", "value": 37},
                      {"name": "queued", "of": "value", "value": 0}]}
```

## date_diff

`{"from": string, "to": string}`. `from` is required; `to` defaults to now. Each is an ISO 8601 date
(`2026-11-08`, read as 00:00 UTC), a date-time with `Z` or an offset (`2026-11-08T14:30:00+01:00`; seconds
optional, up to 9 fractional digits), or `"now"`. A date-time without an offset is read as UTC and noted.
Years 1583 to 9999 ([ADR-0006](docs/adr/0006-date-differences.md)).

The response has `from` and `to` in UTC, `from_is_now` / `to_is_now` when the current time was used,
`to_before_from`, a `calendar` breakdown (`years`, `months`, `days`, `hours`, `minutes`, `seconds`; Gregorian,
UTC, counted forward from the earlier instant, so Jan 31 + 1 month = Feb 28/29), a short `text` (whole
seconds only, `less than 1 second` when a fraction is all there is), `totals`
(`days`, `hours`, `minutes`, `seconds`) and `notes` when something was assumed. When `to` is before `from`,
every number is negative.

```json
{"from": "2026-11-08T14:30:00+01:00", "to": "2027-01-20"}
→ {"from": "2026-11-08T13:30:00Z", "to": "2027-01-20T00:00:00Z", "to_before_from": false,
   "calendar": {"years": 0, "months": 2, "days": 11, "hours": 10, "minutes": 30, "seconds": 0},
   "text": "2 months 1 week 4 days 10 hours 30 minutes",
   "totals": {"days": 72.4375, "hours": 1738.5, "minutes": 104310, "seconds": 6258600}}
```

## Command line

Each command runs one tool and prints the JSON an agent would get, plus the details an MCP result leaves out,
such as `sum`'s `read` ([ADR-0008](docs/adr/0008-small-mcp-results.md)). A tool's error goes to stderr with exit
status 1 (the same text an agent reads); a usage mistake shows the usage with exit status 64.

```sh
abakus tally create review --limit 20 --every-count 5
abakus tally add review-k3f9 6                   # the name it printed, suffix included
abakus tally create build-errors --shared        # exactly this name, for several sessions
abakus tally list
abakus sum 410k 1,234.5 -3
grep -oE '[0-9][0-9.]*k' build.log | abakus sum  # numbers from stdin
abakus sum --decimal , 1.234,5
abakus calc '{errors-k3f9} / {requests-p2x7} * 100'  # quote it: * ( { ^ mean something to the shell
abakus calc -2^2                                 # -4; a leading minus is part of the expression
abakus date-diff 2026-11-08 now
abakus tools                                     # the tools and what they do
abakus call sum '{"numbers": ["0.1", 0.2]}'      # any tool with JSON arguments, as an MCP client sends them
```

`--help` on any command says the rest.

## MCP protocol support

`abakus mcp` speaks MCP over stdio: newline-delimited JSON-RPC 2.0, one message per line, diagnostics on
stderr. It exits when stdin closes.

Supported protocol revisions: **2026-07-28** (stateless: `server/discover`, version and capabilities in each
request's `_meta`) and **2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05** (`initialize` handshake).
`tools/list` and `tools/call` work with or without a handshake.

The server offers tools only: no resources, prompts, logging or subscriptions, and it never sends requests to
the client. A tool's result comes back as compact JSON text and, on revisions that have it (2025-06-18 and
later), also as `structuredContent`. A tool error comes back as a result with `isError: true` and a readable
message. Numbers keep their exact text from request to response. Details and edge cases:
[ADR-0002](docs/adr/0002-own-mcp-server.md).

## State

Tallies live in `abakus/tallies/` in the per-user temporary folder (`/var/folders/…/T/`), one JSON file per
tally, shared by every session of the same user and guarded by a lock on the folder. macOS deletes files there
that have not been touched for three days. `ABAKUS_STATE_DIR` points abakus at a different folder.

## Build and test

Requires macOS 15 or later and Swift 6.2 or later (Xcode 27 or its command line tools).

```sh
swift build
swift test
dev/check.zsh      # end to end against .build/debug/abakus: both MCP eras and the CLI, in a scratch folder
```

## Decisions

Architecture decisions are recorded in [`docs/adr/`](docs/adr/):

- [ADR-0001](docs/adr/0001-one-package-one-binary.md): One Swift package, one binary, MCP first
- [ADR-0002](docs/adr/0002-own-mcp-server.md): Own MCP server instead of the Swift SDK (amended: supported revisions, error mapping)
- [ADR-0003](docs/adr/0003-state-in-user-temp-folder.md): State: one file per tally in the per-user temporary folder (amended: locking)
- [ADR-0004](docs/adr/0004-tallies.md): Tallies: named values with a count, created explicitly, with thresholds that inform (amended: crossings; a random suffix by default, `shared` for exact names; `tally_drop`'s advice for unknown names)
- [ADR-0005](docs/adr/0005-numbers.md): Numbers: exact decimals, read by stated rules (amended: own exact arithmetic, reading rules in detail, the rules in full in `sum`'s description only)
- [ADR-0006](docs/adr/0006-date-differences.md): Date differences: ISO 8601 in, calendar units and exact totals out, in UTC (amended: whole seconds in `text`)
- [ADR-0007](docs/adr/0007-calc.md): calc: one expression, exact fractions, tallies by name (amended: underflow and the readable policy in full, when `fraction` is left out, rounded tallies in the response, unknown names, flat chains of + and * in `read`, errors while evaluating, parser details)
- [ADR-0008](docs/adr/0008-small-mcp-results.md): MCP results stay small; the command line shows everything (proposed)

## License

[0BSD](LICENSE)
