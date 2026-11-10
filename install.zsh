#!/usr/bin/env zsh
# install: build abakus for release, check the build end to end (dev/check.zsh), copy it to ~/.local/bin, with
# its zsh tab completion. The installed abakus is always a build that passed its checks. With --skill, also the
# abakus skill for Claude Code (skills/abakus): tallies in depth, and when and how agents use the command line
# (ADR-0008).
# usage: ./install.zsh [--skill]
set -euo pipefail

skill=false
if (( $# == 1 )) && [[ $1 == --skill ]]; then
  skill=true
elif (( $# )); then
  print -u2 -- "usage: ./install.zsh [--skill]"
  exit 2
fi

# --skill: user-level skills live in Claude Code's configuration folder, ~/.claude unless CLAUDE_CONFIG_DIR moves
# it. Resolved before the cd below, which would make a relative path point into this repository.
if [[ $skill == true ]]; then
  config_folder=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  if [[ $config_folder == '~' || $config_folder == '~/'* ]]; then
    config_folder=$HOME${config_folder#'~'}
  fi
  if [[ $config_folder != /* ]]; then
    print -u2 -- "not installed: CLAUDE_CONFIG_DIR is \"$config_folder\", not an absolute path. Set it to one, or" \
      "unset it to install the skill into ~/.claude."
    exit 1
  fi
  skill_folder=$config_folder/skills/abakus
  old_skill_folder=$config_folder/skills/abakus-cli  # the skill's name until 2026-11-10
fi

cd ${0:A:h}
if [[ $skill == true && ! -f skills/abakus/SKILL.md ]]; then
  print -u2 -- "not installed: skills/abakus/SKILL.md is missing"
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

# the skill: Claude Code finds a user-level skill by its folder, in every project. The folder belongs to this
# install and is replaced as a whole, so no file of an earlier version stays behind. The copy is made in a
# temporary folder first, so that a failed copy leaves no half skill among the user's skills.
if [[ $skill == true ]]; then
  staging=$(mktemp -d)
  cp -R skills/abakus $staging/abakus
  chmod -R u=rwX,go=rX $staging/abakus
  replaced=
  if [[ -e $skill_folder || -L $skill_folder ]]; then
    replaced=$( (cd $skill_folder 2>/dev/null && find . -type f | sed 's|^\./||' | sort | paste -s -d ' ' -) || true)
    rm -rf -- $skill_folder
    replaced="replaced the folder that was there (${replaced:-no files})"
  fi
  mkdir -p ${skill_folder:h}
  mv $staging/abakus $skill_folder
  rmdir $staging
  print -- "installed ${skill_folder/#$HOME/~}/, the skill abakus for Claude Code${replaced:+; $replaced}"
  # the skill's earlier name: no longer this install's folder, so it is left alone; it is named, since agents
  # would see both skills
  if [[ -e $old_skill_folder || -L $old_skill_folder ]]; then
    print -- "left ${old_skill_folder/#$HOME/~}/ alone, the skill's earlier name: agents see both skills until" \
      "you remove it."
  fi
fi

# MCP clients start `abakus mcp` themselves; registering is a one-time step, left to the user
print -- ""
print -- "To offer the tools to Claude Code in every project (once):"
print -- "  claude mcp add --scope user abakus -- $HOME/.local/bin/abakus mcp"
