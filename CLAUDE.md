# Working in this repository

- SwiftPM package, macOS only. `swift build`, `swift test`, then `dev/check.zsh` (end to end against the
  debug binary: both MCP eras and the CLI, in a scratch state folder). Tests use Swift Testing.
- Targets: `AbakusCore` (all tool behaviour), `AbakusMCP` (the MCP server), `abakus` (the executable:
  `abakus mcp` and the CLI). A tool is defined once in the core as a `Tool` and listed in its area's `all`
  (`TallyTools`, `ArithmeticTools`, `DateTools`), which `Catalog` concatenates. CLI commands only build a
  tool's arguments and print its result (`ToolRunner`); behaviour never lives in the CLI.
- A new or changed tool: update its description, the README section and tool table, `dev/check.zsh` if the
  end-to-end path changes, and the ADR if a decision changes.
- `install.zsh` installs into the user's `~/.local/bin`; only run it when asked. Agents test with the debug
  build and `ABAKUS_STATE_DIR` pointing at a scratch folder.
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
