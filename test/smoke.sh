#!/usr/bin/env bash
# Smoke test for crew: runs a throwaway crew of `cat` agents in a detached
# tmux session with its own CREW_HOME, so it never touches real crews.
#   test/smoke.sh          run it
#   KEEP=1 test/smoke.sh   leave the tmux session and files for inspection
set -uo pipefail
# Test identities must not inherit the agent pane running this suite.
unset TMUX_PANE CREW_AGENT CREW_SESSION

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
screen_has() { tmux capture-pane -p -J -t "$1" | grep -qF -- "$2"; }
human() { script -q /dev/null "$@" </dev/null >/dev/null 2>&1; }  # run with a tty, as the human would
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
for i in 1 2 3 4 5; do as impl send lead "burst-$i" >/dev/null & done; wait; sleep 0.5
check "parallel rings all arrive"       test "$(tmux capture-pane -p -J -t "$lead" | grep -c '^\[crew\] impl → lead: burst-[1-5]$')" -ge 5
check "parallel rings don't interleave" bash -c "! tmux capture-pane -p -J -t $lead | grep -q 'burst-.*burst-'"
check "no stale ring lock"              bash -c "! ls -d '$D'/.ring*.lock 2>/dev/null"
check "worker cannot broadcast"         bash -c "! CREW_SESSION=t CREW_AGENT=rev '$CREW' send @all hi"
check "you (terminal) can broadcast"    human "$CREW" -s t send @all "pause"
check "broadcast rung as you (terminal)" screen_has "$impl" "[crew] you (terminal) → @all: pause"
"$CREW" -s t send lead "from nowhere" >/dev/null 2>&1; sleep 0.3
check "non-tty non-member is 'outside'" screen_has "$lead" "[crew] outside"
check "outside cannot broadcast"        bash -c "! '$CREW' -s t send @all nope"
check "crew say refuses without a tty"  bash -c "! '$CREW' -s t say lead hi"
check "crew say works for the human"    human "$CREW" -s t say lead "ship it"
sleep 0.3
check "say rung as you (terminal)"      screen_has "$lead" "[crew] you (terminal) → lead: ship it"
as lead note "rejected R3" >/dev/null
check "note lands in the log"           grep -qF 'note (lead): rejected R3' "$D/channel.log"
check "whoami hints in a foreign pane"  bash -c "TMUX_PANE=%999999 '$CREW' -s t whoami 2>&1 | grep -q \"isn't in crew t\""
check "identity from env"               bash -c "CREW_SESSION=t CREW_AGENT=rev '$CREW' whoami | grep -q '^rev '"
check "identity from pane id"           bash -c "TMUX_PANE=$impl '$CREW' whoami | grep -q '^impl '"

for i in $(seq 1 15); do as lead task add --to rev "task $i" >/dev/null 2>&1 & done; wait
check "15 parallel adds → 15 unique ids" test "$(cut -f1 "$D/board.tsv" | sort -u | wc -l | tr -d ' ')" = 15
for i in $(seq 1 15); do as rev task set "T$i" done >/dev/null 2>&1 & done; wait
check "15 parallel sets all applied"    test "$(awk -F'\t' '$3=="done"' "$D/board.tsv" | wc -l | tr -d ' ')" = 15
check "worker can't set another's task" bash -c "! CREW_SESSION=t CREW_AGENT=impl '$CREW' task set T1 working"
check "no stale board lock"             test ! -e "$D/.board.lock"
check "task message has absolute path"  grep -qF "Write $D/out/T1-rev.md" "$D/inbox/rev.md"
id=$(as lead task add --to impl --out R1-impl.md "review round 1")
check "task add --out sets the one path" awk -F'\t' -v id="$id" '$1==id && $5=="out/R1-impl.md"{f=1} END{exit !f}' "$D/board.tsv"
check "task message uses the --out path" grep -qF "Write $D/out/R1-impl.md" "$D/inbox/impl.md"
check "task add rejects --out outside out/" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' task add --to impl --out ../x.md oops"
as impl task set "$id" done --evidence out/R1-tests.log >/dev/null
check "task set --evidence is stored"   awk -F'\t' -v id="$id" '$1==id && $7=="out/R1-tests.log"{f=1} END{exit !f}' "$D/board.tsv"
check "board shows EVIDENCE column"     bash -c "'$CREW' -s t board | head -1 | grep -q EVIDENCE"

