# ADR-0005: Numbers: exact decimals, read by stated rules

Status: accepted, 2026-11-08; amended 2026-11-08 (see the end)

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
- Foundation's `Decimal` remains the storage type and the source of the plain-notation output; its
  arithmetic functions and its string parser are not used.

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
- `NumberReader.rulesSummary` states the rules in two sentences for tool descriptions;
  `DecimalMark.argument` and `DecimalMark.schema` read and describe a `decimal` argument the same way in
  every tool.

### Consequences

- Results are the same on every macOS version, whatever Foundation's arithmetic does.
- A randomized test with a fixed seed checks the four operations against an independent digit-array
  implementation: correct rounding, `exact`, and the range errors.
- 38 digits is a fixed precision: a `Decimal` could hold some 39-digit values, but a precision that depends on
  the digits would be hard to state.
