# Sourced by smoke.sh; all native session stores and crew state are fixtures.
session_project="$CREW_HOME/session.project"
mkdir -p "$session_project"
session_project=$(cd "$session_project" && pwd)

session_test_crew() { # name cli
  local name="$1" cli="$2" dir="$CREW_HOME/$1" created created_epoch
  mkdir -p "$dir"
  : > "$dir/board.tsv"
  : > "$dir/channel.log"
  created=$(date '+%Y-%m-%dT%H:%M:%S'); created_epoch=$(date +%s)
  printf 'mode=up\ncwd=%s\ncreated=%s\ncreated_epoch=%s\n' "$session_project" "$created" "$created_epoch" > "$dir/meta"
  printf 'lead\t%%999991\t%s\tspawned\n' "$cli" > "$dir/panes"
}

claude_home="$CREW_HOME/claude-config"
claude_slug=$(printf '%s' "$session_project" | sed 's|[^A-Za-z0-9]|-|g')
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
touch "$claude_dir/claude-new.jsonl"
check 'unique Claude role selects and records its newest project transcript' \
  bash -c 'test "$(CLAUDE_CONFIG_DIR="$1" "$2" -s session-newest session lead 2>/dev/null)" = claude-new' _ "$claude_home" "$CREW"
touch -t 202001010000 "$claude_dir/claude-new.jsonl"
session_test_crew session-stale claude
check 'session fallback ignores transcripts older than the crew start' \
  bash -c 'CLAUDE_CONFIG_DIR="$1" "$2" -s session-stale session lead 2>&1 | grep -q "no claude session found"' _ "$claude_home" "$CREW"

codex_home="$CREW_HOME/codex-config"
codex_dir="$codex_home/sessions/2026/10/21"
mkdir -p "$codex_dir"
session_test_crew session-codex codex
printf '{"timestamp":"2026-10-21T09:00:00Z","type":"session_meta","payload":{"id":"codex-session-id","cwd":"%s"}}\n' \
  "$session_project" > "$codex_dir/rollout-2026-10-21T09-00-00-codex-session-id.jsonl"
check 'Codex lookup matches rollout metadata to the crew working folder' \
  bash -c 'test "$(CODEX_HOME="$1" "$2" -s session-codex session lead 2>/dev/null)" = codex-session-id' _ "$codex_home" "$CREW"

codex_old_home="$CREW_HOME/codex-old-config"
codex_old_dir="$codex_old_home/sessions/2026/10/21"
codex_head_bin="$CREW_HOME/codex-head-bin"
codex_head_calls="$CREW_HOME/codex-head-calls"
mkdir -p "$codex_old_dir" "$codex_head_bin"
i=1
while [ "$i" -le 300 ]; do
  suffix=$(printf '%04d' "$i")
  file="$codex_old_dir/rollout-old-$suffix.jsonl"
  printf '{"type":"session_meta","payload":{"id":"old-%s","cwd":"%s"}}\n' "$suffix" "$session_project" > "$file"
  touch -t 202001010000 "$file"
  i=$((i + 1))
done
cat > "$codex_head_bin/head" <<'EOF'
#!/bin/sh
case "$*" in *rollout-old-*) printf 'read\n' >> "$CODEX_HEAD_COUNT" ;; esac
exec /usr/bin/head "$@"
EOF
chmod +x "$codex_head_bin/head"
session_test_crew session-codex-prune codex
codex_prune_pane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" 'sleep 300')
tmux set-option -p -t "$codex_prune_pane" @crew_session session-codex-prune
tmux set-option -p -t "$codex_prune_pane" @crew_role lead
printf 'lead\t%s\tcodex\tspawned\n' "$codex_prune_pane" > "$CREW_HOME/session-codex-prune/panes"
codex_launch_epoch=$(date +%s)
printf 'lead\tcodex\t%s\t\t%s\n' "$session_project" "$codex_launch_epoch" > "$CREW_HOME/session-codex-prune/sessions.tsv"
env CODEX_HEAD_COUNT="$codex_head_calls" PATH="$codex_head_bin:$PATH" head -n 1 "$codex_old_dir/rollout-old-0001.jsonl" >/dev/null
check 'Codex rollout read counter is wired' test -s "$codex_head_calls"
: > "$codex_head_calls"
check 'crew command prunes old Codex rollouts before reading them' \
  env CODEX_HOME="$codex_old_home" CODEX_HEAD_COUNT="$codex_head_calls" PATH="$codex_head_bin:$PATH" \
    CREW_SESSION=session-codex-prune CREW_AGENT=lead "$CREW" -s session-codex-prune status