# rebind: impl moves to a new pane (running cat, like the others)
newp=$(tmux split-window -d -P -F '#{pane_id}' -t "$impl" cat)
as lead rebind impl "$newp" >/dev/null
check "rebind rewrites the panes row"   awk -F'\t' -v p="$newp" '$1=="impl" && $2==p && $3=="cat" && $4=="adopted"{f=1} END{exit !f}' "$D/panes"
check "rebind labels the new pane"      test "$(tmux display -p -t "$newp" '#{@crew_session}/#{@crew_role}')" = "t/impl"
check "rebind unlabels the old pane"    test -z "$(tmux display -p -t "$impl" '#{@crew_role}')"
as lead send impl "after rebind" >/dev/null; sleep 0.3
check "messages ring the new pane"      screen_has "$newp" "[crew] lead → impl: after rebind"
check "rebind refuses a crew member's pane" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' rebind impl $lead"
check "restyle runs"                    "$CREW" -s t restyle
impl=$newp

# Mid-work handover preserves the board/history and changes actual identity,
# even though spawned agent processes still have their original CREW_AGENT.
active=$(as lead task add --to impl "unfinished implementation")
as impl task set "$active" working >/dev/null
cp "$D/inbox/lead.md" "$CREW_HOME/lead-history"
check "worker cannot override roles" bash -c "! CREW_SESSION=t CREW_AGENT=rev '$CREW' override lead impl"
check "override rejects identical roles" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead lead"
# A failed second lock must release only the lock this command acquired.
cp "$D/panes" "$CREW_HOME/panes-before-lock-failure"
mkdir "$D/.board.lock"
check "override fails when board is locked" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead impl"
check "failed override preserves bindings" cmp "$D/panes" "$CREW_HOME/panes-before-lock-failure"
check "failed override releases panes lock" test ! -e "$D/.panes.lock"
check "failed override leaves another caller's lock" test -d "$D/.board.lock"
rmdir "$D/.board.lock"
check "human can override lead" human "$CREW" -s t override lead impl
check "override swaps the lead pane" test "$(awk -F'\t' '$1=="lead"{print $2}' "$D/panes")" = "$impl"
check "override preserves the pane origin" awk -F'\t' -v p="$lead" '$1=="impl" && $2==p && $4=="spawned"{f=1} END{exit !f}' "$D/panes"
check "override transfers unfinished replacement tasks" awk -F'\t' -v id="$active" '$1==id && $2=="lead" && $3=="working"{f=1} END{exit !f}' "$D/board.tsv"
check "override keeps completed task owners" awk -F'\t' -v id="$id" '$1==id && $2=="impl" && $3=="done" && $7=="out/R1-tests.log"{f=1} END{exit !f}' "$D/board.tsv"
check "new lead identity ignores stale env" bash -c "CREW_SESSION=t CREW_AGENT=impl TMUX_PANE=$impl '$CREW' whoami | grep -q '^lead '"
check "old lead loses broadcast privilege" bash -c "! CREW_SESSION=t CREW_AGENT=lead TMUX_PANE=$lead '$CREW' send @all nope"
check "new lead can broadcast" env CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$impl" "$CREW" send @all "takeover confirmed"
check "override preserves existing inbox history" bash -c "head -c $(wc -c < "$CREW_HOME/lead-history" | tr -d ' ') '$D/inbox/lead.md' | cmp - '$CREW_HOME/lead-history'"
check "new lead gets recovery instructions" grep -q 'recover the ongoing work' "$D/inbox/lead.md"
check "handover includes old pane context" bash -c "cat '$D'/out/override-lead-*.md | grep -q 'Previous lead pane'"
check "override releases both locks" test ! -e "$D/.panes.lock"
check "override releases board lock" test ! -e "$D/.board.lock"
# Restore the original occupants for the existing lifecycle assertions.
human "$CREW" -s t override lead impl

