# ADR-0003: State: one file per tally in the per-user temporary folder

Status: accepted, 2026-11-08

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
  (`StateDirectory`). `ABAKUS_STATE_DIR` replaces the whole path; tests always set it. The folder is created
  with mode 0700 on first write.
- One JSON file per tally. Tally names are global for the user: every session and the CLI see the same
  tallies ([ADR-0004](0004-tallies.md) makes collisions visible).
- Every change is a read-modify-write under an exclusive lock (`flock` on a lock file in the state folder),
  written to a temporary file and renamed into place. Parallel calls from several sessions don't lose
  updates, and no reader sees half a file.
- Lifetime is the operating system's: a tally that has not changed for about three days may disappear.
  abakus never recreates one silently; an unknown name is an error that says this can happen.

## Consequences

- Nothing to start, stop or clean up. State can be inspected with `ls` and `cat`.
- Tallies that must survive days of idleness or a reboot are out of scope; a persistent location would be a
  new decision.
- A process sandboxed away from the per-user temporary folder cannot use tallies unless `ABAKUS_STATE_DIR`
  points it somewhere it may write. MCP servers started by a client normally run unsandboxed.
