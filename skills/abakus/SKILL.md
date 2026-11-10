---
name: abakus
description: >-
  Tallies, exact sums and formulas with abakus, over MCP and on its command line. Use it when working through a
  list or a batch with a budget, a checkpoint every N items, milestones or anything else that has to survive a
  context compaction, or to understand tallies (thresholds, finding one again, correcting one); when numbers in
  a file, a log or a command's output are to be added; when you want what an abakus MCP result leaves out; and
  before running abakus in a shell. Not for a single sum, calculation, date difference or tally change that an
  abakus MCP tool answers: call the tool. Only the command-line parts need the `abakus` binary on PATH.
---

# abakus

abakus keeps tallies and works out sums, formulas and date differences exactly. It is one program: `abakus mcp`
is the MCP server the abakus tools come from; its other commands run the same tools in a shell, on the same
tallies, and print the JSON an MCP client gets plus what an MCP result leaves out to stay small.

## Topics

Each file stands on its own; read the one you need.

- [tallies.md](tallies.md), for working through a list with tallies, or a tally result that needs explaining:
  what tallies are for, thresholds, shapes (budgets, checkpoints, milestones), finding a tally after a
  compaction, correcting one, over MCP and on the command line.
- [calc-sum.md](calc-sum.md), for adding numbers from a file, a log or a pipeline, or calc in a shell: recipes,
  `count` as the check, decimal commas, quoting, grouping, notes where conventions differ, tallies in a formula.

## When the command line is the better way

- **Numbers in a file or from a pipeline**: a command over the source data, instead of copying them into an MCP
  call.
- **What an MCP result leaves out**: how each number string was read and how calc grouped (`read`), all the
  marks of an `at` threshold, every tally a calc used, every tally with its state (`abakus tallies info`).
- **Shaping output** with `jq` or `head`, or into a file in a scratch folder, before you read it.
- **Exactly what an MCP client gets**: `abakus call --without-details <tool> '<json>'`.
- **No abakus MCP tools in this session**: the command line does everything they do.

## When not

- A single sum, calculation, date difference or tally change that an MCP call answers needs no shell.
- Don't run the command line to double-check an MCP result that needs no checking. A note in a result (`notes`,
  `note`) is the signal that something deserves a look, and it says what to do.

## Running abakus in a shell

If `abakus` is not found, try `~/.local/bin/abakus`; if that is missing too, use the MCP tools or tell the user.

```sh
abakus tools --show calc                    # a tool's description and schema, as over MCP; tools lists all
abakus date-diff 2026-11-08T14:30:00+01:00 2027-01-20
abakus date-diff 2026-01-01                 # until now
abakus call sum '{"numbers": ["1.234,5", 8], "decimal": ","}'
jq -nc '{numbers: [range(1; 501)]}' | abakus call sum -        # the JSON from stdin
```

- Every command has `--help`. `abakus mcp` is for an MCP client to start, not for a shell.
- Single quotes around JSON and calc expressions: braces, `*`, `^`, `(` and spaces mean something to the shell.
  A leading `-` is no option: `abakus sum 5 -3`, `abakus calc -2^2`.
- `call` runs a tool by its MCP name, for real (`tally_drop` deletes), and prints the full result;
  `--without-details`, only on `call`, leaves out what the server leaves out.
- Success: one line of JSON on stdout, exit status 0. A tool's error: `Error: …`, then `Details: {…}` if any, on
  stderr, exit status 1. A usage mistake: the error and the usage, exit status 64.
- An error leaves a `jq` after it without input: `set -o pipefail` makes the pipeline fail.
- jq computes in binary floating point: let it select and shape, never add or round. jq before 1.7
  (`jq --version`) also rounds long numbers when it prints them; then keep abakus's numbers out of it, as in
  `… | jq -Rnc '{numbers: [inputs]}' | abakus call --without-details sum -` (numbers in as strings, sum out).

## Notes and errors are written in MCP terms

They are the same text on both sides. Rows for tallies and `sum` are in the topic files.

| In a note or an error | On the command line |
|---|---|
| `sum`, `calc`, `date_diff` | `abakus sum`, `abakus calc`, `abakus date-diff` |
| `tally_create`, `tally_add`, `tally_set`, `tally_drop` | `abakus tally create`, `… add`, `… set`, `… drop` |
| `tallies_info` | `abakus tallies info` |
| `name`, `amount`, `expression`, `from`, `to`, `prefix` | arguments: `abakus tally add <name> <amount>` |
| `decimal: ","` | `--decimal ,` |
| a JSON call: `tally_set {"name": "b-p2x7", "value": 2}` | `abakus call tally_set '<the JSON>'`, or `abakus tally set b-p2x7 --value 2` |

## State

The command line sees the same tallies as the MCP server. Tallies change only through abakus, which holds the
lock on their folder: never edit, create or delete files there. More in [tallies.md](tallies.md).