# An unlabelled new pane can take over too; it remains adopted on down.
fresh=$(tmux split-window -d -P -F '#{pane_id}' -t "$impl" cat)
check "human can adopt a successor" human "$CREW" -s t override lead "$fresh"
check "new pane takes over as adopted lead" awk -F'\t' -v p="$fresh" '$1=="lead" && $2==p && $4=="adopted"{f=1} END{exit !f}' "$D/panes"
check "replaced lead is unlabelled and kept open" test -z "$(tmux display -p -t "$lead" '#{@crew_role}')"
check "detached lead cannot use stale env identity" bash -c "CREW_SESSION=t CREW_AGENT=lead TMUX_PANE=$lead '$CREW' whoami | grep -q '^outside '"
human "$CREW" -s t override lead "$lead"
tmux kill-pane -t "$fresh"
if command -v bun >/dev/null; then
  port=$((20000 + $$ % 20000))
  CREW_WEB_PORT=$port bun "$ROOT/share/crew/web.ts" >/dev/null 2>&1 & web=$!
  sleep 1
  check "web: state lists 3 agents"     bash -c "curl -s 'http://127.0.0.1:$port/api/state?s=t' | grep -o '\"role\"' | wc -l | grep -q 3"
  check "web: rejects path traversal"   bash -c "curl -s 'http://127.0.0.1:$port/api/file?s=t&p=../panes' | grep -q 'bad path'"
  check "web: rejects foreign Host"     bash -c "test \$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' http://127.0.0.1:$port/) = 403"
  check "web: send off by default"      bash -c "test \$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: http://127.0.0.1:$port' 'http://127.0.0.1:$port/api/send?s=t') = 403"
  kill "$web" 2>/dev/null; wait "$web" 2>/dev/null
  CREW_WEB_PORT=$port CREW_WEB_ALLOW_SEND=1 CREW_BIN="$CREW" bun "$ROOT/share/crew/web.ts" >/dev/null 2>&1 & web=$!
  sleep 1
  tok=$(curl -s "http://127.0.0.1:$port/api/config" | sed -E 's/.*"token":"([0-9a-f]+)".*/\1/')
  post() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $1" -H "x-crew-token: $2" -H 'content-type: application/json' \
    -d '{"to":"lead","text":"hello from the browser"}' "http://127.0.0.1:$port/api/send?s=t"; }
  check "web send: needs the token"     test "$(post "http://127.0.0.1:$port" wrong)" = 403
  check "web send: needs our Origin"    test "$(post "http://evil.example" "$tok")" = 403
  check "web send: delivers"            test "$(post "http://127.0.0.1:$port" "$tok")" = 200
  sleep 0.3
  check "web send rung as you (web)"    screen_has "$lead" "[crew] you (web) → lead: hello from the browser"
  kill "$web" 2>/dev/null; wait "$web" 2>/dev/null
fi

check "subcommand --help exits 0"       "$CREW" send --help
check "unknown command exits 1"         bash -c "! '$CREW' bogus"

# Simulate pane-id reuse: rev's pane loses its crew labels (as a fresh pane would).
rev=$(awk -F'\t' '$1=="rev"{print $2}' "$D/panes")
tmux set-option -p -u -t "$rev" @crew_role; tmux set-option -p -u -t "$rev" @crew_session
tmux send-keys -t "$rev" C-c; sleep 0.3; tmux send-keys -t "$rev" "clear" Enter; sleep 0.3
check "override refuses a reused pane" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead rev"
check "override refuses a stale pane reference" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead $rev"
as lead send rev "should not ring" >/dev/null 2>&1
check "no ring into a reused pane"      bash -c "! tmux capture-pane -p -t $rev | grep -q 'should not ring'"
check "message still saved to inbox"    grep -q 'should not ring' "$D/inbox/rev.md"
check "peek refuses a reused pane"     bash -c "! '$CREW' -s t peek rev"
check "status marks reused pane STALE"  bash -c "'$CREW' -s t status | grep -q 'STALE'"

"$CREW" -s t down >/dev/null 2>&1
check "down leaves the reused pane open" tmux display -p -t "$rev" '#{pane_id}'
check "down keeps the adopted successor lead" tmux display -p -t "$lead" '#{pane_id}'
check "down leaves rebound pane open"   tmux display -p -t "$impl" '#{pane_id}'
check "down marks crew ended"           test -f "$D/ended"