check 'old Codex rollouts remain unassigned' \
  awk -F '\t' '$1=="lead" && $4=="" && $5 ~ /^[0-9]+$/{f=1} END{exit !f}' \
    "$CREW_HOME/session-codex-prune/sessions.tsv"
check 'crew status read no old Codex rollout headers' test ! -s "$codex_head_calls"
tmux kill-pane -t "$codex_prune_pane"

pi_dir="$CREW_HOME/pi-config"
mkdir -p "$pi_dir"
session_test_crew session-pi pi
printf '{}\n' > "$pi_dir/2026-10-21T10-00-00-000Z_pi-session-id.jsonl"
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

start_home="$CREW_HOME/start-config"
start_bin="$CREW_HOME/start-bin"
start_cli_dir=$(mktemp -d /tmp/c.XXXXXX)
start_slug=$(printf '%s' "$PWD" | sed 's|[^A-Za-z0-9]|-|g')
mkdir -p "$start_home/projects/$start_slug" "$start_bin"
cat > "$start_bin/claude" <<EOF
#!/bin/bash
id="\$2"
exec -a claude /bin/bash -c '
  IFS= read -r first_message
  : > "$start_home/projects/$start_slug/\$1.jsonl"
  exec -a claude /bin/sleep 300
' _ "\$id"
EOF
chmod +x "$start_bin/claude"
ln -s "$start_bin/claude" "$start_cli_dir/claude"
check 'up stores a launch epoch before the CLI receives its first message' \
  env CREW_NO_SWITCH=1 CREW_BOOT_WAIT=4 CLAUDE_CONFIG_DIR="$start_home" \
    "$CREW" up session-start --in "$TS" "lead=$start_cli_dir/claude --id start-lead"
check 'the fake Claude creates its native file only on first input' \
  test -f "$start_home/projects/$start_slug/start-lead.jsonl"
check 'up leaves the session ID empty until a later crew command' \
  awk -F '\t' '$1=="lead" && $2=="claude" && $3=="'"$PWD"'" && $4=="" && $5 ~ /^[0-9]+$/{f=1} END{exit !f}' \
    "$CREW_HOME/session-start/sessions.tsv"
check 'the role lazily captures its first-input session ID on a later crew command' \
  env CLAUDE_CONFIG_DIR="$start_home" CREW_SESSION=session-start CREW_AGENT=lead \
    "$CREW" -s session-start status
check 'up records the exact new session ID' \
  awk -F '\t' '$1=="lead" && $2=="claude" && $4=="start-lead"{f=1} END{exit !f}' "$CREW_HOME/session-start/sessions.tsv"
check 'session lookup returns the lazily captured ID' \
  bash -c 'test "$(CLAUDE_CONFIG_DIR="$1" "$2" -s session-start session lead)" = start-lead' _ "$start_home" "$CREW"
check 'add stores a second same-CLI launch epoch' \
  env CREW_BOOT_WAIT=4 CLAUDE_CONFIG_DIR="$start_home" \
    "$CREW" -s session-start add "rev=$start_cli_dir/claude --id start-rev"
check 'add leaves the new role ID empty until a later crew command' \
  awk -F '\t' '$1=="rev" && $2=="claude" && $4=="" && $5 ~ /^[0-9]+$/{f=1} END{exit !f}' \
    "$CREW_HOME/session-start/sessions.tsv"
