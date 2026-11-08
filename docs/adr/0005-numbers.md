# ADR-0005: Numbers: exact decimals, read by stated rules

Status: accepted, 2026-11-08

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
