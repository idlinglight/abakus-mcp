# Working in this repository

- SwiftPM package, macOS only. `swift build`, `swift test`, then `dev/check.zsh` (end to end against the
  debug binary: both MCP eras and the CLI, in a scratch state folder). Tests use Swift Testing.
- The CLI is tested in `dev/check.zsh`, not in a test target: it only maps options to tool arguments, and the
  script also checks the release binary that `install.zsh` installs (#17). A new option or usage error gets a
  check there; a usage error checks that the usage shown is the command's own.
- The skill `skills/abakus/` (installed by `install.zsh --skill`): a short `SKILL.md` (when and how to use the
  CLI; the tool descriptions only say that it exists, ADR-0008) that links the topic files `tallies.md` (tallies
  in depth, over MCP too) and `calc-sum.md`, each readable on its own. A new or changed command, option, detail
  key or tally behaviour goes into the file for its topic; `dev/check.zsh` fails when a file names a command the
  help does not list, an option its command lacks or a tool that does not exist, when the files together miss a
  command, or when a link points to a missing file or heading.
- Targets: `AbakusCore` (all tool behaviour), `AbakusMCP` (the MCP server), `abakus` (the executable:
  `abakus mcp` and the CLI). A tool is defined once in the core as a `Tool` and listed in its area's `all`
  (`TallyTools`, `ArithmeticTools`, `DateTools`), which `Catalog` concatenates. CLI commands only build a
  tool's arguments and print its result (`ToolRunner`); behaviour never lives in the CLI. What grows with the
  input stays off MCP (ADR-0008): a top-level key that grows is one of the tool's `detailKeys`, which the MCP
  server leaves out; a list that MCP shortens, or one nested inside the result, goes through the tool's own
  `withoutDetails` override (calc's `tallies`, the tally tools' `marks` via `TallyStateTool`). The CLI prints
  everything, and a successful MCP result stays within a few hundred characters.
- A new or changed tool: update its description, the README section and tool table, `dev/check.zsh` if the
  end-to-end path changes, and the ADR if a decision changes.
- `install.zsh` installs into the user's `~/.local/bin` (with `--skill`, also into `~/.claude/skills`); only
  run it when asked. Agents test with the debug build and `ABAKUS_STATE_DIR` pointing at a scratch folder.
- Never use Foundation's `Decimal` arithmetic (`+ - * /`, `NSDecimal*`, `NSDecimalRound`) or
  `Decimal(string:)`: they truncate, miss overflow and round silently (ADR-0005 amendment). Use `DecimalMath`
  and `NumberReader`.
- calc's expression trees (`CalcExpression`) can be about 500 levels deep (a flat `1+1+…+1` chain): walk them
  with `fold` or another loop, never recursively. A recursive walk overflows the 512 KB stack of a test thread
  in debug builds, and in the server it would crash the session's MCP connection (ADR-0007 amendment).
- Decisions are ADRs in `docs/adr/` (`# ADR-NNNN: Title`, a status line, then Context, Decision,
  Consequences). A change that contradicts an ADR amends it or adds a new one. Keep the README's ADR list
  and tool table in step.
- Dependencies only from `github.com/apple` and `github.com/swiftlang` (ADR-0001). Adding or updating one
  goes through the version and owner checks described there, never around them.
- No binary floating point for numbers that reach a user: `Decimal` as storage, and `JSONValue.number` keeps
  literals as text (ADR-0005). There is deliberately no float literal for `JSONValue`.
- Tests never touch real state: anything that writes uses a fresh temporary folder as the
  `ToolContext.stateDirectory`, never `ToolContext.live()`.
- Tool descriptions, error messages and the server's instructions are written for an agent reading them:
  say what happened and what to do next, in plain sentences. For new or much-changed text, a usability probe
  is worth its cost: give the draft alone to a few fresh agents (haiku, sonnet, opus) with tasks that include
  traps, and ask for the calls they would make and what they had to guess (ADR-0007, Context).
- The repository is public. Keep personal context, real data from real projects, and secrets out of it:
  examples and test fixtures are made up. Personal context goes into `CLAUDE.local.md` (not tracked).
- The shell here is zsh. Pull requests run `.github/workflows/ci.yml` (job `build-and-test`, a required
  check on `main`). Actions are pinned by full commit SHA with a version comment; the repository only
  allows actions from GitHub's own organisations.
