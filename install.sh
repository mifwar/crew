#!/usr/bin/env bash
# Put this checkout's crew on PATH: ~/.local/bin/crew → bin/crew (symlink).
# bin/crew finds share/crew next to its real path, so templates and the web
# viewer are always read from this checkout. Re-run safely any time.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="${CREW_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"
if [ -e "$BIN/crew" ] && [ ! -L "$BIN/crew" ]; then
  mv "$BIN/crew" "$BIN/crew.bak.$(date +%Y%m%d-%H%M%S)"
  echo "backed up the old $BIN/crew"
fi
ln -sfn "$ROOT/bin/crew" "$BIN/crew"
echo "installed: $BIN/crew -> $ROOT/bin/crew"
# The crew skill, for each agent CLI that is set up here (skip a real dir).
link_skill() { # agent-home skills-dir
  [ -d "$1" ] || return 0
  mkdir -p "$2"
  if [ -e "$2/crew" ] && [ ! -L "$2/crew" ]; then
    echo "note: $2/crew exists and isn't a symlink; left it alone"
  else
    ln -sfn "$ROOT/skills/crew" "$2/crew"
    echo "installed: $2/crew -> $ROOT/skills/crew"
  fi
}
link_skill "$HOME/.claude" "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
link_skill "$HOME/.codex" "$HOME/.codex/skills"
link_skill "$HOME/.pi" "$HOME/.pi/agent/skills"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not on your PATH" ;; esac
command -v bun >/dev/null || echo "note: 'crew web' needs bun (brew install oven-sh/bun/bun)"