check 'the added role lazily captures its own session ID on a crew command' \
  env CLAUDE_CONFIG_DIR="$start_home" CREW_SESSION=session-start CREW_AGENT=rev \
    "$CREW" -s session-start status
check 'later same-CLI launch gets its own exact session ID' \
  awk -F '\t' '$1=="rev" && $2=="claude" && $4=="start-rev"{f=1} END{exit !f}' "$CREW_HOME/session-start/sessions.tsv"
start_lead_pane=$(awk -F '\t' '$1=="lead"{print $2}' "$CREW_HOME/session-start/panes")
check 'override-spawn leaves a pending launch epoch after the intro' \
  env CREW_BOOT_WAIT=4 CLAUDE_CONFIG_DIR="$start_home" TMUX_PANE="$start_lead_pane" \
    "$CREW" -s session-start override "lead=$start_cli_dir/claude --id override-lead"
check 'override leaves the replacement ID empty until a later crew command' \
  awk -F '\t' '$1=="lead" && $2=="claude" && $4=="" && $5 ~ /^[0-9]+$/{f=1} END{exit !f}' \
    "$CREW_HOME/session-start/sessions.tsv"
check 'the replacement lazily captures its session ID on a crew command' \
  env CLAUDE_CONFIG_DIR="$start_home" CREW_SESSION=session-start CREW_AGENT=lead \
    "$CREW" -s session-start status
check 'override replaces the role mapping with its new CLI session' \
  awk -F '\t' '$1=="lead" && $2=="claude" && $4=="override-lead"{f=1} END{exit !f}' "$CREW_HOME/session-start/sessions.tsv"
"$CREW" -s session-start down >/dev/null 2>&1

check 'up keeps overlapping same-CLI launch IDs unrecorded' \
  env CREW_NO_SWITCH=1 CREW_BOOT_WAIT=4 CLAUDE_CONFIG_DIR="$start_home" \
    "$CREW" up session-overlap --in "$TS" \
      "lead=$start_cli_dir/claude --id overlap-lead" "rev=$start_cli_dir/claude --id overlap-rev"
check 'overlapping session lookup refuses to guess' \
  bash -c 'CLAUDE_CONFIG_DIR="$1" CREW_SESSION=session-overlap CREW_AGENT=lead "$2" -s session-overlap session lead 2>&1 | grep -q "no unique claude session found"' _ "$start_home" "$CREW"
check 'overlapping sessions stay unrecorded for both roles' \
  awk -F '\t' '$4!=""{f=1} END{exit f}' "$CREW_HOME/session-overlap/sessions.tsv"
"$CREW" -s session-overlap down >/dev/null 2>&1
unlink "$start_cli_dir/claude"
rmdir "$start_cli_dir"

fork_command() {
  bash -c '
    short_cli() { local w="${1%% *}"; w="${w##*/}"; printf "%s" "$w"; }
    die() { echo "$*" >&2; exit 1; }
    . "$1/sessions.sh"
    session_fork_command "$2" "$3"
  ' _ "$ROOT/share/crew" "$1" "$2"
}
check 'Claude fork uses resume and fork-session options' \
  test "$(fork_command 'claude --source-flag' fork-source-id)" = 'claude --source-flag --resume fork-source-id --fork-session'
check 'Codex fork uses the fork subcommand' \
  test "$(fork_command 'codex --source-flag' fork-source-id)" = 'codex --source-flag fork fork-source-id'
check 'pi fork uses the fork option' \
  test "$(fork_command 'pi --source-flag' fork-source-id)" = 'pi --source-flag --fork fork-source-id'

session_test_crew session-fork-ambiguous claude
printf 'rev\t%%999994\tclaude\tspawned\n' >> "$CREW_HOME/session-fork-ambiguous/panes"
check 'fork refuses an ambiguous source session' \
  bash -c 'CLAUDE_CONFIG_DIR="$1" "$2" -s session-fork-ambiguous add forked=fork:lead 2>&1 | grep -q "another claude role shares"' _ "$claude_home" "$CREW"

