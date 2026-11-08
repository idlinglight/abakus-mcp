# ADR-0003: State: one file per tally in the per-user temporary folder

Status: accepted, 2026-11-08; amended 2026-11-08 (tally files in `tallies/`, file format, one lock on the
folder itself for all tallies, what creates folders, unreadable files)

## Context

Tallies need state that outlives a tool call and is shared between processes: every MCP client session
starts its own `abakus mcp`, and the CLI is yet another process. A daemon holding the state in memory would
be one more thing to keep running.

The state is ad hoc. It matters for a session or a batch of work, not for weeks.

macOS gives every user a private temporary folder (`/var/folders/…/T/`). `dirhelper` deletes files there
that have not been touched for three days (it runs daily at 03:35 with `CLEAN_FILES_OLDER_THAN_DAYS=3`, see
`/System/Library/LaunchDaemons/com.apple.bsd.dirhelper.plist`). `/private/tmp` is shared by all users.

`$TMPDIR` normally names the per-user folder, but a launcher or sandbox can set it to something else, so two
processes of the same user may disagree on it. `confstr(_CS_DARWIN_USER_TEMP_DIR)` returns the per-user
folder whatever the environment says.

## Decision

- State lives in `abakus/` in the per-user temporary folder, found through `confstr`
  (`StateDirectory`). `ABAKUS_STATE_DIR` replaces the whole path; tests always set it.
- Folders are created with mode 0700 (missing parents too) and files with 0600; a folder that already exists
  keeps its mode. Only a call that writes a new tally (`tally_create`) creates folders: a read, or a change
  that needs an existing tally, leaves a missing folder missing.
- Tallies live in `tallies/` below the state folder, one JSON file `<name>.json` per tally. Tally names are
  global for the user: every session and the CLI see the same tallies ([ADR-0004](0004-tallies.md) makes
  collisions visible).
- The file carries a `format` version (currently 1) and keeps every decimal as a JSON string
  (`"value": "2490123.5"`), so no binary floating point is involved on the way to disk and back
  ([ADR-0005](0005-numbers.md)). A file in a newer format is refused and left alone, never overwritten.
- Every change is a read-modify-write under an exclusive lock: `flock` on the `tallies/` folder itself,
  through a read-only descriptor of the directory, one lock for all tallies. Reads take the same lock shared.
  There is no lock file: nothing would ever write to one, so `dirhelper` could delete it after three days
  even while tallies are in daily use and while it is held, and a newcomer would then lock a fresh file
  and change tallies alongside the holder.
- Each call opens the folder itself, so calls in one process exclude each other just as processes do. After
  locking, abakus checks that the folder at the path is still the one it locked (an empty folder untouched
  for three days may be removed, and created again by someone else) and locks again if not. A folder that is
  gone, also one that vanishes while the lock is being taken, simply holds no tallies.
- The new content is written to a temporary file in the same folder, flushed, and renamed into place.
  Parallel calls from several sessions don't lose updates, and no reader sees half a file. Names starting
  with `.` (temporary files) belong to the folder; tally names cannot start with one.
- Lifetime is the operating system's: a tally that has not changed for about three days may disappear.
  abakus never recreates one silently; an unknown name is an error that says this can happen.
- A file that cannot be read (damaged, or written by a newer version) makes calls on that tally fail with an
  error naming the file. `tally_drop` deletes it all the same, and `tally_list` reports it under `unreadable`
  instead of failing.

## Consequences

- Nothing to start, stop or clean up. State can be inspected with `ls` and `cat`.
- One lock for all tallies serialises every tally call of the user. Each holds it for one small read and
  write, which is negligible at the pace agents call tools; per-tally locks would be the next step if not.
- Tallies that must survive days of idleness or a reboot are out of scope; a persistent location would be a
  new decision.
- A process sandboxed away from the per-user temporary folder cannot use tallies unless `ABAKUS_STATE_DIR`
  points it somewhere it may write. MCP servers started by a client normally run unsandboxed.
