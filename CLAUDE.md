# Working in this repository

- SwiftPM package, macOS only. `swift build`, `swift test`. Tests use Swift Testing (`import Testing`).
- Targets: `AbakusCore` (all tool behaviour), `AbakusMCP` (the MCP server), `abakus` (the executable:
  `abakus mcp` and the CLI). A tool is defined once in the core as a `Tool` and listed in its area's `all`
  (`TallyTools`, `ArithmeticTools`, `DateTools`), which `Catalog` concatenates.
- Decisions are ADRs in `docs/adr/` (`# ADR-NNNN: Title`, a status line, then Context, Decision,
  Consequences). A change that contradicts an ADR amends it or adds a new one. Keep the README's ADR list
  and tool table in step.
- Dependencies only from `github.com/apple` and `github.com/swiftlang` (ADR-0001). Adding or updating one
  goes through the version and owner checks described there, never around them.
- No binary floating point for numbers that reach a user: `Decimal`, and `JSONValue.number` keeps literals as
  text (ADR-0005). There is deliberately no float literal for `JSONValue`.
- Tests never touch real state: anything that writes uses a fresh temporary folder as the
  `ToolContext.stateDirectory`, never `ToolContext.live()`.
- Tool descriptions, error messages and the server's instructions are written for an agent reading them:
  say what happened and what to do next, in plain sentences.
- The repository is public. Keep personal context, real data from real projects, and secrets out of it:
  examples and test fixtures are made up. Personal context goes into `CLAUDE.local.md` (not tracked).
- The shell here is zsh. Pull requests run `.github/workflows/ci.yml` (job `build-and-test`, a required
  check on `main`). Actions are pinned by full commit SHA with a version comment; the repository only
  allows actions from GitHub's own organisations.
