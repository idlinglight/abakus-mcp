#!/usr/bin/env zsh
# install: build abakus for release, check the build end to end (dev/check.zsh), copy it to ~/.local/bin, with
# its zsh tab completion. The installed abakus is always a build that passed its checks.
# usage: ./install.zsh
set -euo pipefail
cd ${0:A:h}

if (( $# )); then
  print -u2 -- "usage: ./install.zsh"
  exit 2
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

# MCP clients start `abakus mcp` themselves; registering is a one-time step, left to the user
print -- ""
print -- "To offer the tools to Claude Code in every project (once):"
print -- "  claude mcp add --scope user abakus -- $HOME/.local/bin/abakus mcp"
