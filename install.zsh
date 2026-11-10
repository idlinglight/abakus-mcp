#!/usr/bin/env zsh
# install: build abakus for release, check the build end to end (dev/check.zsh), copy it to ~/.local/bin, with
# its zsh tab completion. The installed abakus is always a build that passed its checks. With --skill, also the
# abakus-cli skill for Claude Code (skills/abakus-cli): when and how agents use the command line (ADR-0008).
# usage: ./install.zsh [--skill]
set -euo pipefail
cd ${0:A:h}

skill=false
if (( $# == 1 )) && [[ $1 == --skill ]]; then
  skill=true
elif (( $# )); then
  print -u2 -- "usage: ./install.zsh [--skill]"
  exit 2
fi
# user-level skills live in Claude Code's configuration folder, ~/.claude unless CLAUDE_CONFIG_DIR moves it
skill_source=skills/abakus-cli/SKILL.md
skill_folder=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/abakus-cli
if [[ $skill == true && ! -f $skill_source ]]; then
  print -u2 -- "not installed: $skill_source is missing"
  exit 1
fi

swift build -c release --product abakus
bin=$(swift build -c release --show-bin-path)
if ! ABAKUS=$bin/abakus dev/check.zsh; then
  print -u2 -- "not installed: the check failed"
  exit 1
fi

mkdir -p ~/.local/bin
install -m 755 $bin/abakus ~/.local/bin/abakus
print -- "installed ~/.local/bin/abakus $(~/.local/bin/abakus --version)"

# tab completion: zsh finds _abakus in a folder on its fpath (one line in ~/.zshrc, before compinit:
# fpath=(~/.local/share/zsh/site-functions $fpath))
mkdir -p ~/.local/share/zsh/site-functions
~/.local/bin/abakus --generate-completion-script zsh > ~/.local/share/zsh/site-functions/_abakus
print -- "installed ~/.local/share/zsh/site-functions/_abakus"

# the skill: Claude Code finds a user-level skill by its folder, in every project
if [[ $skill == true ]]; then
  mkdir -p $skill_folder
  install -m 644 $skill_source $skill_folder/SKILL.md
  print -- "installed ${skill_folder/#$HOME/~}/SKILL.md, the skill abakus-cli for Claude Code"
fi

# MCP clients start `abakus mcp` themselves; registering is a one-time step, left to the user
print -- ""
print -- "To offer the tools to Claude Code in every project (once):"
print -- "  claude mcp add --scope user abakus -- $HOME/.local/bin/abakus mcp"
