# ADR-0004: Tallies: named values with a count, created explicitly, with thresholds that inform

Status: accepted, 2026-11-08; amended 2026-11-08 (threshold argument shape, crossing rule and "once", unique
suffix, `tally_set` and exactness, unknown names and arguments, thresholds that cannot be computed); amended
2026-11-08 (a random suffix by default, `shared: true` for an exact name; see the end)

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
  share a file. An invalid name is an error that states the rule and suggests a valid name where there is one
  (`My Items` → `my-items`).
- (Superseded by the amendment at the end: the suffix is now the default.) `tally_create` refuses a name that
  exists; the error shows the existing tally and suggests `unique: true`. With `unique: true` it appends `-`
  and four random characters from `[a-z0-9]` (`items` becomes `items-k3f9`), drawn again while the name is
  taken, and returns the name to use; the name given may then have at most 59 characters. The server's
  instructions tell agents to do this when they count their own work.
- `tally_add`, `tally_set` and `tally_drop` refuse an unknown name and never create one, so a typo or an
  expired tally shows up as an error instead of a new tally starting at 1. The error says the tally may never
  have been created or may have expired, and lists existing names (those with the given name plus a suffix
  first, at most 20).
- Thresholds watch the value or the count (default: the value). The argument is a list; each item has
  exactly one of `limit`, `at` (a list of marks) or `every`, and optionally `of: "value" | "count"`, e.g.
  `[{"limit": 20}, {"every": 5, "of": "count"}]`. Mixing is the point: effort points per item with a limit
  on the value, plus a checkpoint every 5 items on the count. Thresholds on the count take whole numbers.
  - `limit`: a ceiling. The addition that reaches it reports it as crossed; from then on, every response
    says it is reached, with how far past it the tally is (before that, what remains).
  - `at`: marks. The addition that reaches or passes a mark says so.
  - `every`: a period with the marks p, 2p, 3p, … (positive multiples only). The addition that reaches or
    passes a multiple says so; one addition can pass several (up to 10 are listed, beyond that a count with
    the first and the last).
  Thresholds inform; they never block an addition. That holds when a threshold cannot be evaluated either
  (arithmetic beyond `Decimal`'s range, such as a tiny period on a huge value): the addition is saved, and
  that threshold carries a `problem` note in `crossed` and in its status. `tally_list` and `tally_drop` work
  the same way. An addition fails only before anything is saved, and its error says the tally is unchanged.
- Crossing: an addition crosses a mark `m` when `before < m <= after`. Upward only: negative amounts are
  allowed and report nothing. "Once" means once per upward crossing: a tally that goes back below a mark (a
  negative amount, `tally_set`) and rises again reports it again. The rule needs only the old and the new
  state, so nothing about earlier reports is stored.
- `tally_set` sets the value, the count and/or replaces the thresholds of an existing tally. It reports no
  crossings: it corrects, it does not make progress. Setting the value also clears `exact: false`, since the
  value is then the one given.
- A tally that ever had to round says `exact: false` in every response, until its value is set.
- Unknown arguments are errors: a typo such as `amout` would otherwise be ignored and add 1.
- Every response carries the tally's full state, each threshold with its status.
- Tools: `tally_create`, `tally_add`, `tally_set` (value, count or thresholds of an existing tally),
  `tally_list` (all tallies or those with a name prefix, and the folder they are in), `tally_drop` (returns
  the final state).

## Consequences

- Sharing a tally on purpose works: one session creates it, others add to its name. Sharing by accident
  needs a session to ignore a refusal.
- Exact response shapes are documented in the README and the tool descriptions, not here.
- Minimum, maximum and counts per label are left out until a use needs them; adding them amends this ADR.

## Amendment 2026-11-08: a random suffix by default, `shared: true` for an exact name

### Context

In the first real use, an agent saw the tools and used `sum` and `date_diff`, but avoided tallies "because
they're shared across sessions". The description framed sharing as a hazard that comes with an opt-in fix
(`unique: true`), and that discouraged use. The common case is a session counting its own work; the safe
behaviour should be the default, not an option to remember. Version 0.1.0 was one day old and had no
consumers relying on `unique`.

### Decision

- `tally_create` always appends `-` and four random characters from `[a-z0-9]` (`items` becomes
  `items-k3f9`), drawn again while the name is taken, and returns the name to use. The name given may have
  at most 59 characters. Two sessions asking for the same name get two tallies.
- `shared: true` (default false) uses the name exactly, up to 64 characters, for a tally several sessions are
  meant to add to. It is refused if the name exists; the error shows the existing tally, says to add to it
  only when coordinating with whoever created it, and says to leave `shared` out to count one's own work.
- `unique` is removed. Passing it is an unknown argument; the error lists the arguments the tool takes and
  adds that the suffix is now the default.
- The server's instructions and `tally_create`'s description lead with the default, mention `shared: true`
  for collaborative tallies, and tell agents to leave other sessions' tallies alone unless they coordinate
  with them.
- The error for an unknown name keeps listing suffixed matches first; the likely mistake is now adding to the
  name asked for instead of the one returned.
- The number rules appear in full in `sum`'s description only; the tally tools carry one sentence
  (`NumberReader.rulesInBrief`), since an unreadable number's error states the rules anyway.

### Consequences

- A session that counts its own work cannot collide with another by accident, and does not have to know
  about sharing to be safe. Sharing on purpose is one explicit argument.
- Tally names in responses and in `tally_list` carry suffixes; an agent that loses the name finds it with
  `tally_list` and a prefix, or in the unknown-name error.
- Agents still see every tally of the user in `tally_list`; leaving other sessions' tallies alone is guidance
  in the descriptions, not enforced.
