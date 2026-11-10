# ADR-0004: Tallies: named values with a count, created explicitly, with thresholds that inform

Status: accepted, 2026-11-08; amended 2026-11-08 (threshold argument shape, crossing rule and "once", unique
suffix, `tally_set` and exactness, unknown names and arguments, thresholds that cannot be computed); amended
2026-11-08 (a random suffix by default, `shared: true` for an exact name; see the end); amended 2026-11-08
(the advice for unknown names in `tally_drop`); amended 2026-11-10 (`tally_list` over MCP: the folder and how many
tallies there are)

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
- Every response carries the tally's full state, each threshold with its status.
- Tools: `tally_create`, `tally_add`, `tally_set` (value, count or thresholds of an existing tally),
  `tally_list` (all tallies or those with a name prefix, and the folder they are in; over MCP only the folder and
  how many there are, by the amendment of 2026-11-10), `tally_drop` (returns the final state).

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
  adding to another session's. (Since the amendment of 2026-11-10, over MCP only in the unknown-name error.)
- Agents still see every tally of the user in `tally_list`; leaving other sessions' tallies alone is guidance
  in the descriptions, not enforced. (Since the amendment of 2026-11-10, only on the command line.)

## Amendment 2026-11-08: the advice for unknown names in `tally_drop`

The error for an unknown name told every tool's caller to create a new tally when unsure, which makes no sense
for a drop. `tally_drop`'s error now names a repeated drop as the first possible cause, and says, when tallies
with the name plus a suffix exist, to drop one only when the agent knows it created it and otherwise to leave it
to expire; without such tallies, that nothing was dropped. `tally_add` and `tally_set` keep the advice to create a
new tally. `tally_add`'s description no longer points to `tally_list` for finding a name, which steered agents
towards other sessions' tallies; it and `tally_set`'s description say that the error shows the tallies whose
names start with the name given, with when each was created.

## Amendment 2026-11-10: `tally_list` over MCP: the folder and how many tallies there are

### Context

`tally_list` returned every tally of the user, other sessions' included, each with its full state and every
threshold. Its size depended on what other sessions did, which the caller does not control, and
[ADR-0008](0008-small-mcp-results.md) listed it as a known exception to the rule that MCP results stay small (issue
#15). Since the amendments above, an agent that lost a name finds it in the error for an unknown name, which shows
the tallies with that name plus a suffix and when each was created; `tally_add`'s description stopped pointing to
`tally_list` for that, because the list steered agents towards other sessions' tallies.

The issue proposed returning the folder, a count and what to expect in it, so that agents would read the files
with `ls`, `jq` or `grep`. That would make the file format an interface: the descriptions would have to document
it and say that only the tally tools write, and every later format version would have to consider agents reading
files. Not chosen.

Also considered: a list of at most a fixed number of tallies plus a count, which ADR-0008 allows. Its entries would
be whichever tallies sort first, as often other sessions' as one's own. The unknown-name error picks tallies by the
name given, which serves an agent looking for its own tally better.

### Decision

- Over MCP, `tally_list` returns `folder`, `tallies_found` (the number of readable tallies) and `unreadable_found`
  (the number of tallies whose file cannot be read, only when there are any); with `prefix`, both count only
  tallies whose names start with it: `{"folder": "/var/folders/…/T/abakus/tallies", "tallies_found": 3}`. Its
  title is "Count tallies"; the name stays `tally_list`.
- `tallies` (each tally's full state, sorted by name) and `unreadable` (each such name with what is wrong) are its
  detail keys (ADR-0008): the command line prints them, `abakus tally list [prefix]` and `abakus call tally_list`
  alike.
- Not `count`: a tally's `count` is its number of additions, and on the command line both appear in one result.
  With a full name as `prefix`, `"count": 1` would read as that tally's count. `tallies_found` and
  `unreadable_found` each count the list of the same name.
- What `tally_list` is for over MCP: how many tallies there are, with a prefix or all, and where they are kept. To
  look up a lost name, the description points to `calc` with the name without its suffix (`{items}`): calc never
  writes, and its error for an unknown name shows the tallies named with it plus a suffix (up to 20, with when
  each was created), as the other tally tools' error does. Those tools are not offered for a lookup: `tally_add`
  or `tally_drop` with a guessed name would change or delete a shared tally of exactly that name. A partial name
  (`item` for `items-k3f9`) finds nothing over MCP; the command line lists every tally. `calc` also reads one
  tally's value or count (`{name}`, `{name:count}`).
- The description says what an MCP result holds, that the command line lists every tally with its state, and that
  tallies change only through the tally tools, which hold the lock on the folder, never by changing files in it.
  It does not describe the files ([ADR-0003](0003-state-in-user-temp-folder.md), amendment of 2026-11-10). It
  informs about the command line and does not tell the agent to run it (ADR-0008).
- `calc`'s errors for a malformed tally reference say to write the full name "as tally_create returned it", no
  longer "or tally_list".

### Consequences

- `tally_list` is within ADR-0008's rule: its MCP result grows only by the digits of its counts.
- An agent that read names or states from `tally_list` over MCP gets counts from abakus 0.5.0 on, a change of the
  result's shape, hence a minor version. The command line prints what `tally_list` returned before, plus the counts.
- Over MCP, only the unknown-name error still names other sessions' tallies: `details.existing` up to 20 names,
  `details.matching` those that start with the name given and `-`, with when each was created.
