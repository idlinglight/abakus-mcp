# Tallies

Over MCP and on the command line. Running abakus in a shell is in [SKILL.md](SKILL.md).

## What a tally is for

A tally is a named, exact `value` (the sum of what was added) and a `count` (how many additions), with `created`
and `updated` times, kept in a file outside your context. A running total carried in the conversation gets
copied wrong or lost in a compaction; a tally keeps it.

- `tally_create` appends a random suffix (`review` becomes `review-k3f9`), so each session counts its own: use
  the name it returns. It always makes a new tally, also for a name that exists (then with a `note`).
- `tally_add` continues a tally: it adds 1, or an amount (a negative one subtracts). Every addition counts.
- `shared: true` takes the name exactly, for a tally several sessions add to; refused if the name exists.
- All sessions of the user see the same tallies: change or drop only yours, or shared ones you coordinate on.
- A tally unchanged for about three days disappears; an unknown name is an error, never a new tally.

## Thresholds

At most 5, each with one of `limit` (a ceiling), `at` (marks, any number) or `every` (each multiple), on the value
or, with `"of": "count"`, the count: `[{"limit": 20}, {"every": 5, "of": "count"}]`.

- An addition crosses a mark, or a `limit`, when it takes the tally from below it to it or past it: upward only.
  After the tally went back below it, by `tally_set` or a negative amount, the next addition that reaches it
  reports it again.
- `crossed`, in `tally_add`'s response, lists what the addition crossed (`[]` if nothing):
  `{"limit": 20, "of": "value"}`, `{"every": 5, "of": "count", "at": [5]}`; past 10 marks of one threshold,
  `times`, `first` and `last`.
- Every response gives each threshold's status. `limit`: `reached`, and `remaining` or `over`. `every`: `next`.
  `at`: `marks_total`, how many are `passed`, the marks `ahead` (at most 5), and on the command line all of them
  (`marks`).
- Thresholds inform and never block an addition.
- A sixth threshold is an error: one `at` takes any number of marks, and a second tally can watch more.

## Shapes for working through a list

- **A budget**: a `limit` on the value, each item's effort in points as the amount. `remaining` shows what is
  left; the addition that reaches the limit lists it in `crossed`.
- **A checkpoint every N items**: `every` on the count, one `tally_add` per item. The addition whose `crossed`
  lists it is the moment to stop and check the last N items.
- **Milestones**: `at` marks, on the value or the count.
- **Both on one tally**: points as the value, items as the count: `[{"limit": 40}, {"every": 5, "of": "count"}]`.
- **One tally per measure** when they count different things, such as comment lines and items; `calc` relates
  them: `{lines-k3f9} / {items-p2x7}`.

The tally holds the numbers; your notes say what each threshold stands for.

## Getting back after a compaction

- The name, suffix included, is in `tally_create`'s response: keep it in your notes. Any later response shows
  where the tally stands and what comes next.
- Lost: `calc` with the name as you gave it (`{review}`) never writes; its error lists the tallies named `review`
  plus a suffix, each with when it was created, to compare with when you created yours. (A shared tally named
  exactly `review` gives its value instead.) `abakus tallies info` lists every tally, or those with a prefix,
  with its state and every mark.
- `tally_add` or `tally_drop` with a guessed name would change a shared tally of that name. If you cannot tell
  which is yours, a new tally loses your count, which is better than adding to another session's.

## Correcting

- `tally_set` sets the `value`, the `count`, or replaces all `thresholds` (`[]` removes them), and reports no
  crossings: it corrects, it does not make progress.
- A negative amount that takes back an addition counts as one more addition, which shifts a checkpoint on the
  count; `tally_set` does not.
- A number string that reads differently with the other decimal mark (`"1,234"`) gets a note under `notes`. After
  `tally_add` the addition has counted, so the note gives the `tally_set` call that keeps the count, and
  `crossed` followed the reading used. After `tally_create`: fix the thresholds with `tally_set`; creating again
  makes a second tally.

## On the command line

```sh
abakus tally create review --limit 20 --every-count 5   # prints the name to use: review-k3f9
abakus tally add review-k3f9 6              # one amount, 1 if none; negative too: -2
abakus tally set review-k3f9 --value 12 --count 4
abakus tally set review-k3f9 --at 100 --at 200 --every-count 10   # replaces all thresholds
abakus tally drop review-k3f9
abakus tallies info review                  # tallies whose names start with review
abakus calc '{review-k3f9:count}'           # its count; {review-k3f9} is its value
```

Repeated `--at` make one threshold. The tally commands take `--decimal ,` for numbers with a decimal comma. For
many numbers, `… | abakus sum`, check its `count`, and add the `total`: one addition, so the count goes up by 1.

Every command prints one line of JSON; `abakus tallies info review`, wrapped and shortened:

```json
{"folder": "/var/folders/…/T/abakus/tallies", "tallies_found": 1,
 "tallies": [{"name": "review-f9q3", "value": 24, "count": 12,
              "thresholds": [{"limit": 40, "of": "value", "reached": false, "remaining": 16},
                             {"marks_total": 7, "of": "count", "passed": 1, "ahead": [20, 30, 40, 50, 60],
                              "marks": [10, 20, 30, 40, 50, 60, 70]}, …],
              "created": "2026-11-10T18:27:07Z", "updated": "2026-11-10T18:27:07Z"}]}
```

| In a note or an error | On the command line |
|---|---|
| `shared: true` | `--shared` |
| `value`, `count` of `tally_set` | `--value`, `--count` |
| `{"limit": 20}`, `{"at": [1, 2]}`, `{"every": 5}` | `--limit 20`, `--at 1 --at 2`, `--every 5` |
| the same with `"of": "count"` | `--limit-count`, `--at-count`, `--every-count` |
| `thresholds: []` | `--clear-thresholds` |

`thresholds[1].at[0]`: thresholds count from 0 in this order, whatever the order of the options: `--limit`,
`--limit-count`, `--at`, `--at-count`, `--every`, `--every-count`.

## State

- abakus locks the tallies' folder for every read and change. The files and their format are internal: never
  edit, create or delete them, and don't rely on what is in them.
- `tallies_info` over MCP gives the folder and how many tallies there are; `abakus tallies info` adds every
  tally with its state (`tallies`) and each unreadable one with what is wrong (`unreadable`).
