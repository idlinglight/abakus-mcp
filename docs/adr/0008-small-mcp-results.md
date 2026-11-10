# ADR-0008: MCP results stay small; the command line shows everything

Status: accepted, 2026-11-09; amended 2026-11-10 (`abakus call --without-details`; the tools that work on one
tally within the rule, see Scope)

## Context

In the first use of abakus seen outside its own development, an agent added a list of numbers with `sum`. It
passed them as strings, which is natural for numbers copied out of text. The response repeated every string with
its index and its value in `read`, and the person watching saw pages of JSON for one sum. Measured with made-up
numbers, the response is about five times the size of the arguments when they are strings, and it grows with the
list: 20 numbers give 189 bytes in and 934 out; 500 numbers give 4.5 KB in and 22.8 KB out. JSON numbers are not
listed in `read`, so the same list as JSON numbers gives about 45 bytes, however long it is.

What a model expects matters more than the bytes. An agent knows a tool by its name and its description, not
from training, and it calls the tool on the strength of what it expects from the name. A pocket calculator shows
the sum. A first answer that surprises (a page of output for three numbers) may be the last call. The value of
each call is small and habitual: the model already has an estimate of the sum, and the tool replaces it with the
exact figure. A call that costs more than that is not worth making. Whether a long first answer really prevents
a second call has not been measured; the size has, and the decision below rests on that.

Asking for details with a second call (a `verbose` argument) costs most where it hurts. The agent has to decide
before the first call what it will want to know, and the second call writes the whole input again, as output
tokens, which are slow and expensive, and with no guarantee that it is the same call. An optional argument also
adds a decision to every call, even when it is left out, and careful models tend to set such flags "to be
safe".

MCP puts a tool's result into the model's context whole. No revision up to 2026-07-28 has paging or a size limit
for tool results; proposals for them were closed without being merged (in the specification repository: issues
#798 and #2210, SEP-2166 and SEP-2631). Claude Code saves a result to a file only above 50,000 characters (or its
token limit), which `sum` reaches at about 1,100 strings. The output of a shell command, on the other hand, can go
through `jq`, `head` or `grep`, or into a file, before the model reads it: the agent shapes it. abakus has a
command line already, and it prints the same results.

`read` exists because of ADR-0005: "Responses show how each string was read, so a misreading is visible." In
practice the list helps only an agent that already suspects a reading, and that agent can tell from its own
request that it should check: it knows that it passed `"1,234"` or `"410k"`, and the rules are in the
description. An agent that suspects nothing does not scan 500 entries, and the silent case shows nothing anyway:
`"1.234"` meant as 1234 is listed as `{"input": "1.234", "value": 1.234}`. What the list was for is served better
by saying when the server chose between two readings.

Considered and not chosen:

- The details in a file, and a handle to it in the result. A full path dominates a three-number result and is
  hard to overlook; a short code has to be resolved by an agent that does not know where abakus keeps its files.
  After a compaction, a handle is gone, or the model invents one. A check made later goes back to the source data
  anyway, not to abakus's record of it. And a read-only tool would write files.
- MCP's `resource_link`: it needs the resources capability, which ADR-0002 leaves out, and in 2026-07-28 the cache
  fields on every read; clients are not obliged to fetch the link.
- Listing only the strings that are not plain JSON numbers (`"12.50"` is read exactly as `12.50` would be). That
  would have shrunk the observed call to nothing, but the result still grows with a long list of `410k` or of
  numbers written the German way.
- Shorter encodings (no `index`, parallel arrays, `"410k=410000"`): smaller by a constant factor, still growing.
- Cutting the list after a number of entries: the entry that matters may be the one cut.

Before deciding, two probes with fresh agents (Haiku, Sonnet and Opus each, given only the text under test):

- The new `sum` description, with seven tasks that included traps: a German export, US thousands separators that
  trigger the note, a German report read with the default mark, a request to prove how `410k` was read, 300
  numbers in a file. Every trap was handled: the note was ignored for US data and acted on for German data. All
  three read "to see how one string is read, sum it alone" as an invitation to check strings one by one, guessed
  how the command line takes its input, and one wondered whether JSON numbers pass through binary floating point;
  the description now answers each.
- The rule below, with every tool's result shape, to sort into within and outside. All three gave the same verdict
  for every tool, and all three found what the first draft of this record had missed: the tools that work on one
  tally repeat every threshold, an `at` threshold with all its marks. They differed where the draft was silent:
  whether stored state counts like input, whether a list of a fixed length plus a count is allowed, whether an
  echo of the input belongs to the answer, and lists that grow with the size of a value. The rule now says.

## Decision

### Small results

A successful MCP result grows at most logarithmically with the amount of input (the number of items in a list, of
characters in an expression) and with the stored state it reports on (the number of tallies, the thresholds a tally
keeps), and stays within a few hundred characters. The size of one value is fixed by abakus's number rules (38
significant digits, below 10^165, no digits below 10^-128), or by a limit a tool states for one value (calc's
`fraction`: at most 100 digits above and below the line), and is not growth. A count, which takes log n digits, is
allowed. A list is allowed when it holds at most a fixed number of entries, followed by a count when there are
more, whatever would make it long: more input, more stored state, or a larger value (crossings of an `every`
threshold: at most 10 marks, then a count). A list with an entry for every input item is not.

