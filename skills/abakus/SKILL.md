---
name: abakus
description: >-
  How and when to run the abakus command line, the shell side of the abakus MCP tools (needs the `abakus`
  binary on PATH). Use it to add numbers that sit in a file, a log or the output of another command
  (`sed … run.log | abakus sum`) instead of copying them into an MCP call; to see what an abakus MCP result
  leaves out (how each number string was read, how calc grouped an expression, every tally with its state); to
  shape abakus output with jq or head; and whenever you are about to run abakus in a shell: quoting, stdin,
  flags, exit codes, and how notes written in MCP terms map to options. Not for a single sum, calculation, date
  difference or tally change that an abakus MCP tool answers: call the tool.
---

# abakus on the command line

`abakus` is one program. `abakus mcp` is the MCP server the abakus tools come from; the other commands run the
same tools in a shell. Each command prints the JSON an MCP client gets, plus what an MCP result leaves out to stay
small. Same tallies, same number rules, same errors.

If the shell says `abakus: command not found`, try `~/.local/bin/abakus`, where abakus's `install.zsh` puts it.
If that is missing too, abakus is not installed: use the MCP tools, or tell the user.

## When the command line is the better way

- **Numbers in a file or from a pipeline.** Run the command over the source data instead of copying the numbers
  into an MCP call. Copying is where a line gets skipped or a digit mistyped, it costs output tokens, and a
  command can simply be run again:

  ```sh
  set -o pipefail                           # so that an abakus error fails the pipeline, not only jq's output
  sed -nE 's/.*duration=([0-9.]+)ms.*/\1/p' run.log | abakus sum | jq -c 'del(.read)'
  # {"total":1653.5,"count":3,"mean":551.166666666667,"mean_exact":false}
  ```

  This needs jq 1.7 or later (`jq --version`); see [Output and exit status](#output-and-exit-status) for an
  older one.

- **What an MCP result leaves out.** The command line also prints:
  - `read` of `sum` and of the tally tools: how each number string was read, as `{"input", "value"}` (with
    `"index"` for `sum`).
  - Every mark of an `at` threshold, under `marks`, in the tally commands and `abakus tallies info`; an MCP result
    shows `marks_total`, `passed` and the next 5 under `ahead`.
  - `read` of `calc`: the expression as calc understood it, with parentheses that show the grouping; and every
    tally the expression used, where an MCP result lists the first 5 and then `tallies_total`. This is for a
    successful result: a calc error is the same text on both sides and lists at most 5 tallies.
  - `abakus tallies info`: every tally with its full state (`tallies`), and each tally file that cannot be read,
    with what is wrong (`unreadable`). Over MCP, `tallies_info` only counts them.
- **Shaping output before you read it**, with `jq` or `head`, or into a file in a scratch folder. A sum over 5,000
  log lines has 5,000 entries in `read`.
- **Seeing exactly what an MCP client gets:** `abakus call --without-details <tool> '<json>'`.
- **No abakus MCP tools in this session:** the command line does everything the tools do.

## When not

- A single sum, calculation, date difference or tally change that an MCP call answers needs no shell. Call the
  tool.
- Don't run the command line to double-check an MCP result that the tool's description says needs no checking,
  such as a total of number strings that follow the rules. A note in an MCP result (`notes` or `note`) is the
  signal that something deserves a look; it says what to do, and the command line can show the details.

## Commands

Every command has `--help`. `abakus tools` lists the tools; `abakus tools --show calc` prints one tool's full
description and input schema, the same text the MCP tool has. `abakus --version` prints the version.
`abakus mcp` is the server, for an MCP client to start; don't run it in a shell.

### sum

```sh
abakus sum 410k 1,234.5 -3                  # numbers as arguments; negative numbers are fine
abakus sum --decimal , 1.234,5 12,5         # numbers with a decimal comma
printf '%s\n' 12.5 7 3 | abakus sum         # no arguments: the numbers come from stdin
set -o pipefail
tail -n +2 export.csv | cut -d';' -f3 | abakus sum --decimal , | jq -c 'del(.read)'   # skip the header line
```

- Without arguments, `sum` reads stdin and splits it at whitespace and line breaks. Every word must be a number:
  a header (`amount`), a unit (`12ms`) or a currency sign is an error that names the word, such as `numbers[0]`.
- With arguments, stdin is ignored.
- A pipeline that finds nothing gives `{"total":0,"count":0,"mean":null}` with exit status 0: compare `count`
  with the number of values you expected. Without arguments and without a pipe, `sum` reads the shell's stdin,
  which may be empty or may wait forever: pipe the numbers in, or add `</dev/null`.
- Every word is a string, so `read` lists each one.

### calc

```sh
abakus calc '{errors-k3f9} / {requests-p2x7} * 100'
abakus calc 'round(1000 * 1.045^10, 2)'
abakus calc '(-2)^2'                        # 4
abakus calc -2^2                            # -4: a leading minus belongs to the expression
```

- Put the expression in single quotes. Braces, `*`, `^`, `(` and spaces mean something to the shell: unquoted,
  the shell may change the expression or refuse the command before abakus sees it.
- A leading `-` is part of the expression, not an option.
- `read` shows the grouping: `abakus calc '2^3^2'` prints `"read":"2 ^ (3 ^ 2)"`.

### Tallies

```sh
abakus tally create review --limit 20 --every-count 5   # prints the name to use, with a suffix: review-k3f9
abakus tally add review-k3f9                # adds 1
abakus tally add review-k3f9 6              # one amount; negative amounts too: -2
abakus tally set review-k3f9 --value 12 --count 4
abakus tally set review-k3f9 --at 100 --at 200 --every-count 10   # replaces all thresholds
abakus tally set review-k3f9 --clear-thresholds
abakus tally drop review-k3f9
abakus tallies info                         # every tally with its state, sorted by name
abakus tallies info review                  # only tallies whose names start with "review"
```

- Thresholds on the value: `--limit n` (a ceiling), `--at n` (a mark; repeat it for more marks, which make one
  threshold), `--every n` (a period). On the count: `--limit-count`, `--at-count`, `--every-count`. At most 5
  thresholds in all. On `tally set`, threshold options replace all thresholds.
- `--shared` uses the name exactly, for a tally several sessions are meant to add to. Without it, the name gets
  a random suffix: use the name the command printed.
- `--decimal ,` works here too, for numbers written with a decimal comma.
- `tally add` takes one amount. For many numbers, sum them first (`… | abakus sum`), check its `count`, then add
  the `total`.

### date-diff

```sh
abakus date-diff 2026-11-08 2027-01-20
abakus date-diff 2026-11-08T14:30:00+01:00 now
abakus date-diff 2026-01-01                 # until now
```

### call

```sh
abakus call sum '{"numbers": ["1.234,5", 8], "decimal": ","}'
jq -nc '{numbers: [range(1; 501)]}' | abakus call sum -        # the arguments from stdin
abakus call --without-details tallies_info '{"prefix": "review"}'
```

- `call` runs any tool by its MCP name (`abakus tools` lists them) with JSON arguments, as an MCP client sends
  them, and prints the full result.
- `--without-details` leaves out what the MCP server leaves out, so a successful result is exactly the text an
  MCP client gets. Only `call` has this option.
- `call` runs the tool for real: `tally_add` adds, `tally_drop` deletes.
- Put the JSON in single quotes. With `-` instead, `call` reads the JSON from stdin, which avoids quoting trouble
  when it is long or made by another command.

## Output and exit status

- Success: one line of JSON on stdout, exit status 0.
- A tool's error: nothing on stdout. On stderr `Error: <message>`, then `Details: {…}` when there are details,
  exit status 1. It is the same text an MCP client gets.
- A usage mistake (an unknown option, a missing argument): `Error: …` and the command's usage on stderr, exit
  status 64.
- In a pipeline into `jq`, an error leaves jq without input and shows only on stderr. Use `set -o pipefail`, so
  the pipeline fails, or run the command alone to read the message.
- jq computes in binary floating point. Use it to select and shape, never to add or round: leave the arithmetic
  to abakus. jq before 1.7 (`jq --version`) also rounds long numbers when it prints them, `total` included. With
  such a jq, keep abakus's numbers out of it: `… | jq -Rnc '{numbers: [inputs]}' | abakus call --without-details sum -`
  turns one number per line into JSON strings and prints the sum without `read`, as abakus wrote it.

## Notes and errors are written in MCP terms

A note or an error has the same text on both sides, so it speaks of tool names and JSON arguments. On the command
line:

| In a note or an error | On the command line |
|---|---|
| `sum`, `calc`, `date_diff` | `abakus sum`, `abakus calc`, `abakus date-diff` |
| `tally_create`, `tally_add`, `tally_set`, `tally_drop` | `abakus tally create`, `abakus tally add`, `abakus tally set`, `abakus tally drop` |
| `tallies_info` | `abakus tallies info` |
| `name`, `amount`, `expression`, `from`, `to`, `prefix` | the command's arguments: `abakus tally add <name> <amount>`, `abakus date-diff <from> <to>` |
| `decimal: ","` | `--decimal ,` |
| `shared: true` | `--shared` |
| `value`, `count` of `tally_set` | `--value`, `--count` |
| `thresholds: []` | `--clear-thresholds` |
| `{"limit": 20}`, `{"at": [100, 200]}`, `{"every": 5}` | `--limit 20`, `--at 100 --at 200`, `--every 5` |
| the same with `"of": "count"` | `--limit-count`, `--at-count`, `--every-count` |

- A JSON call in a note runs as it stands with `call`, or can be written with options:
  `tally_set {"name": "bytes-p2x7", "value": 26.234}` is
  `abakus call tally_set '{"name": "bytes-p2x7", "value": 26.234}'` or
  `abakus tally set bytes-p2x7 --value 26.234`.
- `numbers[2]` is the third number, counted from 0: the third argument, or the third word on stdin.
- `thresholds[1].at[0]`: the thresholds given count from 0 in this order, whatever order the options came in:
  `--limit`, `--limit-count`, `--at`, `--at-count`, `--every`, `--every-count`. With
  `--every-count 5 --at 1,500 --limit 20`, it is the first `--at` mark.
- A note that says to replace the thresholds with tally_set, passing them again with `decimal: ","`, means: run
  `abakus tally set <name>` with all threshold options again, plus `--decimal ,`.

## State

- The command line sees the same tallies as the MCP server: a tally created over MCP can be added to here, and
  the other way round.
- Tallies change only through abakus, a command or an MCP tool, which holds the lock on their folder. Never edit,
  create or delete files in that folder, and don't rely on their format: it is internal and may change. To see a
  tally, use `abakus tallies info` or `abakus calc '{review-k3f9}'`.
- `abakus tallies info` shows the tallies of every session. Reading them is fine; change or drop only tallies you
  created, or shared ones you coordinate on.
- Don't set `ABAKUS_STATE_DIR` except in tests: it points abakus at another folder, and tallies there are
  invisible to the MCP server and to other sessions.
