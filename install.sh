#!/usr/bin/env bash
# Put this checkout's crew on PATH: ~/.local/bin/crew → bin/crew (symlink),
# and link its skill into each installed agent's skills dir. bin/crew finds
# share/crew next to its real path, so templates and the web viewer are always
# read from this checkout. Re-run safely any time.
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
# One shared crew skill, linked into every installed agent's skills dir.
# Anything already at the target is left alone — a real directory or a
# symlink to somewhere else — unless it already points at this skill.
link_skill() { # skills-dir
  local dir="$1" target="$1/crew" existing
  mkdir -p "$dir"
  if [ -L "$target" ] && [ "$target/SKILL.md" -ef "$ROOT/skills/crew/SKILL.md" ]; then
    echo "already linked: $target -> $ROOT/skills/crew"
  elif [ -L "$target" ]; then
    existing=$(readlink "$target")
    echo "note: $target is a symlink to $existing; left it alone"
  elif [ -e "$target" ]; then
    echo "note: $target exists and isn't a symlink; left it alone"
  else
    ln -sfn "$ROOT/skills/crew" "$target"
    echo "installed: $target -> $ROOT/skills/crew"
  fi
}

# Claude Code: ~/.claude/skills/crew
if [ -d "$HOME/.claude" ]; then
  link_skill "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
fi
# Shared Agent Skills dir, read by both Codex and pi: ~/.agents/skills/crew
if [ -d "$HOME/.codex" ] || [ -d "$HOME/.pi" ]; then
  link_skill "${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
fi
# pi: ~/.pi/agent/skills/crew
if [ -d "$HOME/.pi" ]; then
  link_skill "${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
fi
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not on your PATH" ;; esac
command -v bun >/dev/null || echo "note: 'crew web' needs bun (brew install oven-sh/bun/bun)"
