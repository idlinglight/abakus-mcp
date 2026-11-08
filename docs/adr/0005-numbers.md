# ADR-0005: Numbers: exact decimals, read by stated rules

Status: accepted, 2026-11-08; amended 2026-11-08 (see the end); amended 2026-11-08 (the rules in full in
`sum`'s description only)

## Context

Exactness is the point of a calculator. Doing the arithmetic in its head, an agent gets numbers wrong, and the
ready-made tools have traps of their own: `bc` divides with zero decimal places unless told otherwise
(`(17+19)/5` prints 7), and binary floating point turns `0.1 + 0.2` into `0.30000000000000004`. Swift's
`JSONDecoder` reads every JSON number as a `Double`.

Numbers often come from text that agents or programs wrote: `410k`, `1,234.5`, `123.456`. The last one is
123.456 to most programs and 123456 to a German reader. Guessing is how the error gets in.

## Decision

- Arithmetic uses Foundation's `Decimal` (38 significant digits). A result that had to be rounded says so
  (`exact: false`); nothing is rounded silently. Overflow is an error.
- JSON numbers are read from their literal text ([ADR-0002](0002-own-mcp-server.md)), never through `Double`.
- Every number argument accepts a JSON number or a string. Strings are read by fixed rules, stated in the
  tool descriptions:
  - the decimal mark is `.`, or `,` when the call passes `decimal: ","`;
  - the other mark may group thousands, in groups of three only (`1,234,567.5`);
  - an optional sign, and an optional exponent (`2.5e3`);
  - an optional suffix: `k` or `K` (thousand), `M` (million), `G` (billion), `T` (trillion); a lowercase
    `m` is refused, since it could mean milli;
  - whitespace around the number is ignored. Anything else (units, currency signs, `%`) is an error that
    names the input.
- Responses show how each string was read (`"410k"` as 410000), so a misreading is visible.
- Numbers in responses are JSON numbers in plain notation, without an exponent.

## Consequences

- An agent reading numbers written the German way has to say so (`decimal: ","`). If it doesn't, `1,234`
  reads as 1234, and the response shows it.
- New suffixes or separators amend this ADR and the tool descriptions together.

## Amendment, 2026-11-08: rounding, and the reading rules in detail

### Context

Foundation's `NSDecimalAdd`, `NSDecimalSubtract`, `NSDecimalMultiply` and `NSDecimalDivide` turned out to be
unusable for "nothing is rounded silently". Compared with exact results on random operands (macOS 27), they
truncate instead of rounding (`2 / 3` ends in …666), keep 38 or 39 digits depending on the value and as few as
about 30 in some divisions, rarely report the loss, miss overflow and underflow in multiplication because the
exponent wraps around (`1e-100 × 1e-100` returns `1e56` without an error), and report underflow for some
quotients that fit. `Decimal(string:)` silently truncates digits beyond the 38th or 39th.

The rules above also left cases open: `.5`, `5.`, `+5`, `-0`, the Unicode minus sign, a space before a suffix,
a suffix together with an exponent, and numbers outside what a `Decimal` holds.

### Decision

Arithmetic:

- `DecimalMath` computes every result exactly (a small arbitrary-precision integer for the significands) and
  rounds once, half away from zero (Foundation's `.plain`, commercial rounding), to 38 significant digits.
  Results that need digits below 10^-128 are rounded there. `exact` is false exactly when something was
  dropped.
- Errors: division by zero; results of about 10^165 or more (overflow); non-zero results that round to zero
  (underflow).
- `DecimalMath.sum` adds exactly and rounds only the total: no intermediate step rounds or overflows.
- Readable results: values shown to people rather than computed with further, such as the mean of `sum` or
  the totals of `date_diff` ([ADR-0006](0006-date-differences.md)), follow one policy, implemented once
  (`DecimalMath.readableQuotient` and the internal helper the tools call). Such a value is exact when it fits
  38 significant digits; otherwise it is rounded half away from zero to 15 significant digits, or to whole
  units when its integer part has more than 15 digits (38 digits at most), and flagged with `exact: false`
  (`mean_exact`, `days_exact`, …). 1/3 is 0.333333333333333; 1/3,000,000 is 0.000000333333333333333;
  10^20/3 is 33333333333333333333. Significant digits instead of a fixed number of decimal places, because a
  fixed number of places turns a small non-zero value into 0 (the mean of three million numbers summing to 1
  at six places), while 15 digits stay readable and are far more than any input of a mean or a date
  difference supports. A non-zero value never becomes 0 and never loses its sign: below 10^-128, where
  Decimal's digits end, it is an underflow error.
- Rounding to decimal places, for tools that need a whole number or a fixed precision (tally thresholds,
  `floor(value / period)`): `DecimalMath.rounded(_:toPlaces:_:)`, `divide(_:_:toPlaces:_:)` with the modes
  down (floor), up (ceiling), toward zero and half away from zero, plus `floor(_:)` and `isInteger(_:)`. They
  are exact: `divide(a, b, toPlaces: 0, .down)` is the floor of the exact quotient, never of a quotient
  rounded to 38 digits first. Places run from -165 to 128; a result with more than 38 significant digits is
  an error. Here a result of 0 is a result: the caller chose the places.
- Foundation's `Decimal` remains the storage type and the source of the plain-notation output; its
  arithmetic functions, its rounding (`NSDecimalRound`) and its string parser are not used.

Reading (`NumberReader`):

- JSON numbers must match the JSON grammar (RFC 8259). The `decimal` argument does not apply to them: a JSON
  number always uses `.`.
- Accepted in strings, in addition to the rules above:
  - `.5` (and `,5` with `decimal: ","`): a leading decimal mark is common and unambiguous.
  - `+5`, and `−` (U+2212, the typographic minus) as a minus sign, also in the exponent.
  - `-0`, read as 0.
  - Leading zeros (`007`), except in a grouped number.
- Refused, each with an error that names the input, says what is wrong and what is accepted:
  - `5.`: a decimal mark must be followed by digits. A trailing mark is more often a sentence's full stop or a
    cut-off number than a way to write 5.
  - Grouped numbers starting with 0 (`0,123` with `.` as the decimal mark): almost certainly a decimal comma.
  - A grouping mark after the decimal mark (`1.5,3`), more than one decimal mark (`1.234.567` with `.`). The
    error suggests the other `decimal` setting where that would read the input.
  - A space before a suffix (`410 k`): with a space, a letter reads like a unit (`300 K` is a temperature).
  - A suffix together with an exponent (`1e3k`): never meant, and easy to misread.
  - Any whitespace inside the number (`1 234`), other digits than ASCII 0–9, other dashes (`–5`).
  - Values a `Decimal` cannot hold exactly: more than 38 significant digits, 10^165 or more (`1e400`), or
    digits below 10^-128 (`1.5e-128`). Input is never rounded. Trailing zeros are not significant digits:
    `1` followed by 50 zeros is 10^50 and fine.
- `NumberReader.rulesSummary` states the rules in two sentences, in `sum`'s description. Tools that take a
  number or two besides other things (the tallies) carry `NumberReader.rulesInBrief` instead, one sentence
  with examples that says an unreadable number is an error that says why, and points to `sum`'s
  description: the full rules once in the tool list are enough ([ADR-0004](0004-tallies.md), amendment on the
  default suffix). Every error about a number string, the range errors included, also lists the accepted
  forms; errors about JSON literals and wrong types say only what is wrong. `DecimalMark.argument` and
  `DecimalMark.schema` read and describe a `decimal` argument the same way in every tool.

The `sum` tool:

- An empty `numbers` list is allowed: total 0, count 0, mean null. The sum of nothing is 0; a list that came
  out empty is not a mistake by itself.
- The total is the exact sum, rounded once; `total_exact: false` is added when it had to be rounded.
- The mean is computed from the exact total and is a readable result (above): exact when it fits 38 digits
  (`[1, 2]` gives 1.5), otherwise 15 significant digits (`[1, 2, 3.5]` gives 2.16666666666667) with
  `mean_exact: false`. A mean below 10^-128 (only possible for totals near 10^-128) is an error that names
  the total, never a 0.
- The `*_exact` flags appear only when false, so the common response stays short; the tool description says
  that their absence means exact.
- Unknown arguments are errors: a misspelt `decimal` would otherwise read numbers written the German way by
  the default rules without a word.

### Consequences

- Results are the same on every macOS version, whatever Foundation's arithmetic does.
- A randomized test with a fixed seed checks the four operations, the readable policy and rounding to places
  in every mode against an independent digit-array implementation: correct rounding, `exact`, and the range
  errors.
- 38 digits is a fixed precision: a `Decimal` could hold some 39-digit values, but a precision that depends on
  the digits would be hard to state.
