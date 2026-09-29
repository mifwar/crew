#!/usr/bin/env bash
# Smoke test for crew: runs a throwaway crew of `cat` agents in a detached
# tmux session with its own CREW_HOME, so it never touches real crews.
#   test/smoke.sh          run it
#   KEEP=1 test/smoke.sh   leave the tmux session and files for inspection
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CREW="$ROOT/bin/crew"
export CREW_HOME; CREW_HOME=$(mktemp -d "${TMPDIR:-/tmp}/crew-smoke.XXXXXX")
export CREW_BOOT_WAIT=4 CREW_NO_SWITCH=1
TS="crew-smoke-$$"
fail=0

check() { # description, then a command that must succeed
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$what"; else printf 'FAIL  %s\n' "$what"; fail=1; fi
}
as() { # role, then crew args — run crew as that agent
  local role="$1"; shift
  CREW_SESSION=t CREW_AGENT="$role" "$CREW" "$@"
}
screen_has() { tmux capture-pane -p -t "$1" | grep -qF -- "$2"; }
cleanup() {
  [ -n "${KEEP:-}" ] && { echo "kept: tmux session $TS, CREW_HOME=$CREW_HOME"; return; }
  tmux kill-session -t "$TS" 2>/dev/null
  rm -rf "$CREW_HOME"
}
trap cleanup EXIT

bash -n "$CREW" || { echo "FAIL  bash -n"; exit 1; }
tmux new-session -d -s "$TS" -x 200 -y 50

"$CREW" up t --in "$TS" lead=cat "impl=cat && true" rev=cat >/dev/null 2>&1
D="$CREW_HOME/t"
lead=$(awk -F'\t' '$1=="lead"{print $2}' "$D/panes")
impl=$(awk -F'\t' '$1=="impl"{print $2}' "$D/panes")

check "up creates 3 spawned panes"      test "$(awk -F'\t' '$4=="spawned"' "$D/panes" | wc -l | tr -d ' ')" = 3
check "intro typed into lead"           screen_has "$lead" "You are agent 'lead'"
check "roles/rev.md from rev template"  grep -q 'You review' "$D/roles/rev.md"
check "roster shows short program names" grep -qF 'lead=cat, impl=cat, rev=cat' "$D/roles/lead.md"
check "pane labelled with role"         test "$(tmux display -p -t "$impl" '#{@crew_role}')" = impl

as impl send lead "T1 done" >/dev/null; sleep 0.5
check "dm rings recipient pane"         screen_has "$lead" "[crew] impl → lead: T1 done"
check "dm logged"                       awk -F'\t' '$2=="dm" && $3=="impl" && $4=="lead" && $5=="T1 done"{f=1} END{exit !f}' "$D/channel.log"
check "dm saved to inbox"               grep -q 'T1 done' "$D/inbox/lead.md"
check "worker cannot broadcast"         bash -c "! CREW_SESSION=t CREW_AGENT=rev '$CREW' send @all hi"
check "you can broadcast"               "$CREW" -s t send @all "pause"
check "identity from env"               bash -c "CREW_SESSION=t CREW_AGENT=rev '$CREW' whoami | grep -q '^rev '"
check "identity from pane id"           bash -c "TMUX_PANE=$impl '$CREW' whoami | grep -q '^impl '"

for i in $(seq 1 15); do as lead task add --to rev "task $i" >/dev/null 2>&1 & done; wait
check "15 parallel adds → 15 unique ids" test "$(cut -f1 "$D/board.tsv" | sort -u | wc -l | tr -d ' ')" = 15
for i in $(seq 1 15); do as rev task set "T$i" done >/dev/null 2>&1 & done; wait
check "15 parallel sets all applied"    test "$(awk -F'\t' '$3=="done"' "$D/board.tsv" | wc -l | tr -d ' ')" = 15
check "no stale board lock"             test ! -e "$D/.board.lock"
check "task message has absolute path"  grep -qF "Write $D/out/T1-rev.md" "$D/inbox/rev.md"

if command -v bun >/dev/null; then
  port=$((20000 + $$ % 20000))
  CREW_WEB_PORT=$port bun "$ROOT/share/crew/web.ts" >/dev/null 2>&1 & web=$!
  sleep 1
  check "web: state lists 3 agents"     bash -c "curl -s 'http://127.0.0.1:$port/api/state?s=t' | grep -o '\"role\"' | wc -l | grep -q 3"
  check "web: rejects path traversal"   bash -c "curl -s 'http://127.0.0.1:$port/api/file?s=t&p=../panes' | grep -q 'bad path'"
  check "web: rejects foreign Host"     bash -c "test \$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' http://127.0.0.1:$port/) = 403"
  kill "$web" 2>/dev/null; wait "$web" 2>/dev/null
fi

check "subcommand --help exits 0"       "$CREW" send --help
check "unknown command exits 1"         bash -c "! '$CREW' bogus"

# Simulate pane-id reuse: rev's pane loses its crew labels (as a fresh pane would).
rev=$(awk -F'\t' '$1=="rev"{print $2}' "$D/panes")
tmux set-option -p -u -t "$rev" @crew_role; tmux set-option -p -u -t "$rev" @crew_session
tmux send-keys -t "$rev" C-c; sleep 0.3; tmux send-keys -t "$rev" "clear" Enter; sleep 0.3
as lead send rev "should not ring" >/dev/null 2>&1
check "no ring into a reused pane"      bash -c "! tmux capture-pane -p -t $rev | grep -q 'should not ring'"
check "message still saved to inbox"    grep -q 'should not ring' "$D/inbox/rev.md"
check "status marks reused pane STALE"  bash -c "'$CREW' -s t status | grep -q 'STALE'"

"$CREW" -s t down >/dev/null 2>&1
check "down leaves the reused pane open" tmux display -p -t "$rev" '#{pane_id}'
check "down closes spawned panes"       bash -c "! tmux display -p -t $impl '#{pane_id}' 2>/dev/null | grep -q ."
check "down marks crew ended"           test -f "$D/ended"

# --self --here: an existing pane joins as lead; others split into its window.
self=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:")
TMUX_PANE=$self "$CREW" up s --self lead --here impl=cat >/dev/null 2>&1
check "--self registers caller as adopted" awk -F'\t' -v p="$self" '$1=="lead" && $2==p && $4=="adopted"{f=1} END{exit !f}' "$CREW_HOME/s/panes"
check "--here splits caller's window"   test "$(tmux display -p -t "$self" '#{window_panes}')" = 2
TMUX_PANE=$self "$CREW" down >/dev/null
check "down keeps the adopted pane"     tmux display -p -t "$self" '#{pane_id}'
check "down unlabels the adopted pane"  test -z "$(tmux display -p -t "$self" '#{@crew_role}')"

[ "$fail" = 0 ] && echo "all passed" || { echo "some checks failed"; exit 1; }
