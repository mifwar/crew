# Sourced by smoke.sh; all native session stores and crew state are fixtures.
session_project="$CREW_HOME/session-project"
mkdir -p "$session_project"
session_project=$(cd "$session_project" && pwd)

session_test_crew() { # name cli
  local name="$1" cli="$2" dir="$CREW_HOME/$1"
  mkdir -p "$dir"
  : > "$dir/board.tsv"
  : > "$dir/channel.log"
  printf 'mode=up\ncwd=%s\n' "$session_project" > "$dir/meta"
  printf 'lead\t%%999991\t%s\tspawned\n' "$cli" > "$dir/panes"
}

claude_home="$CREW_HOME/claude-config"
claude_slug=$(printf '%s' "$session_project" | sed 's|/|-|g')
claude_dir="$claude_home/projects/$claude_slug"
mkdir -p "$claude_dir"
printf '{}\n' > "$claude_dir/claude-old.jsonl"
printf '{}\n' > "$claude_dir/claude-new.jsonl"
touch -t 202610210900 "$claude_dir/claude-old.jsonl"
touch -t 202610211000 "$claude_dir/claude-new.jsonl"

session_test_crew session-ambiguous claude
printf 'rev\t%%999992\tclaude\tspawned\n' >> "$CREW_HOME/session-ambiguous/panes"
check 'session refuses newest-only lookup when same-CLI roles share a folder' \
  bash -c 'CLAUDE_CONFIG_DIR="$1" "$2" -s session-ambiguous session lead 2>&1 | grep -q "another claude role shares"' _ "$claude_home" "$CREW"
CLAUDE_CONFIG_DIR="$claude_home" "$CREW" -s session-ambiguous session lead claude-exact-id >/dev/null
check 'session pin records the exact role ID' \
  awk -F '\t' '$1=="lead" && $2=="claude" && $4=="claude-exact-id"{f=1} END{exit !f}' \
    "$CREW_HOME/session-ambiguous/sessions.tsv"
check 'recorded ID resolves even when same-CLI roles share a folder' \
  bash -c 'test "$(CLAUDE_CONFIG_DIR="$1" "$2" -s session-ambiguous session lead)" = claude-exact-id' _ "$claude_home" "$CREW"

session_test_crew session-newest claude
check 'unique Claude role selects and records its newest project transcript' \
  bash -c 'test "$(CLAUDE_CONFIG_DIR="$1" "$2" -s session-newest session lead 2>/dev/null)" = claude-new' _ "$claude_home" "$CREW"

codex_home="$CREW_HOME/codex-config"
codex_dir="$codex_home/sessions/2026/10/21"
mkdir -p "$codex_dir"
printf '{"timestamp":"2026-10-21T09:00:00Z","type":"session_meta","payload":{"id":"codex-session-id","cwd":"%s"}}\n' \
  "$session_project" > "$codex_dir/rollout-2026-10-21T09-00-00-codex-session-id.jsonl"
session_test_crew session-codex codex
check 'Codex lookup matches rollout metadata to the crew working folder' \
  bash -c 'test "$(CODEX_HOME="$1" "$2" -s session-codex session lead 2>/dev/null)" = codex-session-id' _ "$codex_home" "$CREW"

pi_dir="$CREW_HOME/pi-config"
mkdir -p "$pi_dir"
printf '{}\n' > "$pi_dir/2026-10-21T10-00-00-000Z_pi-session-id.jsonl"
session_test_crew session-pi pi
check 'pi lookup reads the session ID from its project filename' \
  bash -c 'test "$(PI_CODING_AGENT_SESSION_DIR="$1" "$2" -s session-pi session lead 2>/dev/null)" = pi-session-id' _ "$pi_dir" "$CREW"

resume_dir="$CREW_HOME/session-resume"
mkdir -p "$resume_dir" "$CREW_HOME/fake-bin"
: > "$resume_dir/board.tsv"
: > "$resume_dir/channel.log"
printf 'mode=up\ncwd=%s\n' "$session_project" > "$resume_dir/meta"
printf 'lead\t%%999993\t%s/claude --marker test\tspawned\n' "$CREW_HOME/fake-bin" > "$resume_dir/panes"
printf 'lead\tclaude\t%s\tresume-session-id\n' "$session_project" > "$resume_dir/sessions.tsv"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FAKE_SESSION_ARGS"\npwd > "${FAKE_SESSION_CWD}"\n' \
  > "$CREW_HOME/fake-bin/claude"
chmod +x "$CREW_HOME/fake-bin/claude"
resume_pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$TS:" 'sleep 300')
FAKE_SESSION_ARGS="$CREW_HOME/session-args" FAKE_SESSION_CWD="$CREW_HOME/session-cwd" \
  TMUX_PANE="$resume_pane" CLAUDE_CONFIG_DIR="$claude_home" "$CREW" -s session-resume resume lead >/dev/null
check 'resume rebinds the role to the new pane as adopted' \
  awk -F '\t' -v p="$resume_pane" '$1=="lead" && $2==p && $4=="adopted"{f=1} END{exit !f}' "$resume_dir/panes"
check 'resume launches Claude with the exact saved session ID' \
  bash -c 'grep -qF -- "--resume" "$1" && grep -qF "resume-session-id" "$1"' _ "$CREW_HOME/session-args"
check 'resume starts in the crew working directory' \
  test "$(cat "$CREW_HOME/session-cwd")" = "$session_project"
check 'resume keeps the new pane owned by its role' \
  test "$(tmux display-message -p -t "$resume_pane" '#{@crew_session}/#{@crew_role}')" = session-resume/lead
