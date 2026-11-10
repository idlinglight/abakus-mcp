# ADR-0004: Tallies: named values with a count, created explicitly, with thresholds that inform

Status: accepted, 2026-11-08; amended 2026-11-08 (threshold argument shape, crossing rule and "once", unique
suffix, `tally_set` and exactness, unknown names and arguments, thresholds that cannot be computed); amended
2026-11-08 (a random suffix by default, `shared: true` for an exact name; see the end); amended 2026-11-08
(the advice for unknown names in `tally_drop`); amended 2026-11-10 (an `at` threshold by how many marks it has,
`at` crossings capped, at most 5 thresholds, `read` as a detail with a decimal note; see the end)

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
  first, at most 20). (The amendment at the end adds the state of those suffixed matches and drops any
  suggestion to use one.)
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
- Every response carries the tally's full state, each threshold with its status. (Amended 2026-11-10, see the
  end: an `at` threshold shows how many marks it has, not the marks; `at` crossings list at most 10 marks; at
  most 5 thresholds; how strings were read is a detail, with a note when a reading was a choice.)
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
  `items-k3f9`), drawn again while the name is taken, and returns the name to use. Two sessions asking for
  the same name get two tallies.
- The name given may have at most 59 characters: the suffix takes 5 of the 64. A longer name is an error
  that says so and suggests the name cut to 59 characters, without a trailing `-`, `.` or `_`. It does not
  suggest `shared: true`, which would turn a tally meant for one session's work into a shared one.
- Given a name that exists exactly, `tally_create` still creates a new tally with a suffix: creating never
  blocks on a name that may be someone else's. The typical case is an agent that gives a name it got earlier
  (after compaction, say) to continue counting, so the response then carries a `note`: a tally with exactly
  that name exists, `tally_create` always makes a new tally, and to continue the existing one, add to it with
  `tally_add` and drop the new one with `tally_drop`.
- `shared: true` (default false) uses the name exactly, up to 64 characters, for a tally several sessions are
  meant to add to. It is refused if the name exists; the error shows the existing tally, says to add to it
  only when coordinating with whoever created it, and says to leave `shared` out to count one's own work. It
  does not offer `tally_set` or `tally_drop` to start the tally over: an agent cannot know that a shared tally
  is its own, and starting it over would wipe the count of the sessions that share it.
- `unique` is removed. Passing it is an unknown argument; the error lists the arguments the tool takes and
  adds what to do instead, by the value passed: for `true`, leave it out, the suffix is the default; for
  `false`, pass `shared: true` for the exact name, which must not exist yet. Other values get no hint.
- The server's instructions and `tally_create`'s description lead with the default, mention `shared: true`
  for collaborative tallies, and tell agents to leave other sessions' tallies alone unless they coordinate
  with them.
- The error for an unknown name keeps listing the tallies whose names start with the name and `-` first, the
  likely mistake being to add to the name asked for instead of the one returned. But with a suffix on every
  tally but shared ones, such a tally is as likely another session's, so the error does not ask "did you
  mean": it gives each one's `created` time, value and count (up to three in the message, up to 20 under
  `details.matching`), says they may belong to other sessions, to use one only when the agent knows it
  created it (comparing created times), and otherwise to create a new tally.
- The number rules appear in full in `sum`'s description only; the tally tools carry one sentence
  (`NumberReader.rulesInBrief`) that says an unreadable number is an error that says why, and points to
  `sum`'s description. Every error about a number string also lists the accepted forms
  ([ADR-0005](0005-numbers.md)).

### Consequences

- A session that counts its own work cannot collide with another by accident, and does not have to know
  about sharing to be safe. Sharing on purpose is one explicit argument.
- Tally names in responses and in `tally_list` carry suffixes; an agent that loses the name finds it with
  `tally_list` and a prefix, or in the unknown-name error, and tells its own from others' by when it was
  created. An agent that cannot tell starts a new tally and loses its earlier count, which is better than
  adding to another session's.
- Agents still see every tally of the user in `tally_list`; leaving other sessions' tallies alone is guidance
  in the descriptions, not enforced.

## Amendment 2026-11-08: the advice for unknown names in `tally_drop`

The error for an unknown name told every tool's caller to create a new tally when unsure, which makes no sense
for a drop. `tally_drop`'s error now names a repeated drop as the first possible cause, and says, when tallies
with the name plus a suffix exist, to drop one only when the agent knows it created it and otherwise to leave it
to expire; without such tallies, that nothing was dropped. `tally_add` and `tally_set` keep the advice to create a
new tally. `tally_add`'s description no longer points to `tally_list` for finding a name, which steered agents
towards other sessions' tallies; it and `tally_set`'s description say that the error shows the tallies whose
names start with the name given, with when each was created.

## Amendment 2026-11-10: an `at` threshold by how many marks it has, at most 5 thresholds, `read` as a detail

### Context

