# Sums and formulas on the command line

Running abakus in a shell (quoting, exit status, `pipefail`, jq) is in [SKILL.md](SKILL.md).

## Numbers from a file, a log or a pipeline

Run `abakus sum` over the source data instead of copying the numbers into an MCP call: copying is where a line
gets skipped or a digit mistyped, it costs output tokens, and a command can be run again.

```sh
set -o pipefail
sed -nE 's/.*duration=([0-9.]+)ms.*/\1/p' run.log | abakus sum | jq -c 'del(.read)'
# {"total":1653.5,"count":3,"mean":551.166666666667,"mean_exact":false}
tail -n +2 export.csv | cut -d';' -f3 | abakus sum --decimal , | jq -c 'del(.read)'   # skip the header line
abakus sum 410k 1,234.5 -3                  # as arguments; stdin is then ignored
```

- Without arguments, `sum` reads stdin, split at whitespace and line breaks. Every word must be a number: a
  header (`amount`), a unit (`12ms`) or a currency sign is an error that names the word: `numbers[2]` is the
  third, counted from 0.
- `count` is the check: a pipeline that finds nothing gives `{"total":0,"count":0,"mean":null}` with exit
  status 0. Compare it with the number of values you expected.
- Without arguments and without a pipe, `sum` reads the shell's stdin, which may be empty or wait forever: pipe
  the numbers in, or add `</dev/null`.
- Every word is a string, so `read` has one entry per word, 5,000 for 5,000 lines: drop it with jq or `head`.
- `--decimal ,` for numbers like `1.234,5`. When a word reads differently with the other mark (`1,234`) and no
  other word rules that mark out, `notes` gives both readings; if the source writes a decimal comma, run the
  command again with `--decimal ,`. The rules in full: `abakus tools --show sum`.
- To add a sum to a tally as one addition (the count goes up by 1), see [tallies.md](tallies.md#on-the-command-line).

## calc

```sh
abakus calc '{errors-k3f9} / {requests-p2x7} * 100'
abakus calc 'round(1000 * 1.045^10, 2)'
abakus calc -2^2                            # -4: a leading minus belongs to the expression
```

- Single quotes: unquoted, the shell may change the expression or refuse the command before abakus sees it.
- `read` shows the grouping: `abakus calc '2^3^2'` prints `"read":"2 ^ (3 ^ 2)"`.
- Where conventions differ, `notes` says how calc read it and how to write the other reading: `-2^2` is -4, as
  in mathematics (Excel and bc: 4), and `2^3^2` is 2^9 (Excel: (2^3)^2). Parentheses you write settle it. An
  error carries such notes under `details.notes`, since the reading may be what failed: `1/(-2^2+4)` divides by
  zero.
- `{name}` is a tally's value, `{name:count}` its count, by the full name; calc never changes a tally. A
  successful result lists the tallies used under `tallies`: over MCP the first 5 and `tallies_total`, on the
  command line all. An error is the same text on both sides, with at most 5.
