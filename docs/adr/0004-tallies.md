# ADR-0004: Tallies: named values with a count, created explicitly, with thresholds that inform

Status: accepted, 2026-11-08

## Context

The cases abakus is for:

- counting work items against a budget ("at most 20 in this session");
- checkpoints ("check your own work after every 5 items");
- adding up numbers that arrive one at a time, one per file or log line.

An agent cannot reliably carry a running value through many turns: numbers get copied wrong, and context
compaction can drop them. Tally names are global ([ADR-0003](0003-state-in-user-temp-folder.md)), and an agent
does not reliably know an identifier that is unique to its session.

## Decision

- A tally is a named `value`, the exact sum of the amounts added ([ADR-0005](0005-numbers.md)), and a
  `count`, the number of additions. Counting is adding 1, the default amount. Amounts may be negative.
- Names: lowercase letters, digits, `.`, `_` and `-`, starting with a letter or digit, at most 64
  characters. Lowercase only, because the file system ignores case by default and `Items` and `items` would
  share a file.
- `tally_create` refuses a name that exists; the error shows the existing tally. With `unique: true` it
  appends a random suffix (`items` becomes `items-k3f9`) and returns the name to use. The server's
  instructions tell agents to do this when they count their own work.
- `tally_add` refuses an unknown name and never creates one, so a typo or an expired tally shows up as an
  error instead of a new tally starting at 1.
- Thresholds watch the value or the count (default: the value):
  - `limit`: a ceiling. Once reached, every response says so, with how far past it the tally is.
  - `at`: marks. The addition that reaches or passes a mark says so, once.
  - `every`: a period. The addition that reaches or passes a multiple says so; one addition can pass
    several.
  Thresholds inform; they never block an addition.
- Every response carries the tally's full state.
- Tools: `tally_create`, `tally_add`, `tally_set` (value, count or thresholds of an existing tally),
  `tally_list`, `tally_drop`.

## Consequences

- Sharing a tally on purpose works: one session creates it, others add to its name. Sharing by accident
  needs a session to ignore a refusal.
- Exact response shapes are documented in the README and the tool descriptions, not here.
- Minimum, maximum and counts per label are left out until a use needs them; adding them amends this ADR.