# --self --here: an existing pane joins as lead; others split into its window.
self=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:")
TMUX_PANE=$self "$CREW" up s --self lead --here impl=cat >/dev/null 2>&1
check "--self registers caller as adopted" awk -F'\t' -v p="$self" '$1=="lead" && $2==p && $4=="adopted"{f=1} END{exit !f}' "$CREW_HOME/s/panes"
check "--here splits caller's window"   test "$(tmux display -p -t "$self" '#{window_panes}')" = 2
self_worker=$(awk -F'\t' '$1=="impl"{print $2}' "$CREW_HOME/s/panes")
TMUX_PANE=$self "$CREW" down >/dev/null
check "down closes a spawned worker" bash -c "! tmux display -p -t $self_worker '#{pane_id}' 2>/dev/null | grep -q ."
check "down keeps the adopted pane"     tmux display -p -t "$self" '#{pane_id}'
check "down unlabels the adopted pane"  test -z "$(tmux display -p -t "$self" '#{@crew_role}')"

# Bad specs fail before anything is created.
wins=$(tmux list-windows -t "$TS" | wc -l)
check "up refuses a duplicate role"     bash -c "! '$CREW' up q --in $TS a=cat a=cat"
check "  and opens no window"           test "$(tmux list-windows -t "$TS" | wc -l)" = "$wins"
check "  and leaves no crew dir"        test ! -e "$CREW_HOME/q"
check "adopt refuses a missing pane"    bash -c "! '$CREW' adopt r x=$self y=%999999"
check "  and labels nothing"            test -z "$(tmux display -p -t "$self" '#{@crew_role}')"
check "  and leaves no crew dir"        test ! -e "$CREW_HOME/r"
check "adopt refuses one pane twice"    bash -c "! '$CREW' adopt r x=$self y=$self"

# A pane showing a startup dialog gets no intro (Enter would answer the dialog).
err=$("$CREW" up dlg --in "$TS" "d=printf 'Trust this folder?\\nEnter to confirm\\n'; cat" 2>&1 >/dev/null)
dlg=$(awk -F'\t' '$1=="d"{print $2}' "$CREW_HOME/dlg/panes")
check "no intro typed into a dialog"    bash -c "! tmux capture-pane -p -J -t $dlg | grep -q \"You are agent 'd'\""
check "  and crew says how to send it"  bash -c "printf '%s' \"\$1\" | grep -q 'startup dialog'" _ "$err"
replacement_dialog=$(tmux split-window -d -P -F '#{pane_id}' -t "$dlg" "printf 'Trust this folder?\nEnter to confirm\n'; cat")
sleep 0.3
check "human can override into a dialog pane" human "$CREW" -s dlg override d "$replacement_dialog"
check "override does not type into a dialog" bash -c "! tmux capture-pane -p -J -t $replacement_dialog | grep -q 'You are now'"
check "ordinary messages also leave dialogs alone" human "$CREW" -s dlg send d "dialog message must stay in inbox"
check "ordinary dialog message stays in inbox" grep -q 'dialog message must stay in inbox' "$CREW_HOME/dlg/inbox/d.md"
check "ordinary message does not answer dialog" bash -c "! tmux capture-pane -p -J -t $replacement_dialog | grep -q 'dialog message must stay in inbox'"
check "override saves dialog handover to inbox" grep -q 'recover the ongoing work' "$CREW_HOME/dlg/inbox/d.md"
"$CREW" -s dlg down >/dev/null 2>&1

# A spec whose command exits leaves a bare shell: warn, send no intro.
err=$("$CREW" up gone --in "$TS" "g=true" 2>&1 >/dev/null)
gone=$(awk -F'\t' '$1=="g"{print $2}' "$CREW_HOME/gone/panes")
check "failed command gets no intro"    bash -c "! tmux capture-pane -p -J -t $gone | grep -q \"You are agent 'g'\""
check "  and crew says it failed"       bash -c "printf '%s' \"\$1\" | grep -q 'back at a shell prompt'" _ "$err"
"$CREW" -s gone down >/dev/null 2>&1

[ "$fail" = 0 ] && echo "all passed" || { echo "some checks failed"; exit 1; }
