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
# Claude Code skill: ~/.claude/skills/crew → skills/crew (skip if a real dir is there).
SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ -d "$HOME/.claude" ]; then
  mkdir -p "$SKILLS"
  if [ -e "$SKILLS/crew" ] && [ ! -L "$SKILLS/crew" ]; then
    echo "note: $SKILLS/crew exists and isn't a symlink; left it alone"
  else
    ln -sfn "$ROOT/skills/crew" "$SKILLS/crew"
    echo "installed: $SKILLS/crew -> $ROOT/skills/crew"
  fi
fi
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not on your PATH" ;; esac
command -v bun >/dev/null || echo "note: 'crew web' needs bun (brew install oven-sh/bun/bun)"