fork_dir="$CREW_HOME/session-fork"
fork_bin="$CREW_HOME/fork-bin"
fork_home="$CREW_HOME/fork-claude-config"
mkdir -p "$fork_dir/inbox" "$fork_dir/out" "$fork_dir/roles" "$fork_bin" "$fork_home/projects/$claude_slug"
fork_source_pane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" 'sleep 300')
fork_source_window=$(tmux display-message -p -t "$fork_source_pane" '#{window_id}')
fork_source_cli="$fork_bin/claude --source-flag"
printf 'mode=up\nwindow=%s\ncwd=%s\n' "$fork_source_window" "$session_project" > "$fork_dir/meta"
: > "$fork_dir/board.tsv"
: > "$fork_dir/channel.log"
printf 'lead\t%s\t%s\tadopted\n' "$fork_source_pane" "$fork_source_cli" > "$fork_dir/panes"
printf 'lead\tclaude\t%s\tfork-source-id\n' "$session_project" > "$fork_dir/sessions.tsv"
tmux set-option -p -t "$fork_source_pane" @crew_session session-fork
tmux set-option -p -t "$fork_source_pane" @crew_role lead
cat > "$fork_bin/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$CREW_HOME/fork-cli-args"
exec -a claude /bin/bash -c '
  IFS= read -r first_message
  printf '{}\n' > "$fork_home/projects/$claude_slug/fork-created-id.jsonl"
  exec -a claude /bin/sleep 300
'
EOF
chmod +x "$fork_bin/claude"
check 'fork has no native session file before its first input' \
  test ! -f "$fork_home/projects/$claude_slug/fork-created-id.jsonl"
check 'crew add accepts fork:source role syntax' \
  env CREW_BOOT_WAIT=4 "$CREW" -s session-fork add forked=fork:lead ordinary=cat
check 'fork CLI creates its native file only after its first input' \
  test -f "$fork_home/projects/$claude_slug/fork-created-id.jsonl"
check 'forked role keeps a pending ID and launch epoch after add' \
  awk -F '\t' '$1=="forked" && $2=="claude" && $4=="" && $5 ~ /^[0-9]+$/{f=1} END{exit !f}' \
    "$fork_dir/sessions.tsv"
check 'forked role lazily captures its own ID on a later crew command' \
  env CLAUDE_CONFIG_DIR="$fork_home" CREW_SESSION=session-fork CREW_AGENT=forked \
    "$CREW" -s session-fork status
check 'forked role records its own first-input session ID' \
  awk -F '\t' '$1=="forked" && $2=="claude" && $4=="fork-created-id"{f=1} END{exit !f}' \
    "$fork_dir/sessions.tsv"
check 'source session ID remains pinned beside the fork ID' \
  awk -F '\t' '$1=="lead" && $4=="fork-source-id"{f=1} END{exit !f}' \
    "$fork_dir/sessions.tsv"
check 'forked role keeps the source CLI spec for later resume' \
  awk -F '\t' -v cli="$fork_source_cli" '$1=="forked" && $3==cli && $4=="spawned"{f=1} END{exit !f}' "$fork_dir/panes"
check 'regular additions keep their own launch command beside a fork' \
  awk -F '\t' '$1=="ordinary" && $3=="cat" && $4=="spawned"{f=1} END{exit !f}' "$fork_dir/panes"
check 'fork command receives source flags and exact native session ID' \
  awk 'NR==1&&$0=="--source-flag"{a=1} NR==2&&$0=="--resume"{b=1} NR==3&&$0=="fork-source-id"{c=1} NR==4&&$0=="--fork-session"{d=1} END{exit !(a&&b&&c&&d)}' "$CREW_HOME/fork-cli-args"
"$CREW" -s session-fork down >/dev/null 2>&1