[ADR-0008](0008-small-mcp-results.md) lets a successful MCP result grow at most logarithmically with the input and
with the stored state it reports on. The tools that work on one tally did not: "every response carries the tally's
full state, each threshold with its status" meant each threshold with its spec, an `at` threshold with all its
marks; `crossed` repeated every `at` mark crossed; and `read` listed every number string with its value. Neither
the number of thresholds nor the number of marks was limited. A `tally_create` with one `at` threshold of 200 marks
given as strings got a response of about 7,400 characters, and every `tally_add` after it repeated the 200 marks.
ADR-0008 listed this as a known exception.

The marks are the agent's own input: it has them in its request. What it needs from a response is where the tally
stands against them.

### Decision

- An `at` threshold's status is `{"marks": 50, "of": "value", "passed": 2, "next": 3000000}`: how many marks it
  has, how many are reached (at or below the current value or count), and the next mark, left out when all are
  passed. The kind key and `of` come first, as in the statuses of `limit` and `every`, which are unchanged.
  Responses still carry the tally's whole state; an `at` threshold is shown by what an agent acts on, not by its
  marks. The tally file keeps every mark: it is state, not a response.
- `crossed` for an `at` threshold starts the same way and lists the marks crossed, at most 10
  (`Threshold.listedMarks`, as for `every`); beyond that, how many with the first and the last:
  `{"marks": 400, "of": "value", "times": 250, "first": 150, "last": 399}`. Crossings of `limit` and `every` are
  unchanged.
- A tally keeps at most 5 thresholds, in `tally_create` and in `tally_set`. A sixth is an error that says to pass
  at most 5, that one `at` threshold takes any number of marks (so marks on the value, or on the count, fit in one),
  and that a second tally can watch the rest. The schema says `maxItems: 5`. The number of marks is not limited:
  the status no longer shows them. Five covers the cases this ADR is for (a budget, a checkpoint, a few marks) with
  room to spare, and keeps the thresholds of a response within a fixed size, as ADR-0008 asks of stored state.
- `read` is a detail of `tally_create`, `tally_add` and `tally_set` (ADR-0008): the command line prints it, an MCP
  result leaves it out. In its place, `sum`'s decimal note (ADR-0008, section "sum"), from the same code: when a
  number string in the call reads differently with the other decimal mark, and no other string in the call rules
  that mark out, `notes` holds one note of fixed size that names the argument (`amount`, `thresholds[0].at[2]`),
  gives both readings and says what to do. What to do depends on the tool, since by the time the agent reads the
  note the call has changed the tally:
  - `tally_set` is idempotent: call again with the other mark, as for `sum`.
  - `tally_create`: replace the thresholds with `tally_set` on the new tally, passing them again with the other
    mark. Calling `tally_create` again would make a second tally.
  - `tally_add`: the addition has counted with the reading it got, and adding again would count it a second time.
    The note gives the `tally_set` call with the value the other reading gives (`{"name": "bytes-k3f9", "value":
    26.234}`), which keeps the count: it was one addition either way. It also says that `tally_set` reports no
    crossings and that `crossed` follows the reading used, so a mark listed there may not have been reached. When
    that value has more than 38 significant digits, the note says how to get it instead. A negative amount was
    considered and not chosen: it corrects the value but counts a second addition, which throws off a checkpoint
    every N items.
  - Where only whole numbers go (a count, a threshold on the count), a string whose other reading has a fraction
    (`"1,234"` as a count) has no second reading, and it rules the other mark out like a string the other mark
    cannot read: calling again with it would fail.
- `tally_create`'s `note` about an existing name stays as it is, beside `notes`.
- The shared-name error shows the existing tally's state, as compact as every response. The unknown-name error's
  `details.matching` held only each tally's name, value, count and created time all along; ADR-0008 described it
  as whole tallies by mistake.

### Consequences

- A tally tool's MCP result has a fixed size: at most 5 threshold statuses, at most 10 marks per crossing, at most
  one decimal note, whatever was passed to `tally_create`. With an `at` threshold of 200 marks given as strings,
  `tally_create` and `tally_add` stay within 700 characters (`dev/check.zsh` checks it); the same call gave about
  7,400 before.
- The marks of an `at` threshold show in no response, on the command line neither. The agent has them in its
  request, and the tally's file keeps them (ADR-0003: state can be inspected with `cat`).
- Tally files follow the rules arguments follow ([ADR-0003](0003-state-in-user-temp-folder.md): one validation for
  both), so an existing file with more than 5 thresholds is now unreadable: calls on that tally fail with the usual
  error naming the file, `tally_drop` deletes it, and `tally_list` reports it under `unreadable`. Only abakus 0.4
  and earlier could write such a file, and a tally expires after about three days unchanged.
- abakus 0.5.0 is the first version with this. An agent that read the marks of an `at` threshold, or `read`, from
  a tally response over MCP no longer gets them; a crossing of an `at` threshold now starts with `marks`.