The result holds the answer the tool's name promises, plus what keeps that answer from misleading: a mark when it
was rounded (`exact: false` and its kin, as before), and a note when the server chose one of two readings of an
input. An echo of the input is not part of the answer: the agent has its request. Where a reading involved a
choice, a note says so; any other reading the agent asks for, with a call on that part alone or on the command
line.

Errors are bounded too. They quote at most 100 characters of an input, cut in the middle with `…`, and list at most
a fixed number of names (the tally errors list 20, as before).

Why logarithmic, when every value is capped: a request line is at most 16 MiB (ADR-0002), so a `sum` call has at
most 8,388,608 items and its count at most 7 digits; everything a result holds is bounded in practice. But with the
amount of input capped, a list per item would be bounded too, and the rule could no longer tell it from a count.
So the rule keeps the amount of input unbounded and fixes only the size of a value. The few hundred characters are
the practical check; the growth rule says what does not belong in a result at all.

### The command line shows everything

- A tool's result in the core holds everything abakus knows about the call. Keys that grow with the input are the
  tool's details (`Tool.detailKeys`): the MCP server leaves them out, the command line prints them. The behaviour
  stays in the core; each side chooses what it shows. One exception, amended 2026-11-10: `abakus call
  --without-details` prints a result as the server sends it (see Consequences).
- The command line takes numbers as arguments or from stdin, so a check can be a command that runs again over the
  source data (`grep -oE '…' build.log | abakus sum`), and its output can go through `jq` or `head` or into a file.
- The tool descriptions say that the command line exists and what it adds. They do not tell an agent to run it: a
  tool server's text that asks for shell commands reads like the instructions careful agents distrust.
  Instructions for using the command line, if any, belong in the user's own channel, a skill (see Scope).

### sum

- Over MCP: `total`, `count`, `mean` and the `*_exact` flags, as before, and `notes` when a string reads
  differently with the other decimal mark. Like date_diff's `notes` (ADR-0006), it is a list of strings; here it
  holds one note of fixed size, whatever the number of such strings: how many there are, the first one with its
  index, both readings, and what to do:
  `"1,234" (numbers[2]) was read as 1234; with decimal: "," it would be 1.234. If the numbers use a decimal comma,
  call again with decimal: ","`. Calling again sends the input again, but only after the server chose a reading
  that may be wrong: that is a correction, not a call made only to check.
- A string reads differently with the other decimal mark when it contains `.` or `,` and the other `decimal`
  setting reads it as well. The two values then always differ: in one reading the mark is the decimal mark, in the
  other it groups thousands (and grouping excludes a leading 0, so `0.000` is not a case).
- No note when another string in the list rules the other mark out, by containing a mark that only the current
  setting reads (`"12.50"` or `"1,234.5"` with `.`): it shows how the list is written, and calling again with the
  other mark would fail on it. Found in review.
- `read` is a detail: the command line prints it, as before.
- The description says that strings following the rules need no checking, and how to check a single string
  anyway: sum it alone, `{"numbers": ["410k"]}`.

### Scope

- Now: `sum`, and the errors of every tool that quote an input (number strings, JSON number literals, calc's
  numbers, dates, tally names, unknown argument names).
- `date_diff` is within the rule: its input is two instants, and every key it returns is bounded.
- Amended 2026-11-10: the tools that work on one tally (`tally_create`, `tally_add`, `tally_set`, `tally_drop`)
  are within the rule, no longer a known exception ([ADR-0004](0004-tallies.md), amendment of 2026-11-10). An `at`
  threshold shows how many marks it has, how many are reached and the next one; `crossed` lists at most 10 marks
  per threshold, then a count; a tally keeps at most 5 thresholds; `read` is a detail, with the decimal note of
  `sum` in its place. The exception also said that an error for an unknown name lists whole tallies in
  `details.matching`: it lists only each one's name, value, count and created time, and always did.
- Known exceptions, each to be brought within the rule when it is next changed:
  - `calc`: `read` grows with the expression and `tallies` with the tallies it names. ADR-0007's reasoning about
    `-2^2` relies on `read` being visible; the replacement would be notes for the known traps, and `tallies` could
    become a list of a fixed length plus a count.
  - `tally_list` grows with the number of tallies, other sessions' included, which the caller does not control.
    A direction: the folder and what is in it, plus a count. The files would become an interface that agents read,
    and the description would have to say that tallies change only through the tally tools, which hold the lock.
- A skill for the command line, user-level and installed on request, with its source in this repository: open.

## Consequences

- This amends ADR-0005's "Responses show how each string was read": over MCP, a reading shows in a note when it was
  a choice; the command line shows every reading.
- `abakus call` prints the full result, not exactly what an MCP client gets. Amended 2026-11-10: `abakus call
  --without-details` leaves out the detail keys as the server does (`Tool.withoutDetails`), so the size of an MCP
  result can be checked without speaking JSON-RPC. It is a flag of the command line, not a tool argument, so the
  reasoning against a `verbose` argument above does not apply; the other commands print everything, as decided.
- `dev/check.zsh` checks both sides: no `read` over MCP, `read` on the command line.
- Claude Code's session transcripts record every abakus call, so calls per session can be compared before and
  after this change.
- abakus 0.4.0 is the first version with this rule. An agent that read `sum`'s `read` over MCP no longer gets it.
