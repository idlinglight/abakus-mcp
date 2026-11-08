# ADR-0006: Date differences: ISO 8601 in, calendar units and exact totals out, in UTC

Status: accepted, 2026-11-08

## Context

"How long since" and "how long until" are questions agents get wrong in their heads: months have different
lengths, years may be leap years, offsets shift the day. There are two kinds of answer. Calendar units
("1 year 2 months 5 days") depend on where one starts counting and on how a month is added to January 31.
Totals ("427 days", "17.5 days") do not.

Foundation's `Date` is a `Double`: whole seconds are exact in it for every date that matters here, fractions
of a second are not. Foundation's `Calendar` does calendar arithmetic, month ends included, but its Gregorian
calendar switches to the Julian calendar before 15 October 1582. Time zones other than fixed offsets need a
place and the tz database, which a tool call rarely carries.

## Decision

- One tool, `date_diff`, with `from` (required) and `to` (optional, default: now).
- Input is ISO 8601 in the extended format:
  - a date, `2026-11-08`, read as 00:00 UTC;
  - a date-time, `2026-11-08T14:30:00+01:00`: `T`, `t` or a space between date and time (as RFC 3339
    allows), seconds optional, a fraction with `.` or `,` of up to 9 digits (nanoseconds), then `Z`, `z` or
    an offset `±HH:MM`, `±HHMM` or `±HH` (`−`, U+2212, counts as minus);
  - `now`, in any case, for either argument.
- A date-time without an offset is read as UTC, and the response says so in `notes`. The project's first
  sketch spoke of UTC dates; refusing `2026-11-08T14:30` would fail the common case for little gain, and the
  note makes the assumption visible.
- Refused, with an error that names the argument and the input, says what is wrong (`February 2026 has 28
  days`) and what is accepted: other formats (week and ordinal dates, the basic format, an hour without
  minutes), hour 24, second 60 (abakus ignores leap seconds and says so), offsets beyond ±23:59, more than 9
  fractional digits, and instants outside the years 1583 to 9999 in UTC. 1583 is the first full year in which
  Foundation's Gregorian calendar is proleptic; refusing earlier dates beats computing them in a calendar that
  changes in the middle.
- Instants are integers: whole seconds since 1970 plus nanoseconds, computed with proleptic Gregorian day
  numbers (Howard Hinnant's `days_from_civil`). A `Date` is only built from whole seconds. `now` is
  `ToolContext.now()` to the nearest millisecond, read once per call.
- Output, in this order: `from` and `to` in UTC (`2026-11-08T13:30:00Z`, a fraction only when there is one),
  `from_is_now` / `to_is_now` when now was used, `to_before_from`, `calendar`, `text`, `totals`, and `notes`
  when something was assumed.
- `calendar` (years, months, days, hours, minutes, seconds) comes from Foundation's Gregorian calendar in UTC,
  `dateComponents(_:from:to:)` between whole seconds, always counted forward from the earlier instant; the
  remaining fraction of a second is added to `seconds`. Month ends are Foundation's: adding a month to
  January 31 ends on the last day of February. So January 31 to February 28 is 1 month, January 31 to March 1
  is 1 month 1 day, and 2024-02-29 to 2025-02-28 is 1 year. Counting from the earlier instant makes the
  result symmetric: swapping `from` and `to` changes the sign of every number and nothing else (Foundation
  counting backwards would make March 31 to February 28 one month, but February 28 to March 31 one month and
  three days).
- When `to` is before `from`, `to_before_from` is true and every number in `calendar` and `totals` is negative;
  `text` gives the size only.
- `text` lists the non-zero parts: years, months, weeks, days, hours, minutes, seconds, singular for 1
  (`1 year 2 months 5 days`, `2 weeks 3 days`, `31.123 seconds`; `0 seconds` for no difference). Weeks appear
  only here: seven or more days are written as weeks and days, while `calendar.days` keeps the full count.
- `totals` (days, hours, minutes, seconds) come from the exact difference in nanoseconds. `seconds` is always
  exact. The others are exact when they come out even (17.5 days); otherwise they are rounded half away from
  zero to six more decimal places than the seconds have (six for whole seconds), and `days_exact: false`,
  `hours_exact: false` or `minutes_exact: false` is added, as `sum` does for its mean
  ([ADR-0005](0005-numbers.md)).
- Leap seconds are ignored: every day has 86400 seconds, as in POSIX time and Foundation.
- Annotations: read-only, idempotent, not open-world. The result is not deterministic when `to` defaults to
  now; MCP has no annotation for that, so the description says it.
- Unknown arguments are errors.

## Consequences

- UTC only. An agent with local times passes their offsets; dates without times count calendar days, whatever
  the zone. Differences across daylight saving changes in a named zone ("the same wall-clock time tomorrow")
  are out of scope; a time zone argument would amend this ADR.
- Month arithmetic is Foundation's. Tests pin the month-end cases and check, on random pairs, that the
  breakdown added to the earlier instant gives the later one; a change in Foundation would show there.
- Fractions finer than a nanosecond, dates before 1583 and years beyond 9999 are refused rather than
  approximated.
