# ADR-0008: MCP results stay small; the command line shows everything

Status: proposed, 2026-11-09 (draft for discussion)

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

## Decision

### Small results

A successful MCP result grows at most logarithmically with the amount of input (the number of items in a list, of
tallies, of characters in an expression) and stays within a few hundred characters. The size of one value is
fixed by abakus's number rules (38 significant digits, below 10^165, no digits below 10^-128) and is not growth.
A count of the input, which takes log n digits, is allowed; anything listed per input item is not.

The result holds the answer the tool's name promises, plus what keeps that answer from misleading: a mark when it
was rounded (`exact: false` and its kin, as before), and a note when the server chose one of two readings of an
input.

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
  stays in the core; each side chooses what it shows.
- The command line takes numbers as arguments or from stdin, so a check can be a command that runs again over the
  source data (`grep -oE '…' build.log | abakus sum`), and its output can go through `jq` or `head` or into a file.
- The tool descriptions say that the command line exists and what it adds. They do not tell an agent to run it: a
  tool server's text that asks for shell commands reads like the instructions careful agents distrust.
  Instructions for using the command line, if any, belong in the user's own channel, a skill (see Scope).

### sum

- Over MCP: `total`, `count`, `mean` and the `*_exact` flags, as before, and `notes` when a string reads
  differently with the other decimal mark. Like date_diff's `notes` (ADR-0006), it is a list of sentences; here it
  has one, of fixed size, whatever the number of such strings: how many there are, the first one with its index,
  both readings, and what to do:
  `"1,234" (numbers[2]) was read as 1234; with decimal: "," it would be 1.234. If the numbers use a decimal comma,
  call again with decimal: ","`. Calling again sends the input again, but only after the server chose a reading
  that may be wrong: that is a correction, not a call made only to check.
- A string reads differently with the other decimal mark when it contains `.` or `,` and the other `decimal`
  setting reads it as well. The two values then always differ: in one reading the mark is the decimal mark, in the
  other it groups thousands (and grouping excludes a leading 0, so `0.000` is not a case).
- `read` is a detail: the command line prints it, as before.
- The description says how to check a single string: sum it alone, `{"numbers": ["410k"]}`.

### Scope

- Now: `sum`, and the errors of every tool that quote an input (number strings, dates, tally names, unknown
  argument names).
- `calc` follows the same rule when it is next changed: `read` and `tallies` grow with the expression. Until then
  they stay in its MCP result. ADR-0007's reasoning about `-2^2` relies on `read` being visible; the replacement
  would be notes for the known traps.
- `tally_list` grows with the number of tallies, other sessions' included, which the caller does not control.
  Open: return the folder and what is in it instead. The files would become an interface that agents read, and
  the description would have to say that tallies change only through the tally tools, which hold the lock.
- A skill for the command line, user-level and installed on request, with its source in this repository: open.
- `date_diff` and the tools that work on one tally are within the rule already.

## Consequences

- This amends ADR-0005's "Responses show how each string was read": over MCP, a reading shows in a note when it was
  a choice; the command line shows every reading.
- `abakus call` prints the full result, not exactly what an MCP client gets.
- `dev/check.zsh` checks both sides: no `read` over MCP, `read` on the command line.
- Claude Code's session transcripts record every abakus call, so calls per session can be compared before and
  after this change.
