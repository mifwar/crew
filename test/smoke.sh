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
bash -n "$ROOT/share/crew/listing.sh" || { echo "FAIL  bash -n listing.sh"; exit 1; }
bash -n "$ROOT/share/crew/pane.sh" || { echo "FAIL  bash -n pane.sh"; exit 1; }
tmux new-session -d -s "$TS" -x 200 -y 50

"$CREW" up t --in "$TS" lead=cat "impl=cat && true" rev=cat >/dev/null 2>&1
D="$CREW_HOME/t"
lead=$(awk -F'\t' '$1=="lead"{print $2}' "$D/panes")
impl=$(awk -F'\t' '$1=="impl"{print $2}' "$D/panes")

check "up creates 3 spawned panes"      test "$(awk -F'\t' '$4=="spawned"' "$D/panes" | wc -l | tr -d ' ')" = 3
check "intro typed into lead"           screen_has "$lead" "You are agent 'lead'"
check "roles/rev.md from rev template"  grep -q 'You review' "$D/roles/rev.md"
check "role file points to the live roster" grep -qF "For the current roster, read \`$D/panes\`" "$D/roles/lead.md"
check "pane labelled with role"         test "$(tmux display -p -t "$impl" '#{@crew_role}')" = impl

# A helper started earlier on the tty (a hook's caffeinate) must not hide the agent.
mkdir -p "$CREW_HOME/helper"; ln -s /bin/cat "$CREW_HOME/helper/codex"
helper=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS" "sleep 300 & sleep 0.3; exec '$CREW_HOME/helper/codex'")
sleep 1
check "detect_cli prefers the agent over an earlier helper" \
  test "$(bash -c "$(sed -n '/^short_cli()/,/^}/p;/^detect_cli()/,/^}/p' "$CREW"); detect_cli $helper")" = codex
tmux kill-pane -t "$helper"

# 16 prefix bytes + 52 ASCII bytes put byte 70 inside the final arrow.
utf8_message="$(printf '%052d' 0)→ café 😀 tail"
as impl send lead "$utf8_message" >/dev/null
status_file="$CREW_HOME/status-utf8"
check "status survives a mid-UTF-8 byte boundary" bash -c '"$1" -s t status > "$2"' _ "$CREW" "$status_file"
check "status retains every agent row" test "$(awk '$1=="lead" || $1=="impl" || $1=="rev"{n++} END{print n}' "$status_file")" = 3
check "status output is valid UTF-8" iconv -f UTF-8 -t UTF-8 "$status_file"
check "status truncates by characters" grep -qF "${utf8_message:0:55}" "$status_file"
check "healthy lead has no recovery hint" bash -c '"$1" -s t status > "$2" && ! grep -q "if lead is dead" "$2"' _ "$CREW" "$CREW_HOME/status-healthy-lead"

as impl send lead "T1 done" >/dev/null; sleep 0.5
check "dm rings recipient pane"         screen_has "$lead" "[crew] impl → lead: T1 done"
check "dm logged"                       awk -F'\t' '$2=="dm" && $3=="impl" && $4=="lead" && $5=="T1 done"{f=1} END{exit !f}' "$D/channel.log"
check "dm saved to inbox"               grep -q 'T1 done' "$D/inbox/lead.md"
for i in 1 2 3 4 5; do as impl send lead "burst-$i" >/dev/null & done; wait; sleep 0.5
check "parallel rings all arrive"       test "$(tmux capture-pane -p -J -t "$lead" | grep -c '^\[crew\] impl → lead: burst-[1-5]$')" -ge 5
check "parallel rings don't interleave" bash -c "! tmux capture-pane -p -J -t $lead | grep -q 'burst-.*burst-'"
check "no stale ring lock"              bash -c "! ls -d '$D'/.ring*.lock 2>/dev/null"
as lead send impl,rev "pair-msg" >/dev/null; sleep 0.5
check "send to a list rings each"       bash -c "tmux capture-pane -p -J -t $impl | grep -qF '[crew] lead → impl: pair-msg' && grep -q pair-msg '$D/inbox/rev.md'"
check "  and logs one dm each"          test "$(awk -F'\t' '$2=="dm" && $5=="pair-msg"' "$D/channel.log" | wc -l | tr -d ' ')" = 2
check "a list with a bad name sends nothing" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' send impl,nobody lost-msg 2>/dev/null && ! grep -q lost-msg '$D/inbox/impl.md'"
check "worker cannot broadcast"         bash -c "! CREW_SESSION=t CREW_AGENT=rev '$CREW' send @all hi"
check "you (terminal) can broadcast"    human "$CREW" -s t send @all "pause"
check "broadcast rung as you (terminal)" screen_has "$impl" "[crew] you (terminal) → @all: pause"
"$CREW" -s t send lead "from nowhere" >/dev/null 2>&1; sleep 0.3
check "non-tty non-member is 'outside'" screen_has "$lead" "[crew] outside"
check "outside send warns with the reason and whoami hint" bash -c 'CREW_SESSION=other CREW_AGENT=impl TMUX_PANE=%999999 "$1" -s t send lead "warn-check" 2> "$2" >/dev/null; grep -q "sending as outside (not in crew t): CREW_SESSION=other does not match crew t; see: crew -s t whoami" "$2"' _ "$CREW" "$CREW_HOME/outside-send-err"
check "  and the outside doorbell label is unchanged" screen_has "$lead" "[crew] outside %999999 (not in this crew) → lead: warn-check"
check "outside multi-send warns once" bash -c 'CREW_SESSION=other CREW_AGENT=impl TMUX_PANE=%999999 "$1" -s t send impl,rev "multi-warn" 2> "$2" >/dev/null; test "$(grep -c "sending as outside" "$2")" = 1' _ "$CREW" "$CREW_HOME/outside-multi-err"
check "outside cannot broadcast"        bash -c "! '$CREW' -s t send @all nope"
check "crew say refuses without a tty"  bash -c "! '$CREW' -s t say lead hi"
check "crew say works for the human"    human "$CREW" -s t say lead "ship it"
sleep 0.3
check "say rung as you (terminal)"      screen_has "$lead" "[crew] you (terminal) → lead: ship it"
as rev send lead "inbox-marker" >/dev/null; as lead send impl "inbox-impl-last" >/dev/null; sleep 0.3
check "inbox prints whole entries"      bash -c "'$CREW' -s t inbox lead | grep -q inbox-marker"
check "inbox --last keeps only the newest" bash -c "'$CREW' -s t inbox lead --last | grep -q inbox-marker && ! '$CREW' -s t inbox lead --last | grep -q 'ship it'"
check "inbox --last N keeps the newest N" bash -c "'$CREW' -s t inbox lead --last 2 | grep -q 'ship it'"
check "inbox --from filters by sender"  bash -c "'$CREW' -s t inbox lead --from rev | grep -q inbox-marker && ! '$CREW' -s t inbox lead --from rev | grep -q 'ship it'"
check "inbox --from you covers both channels" bash -c "'$CREW' -s t inbox lead --from you | grep -q 'ship it'"
inbox_minute=$(awk -F'  ' '/^## /{print substr($1, 15, 5)}' "$D/inbox/lead.md" | tail -n 1)
check "inbox --since keeps that minute" bash -c "'$CREW' -s t inbox lead --since $inbox_minute | grep -q inbox-marker"
check "inbox --since drops older entries" bash -c "! '$CREW' -s t inbox lead --since 24:00 | grep -q inbox-marker"
check "inbox defaults to the caller's role" bash -c "CREW_SESSION=t CREW_AGENT=impl '$CREW' inbox --last | grep -q inbox-impl-last"
check "inbox works for the human"       human "$CREW" -s t inbox --last
check "inbox refuses an unknown role"   bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' inbox nobody"
check "inbox refuses a bad --since"     bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' inbox lead --since 9am"
as rev send lead "$(awk 'BEGIN{for(i=0;i<520;i++)printf "x"}')" >/dev/null; sleep 0.5
check "long doorbells name crew inbox --last" screen_has "$lead" "crew inbox --last"
as rev send lead $'body one\n## Findings\nbody two' >/dev/null; sleep 0.3
check "inbox --last keeps a body with an H2" bash -c "'$CREW' -s t inbox lead --last | grep -q 'body one' && '$CREW' -s t inbox lead --last | grep -q 'body two'"
check "inbox --from keeps a body with an H2" bash -c "'$CREW' -s t inbox lead --from rev --last | grep -q 'body one' && '$CREW' -s t inbox lead --from rev --last | grep -q Findings"
inbox_minute=$(awk '/^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/{print substr($0, 15, 5)}' "$D/inbox/lead.md" | tail -n 1)
check "inbox --since keeps a body with an H2" bash -c "'$CREW' -s t inbox lead --since $inbox_minute | grep -q 'body one'"
check "inbox --last rejects a non-integer count" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' inbox lead --last 1garbage"
check "inbox --last rejects zero"        bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' inbox lead --last 0"
as lead note "rejected R3" >/dev/null
check "note lands in the log"           grep -qF 'note (lead): rejected R3' "$D/channel.log"
check "whoami hints in a foreign pane"  bash -c "TMUX_PANE=%999999 '$CREW' -s t whoami 2>&1 | grep -q \"isn't in crew t\""
check "identity from env"               bash -c "CREW_SESSION=t CREW_AGENT=rev '$CREW' whoami | grep -q '^rev '"
check "  and says the env fallback has no pane" bash -c "env -u TMUX_PANE CREW_SESSION=t CREW_AGENT=rev '$CREW' whoami | grep -q '^why: env CREW_AGENT=rev, CREW_SESSION=t; no TMUX_PANE'"
check "identity from pane id"           bash -c "TMUX_PANE=$impl '$CREW' whoami | grep -q '^impl '"
check "  and says which pane resolved it" bash -c "TMUX_PANE=$impl '$CREW' whoami | grep -q '^why: pane $impl is bound to impl'"
check "identity falls back from a missing tool-shell pane" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE=%999999 "$1" whoami | grep -q "^impl "' _ "$CREW"
check "  and reports the tool-shell pane as gone" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE=%999999 "$1" whoami | grep -q "^why: env CREW_AGENT=impl, CREW_SESSION=t; TMUX_PANE %999999 not found"' _ "$CREW"
foreign_pane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
tmux set-option -p -t "$foreign_pane" @crew_session unrelated
tmux set-option -p -t "$foreign_pane" @crew_role other
check "identity falls back from another crew's pane" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^impl "' _ "$CREW" "$foreign_pane"
check "  and says the pane belongs to that crew" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^why: env CREW_AGENT=impl, CREW_SESSION=t; TMUX_PANE $2 belongs to crew unrelated"' _ "$CREW" "$foreign_pane"
tmux set-option -p -u -t "$foreign_pane" @crew_session
check "identity rejects an unlabelled pane" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^outside "' _ "$CREW" "$foreign_pane"
check "  and says the pane is unlabelled" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^why: TMUX_PANE $2 is unlabelled"' _ "$CREW" "$foreign_pane"
tmux set-option -p -t "$foreign_pane" @crew_session t
check "identity rejects an unbound pane labelled to this crew" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^outside "' _ "$CREW" "$foreign_pane"
check "  and says the same-crew pane is bound to no role" bash -c 'CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$2" "$1" whoami | grep -q "^why: TMUX_PANE $2 is labelled for crew t but bound to no role"' _ "$CREW" "$foreign_pane"
check "fallback identity can update its own task" bash -c 'CREW_SESSION=t CREW_AGENT=lead TMUX_PANE=%999999 "$1" task add --to impl identity-check > "$2" && CREW_SESSION=t CREW_AGENT=impl TMUX_PANE=%999999 "$1" task set "$(cat "$2")" done --force' _ "$CREW" "$CREW_HOME/identity-task"
# Existing board count assertions expect the first task to be T1 below.
: > "$D/board.tsv"
check "identity fallback refuses an unknown env role" bash -c 'CREW_SESSION=t CREW_AGENT=absent TMUX_PANE=%999999 "$1" whoami | grep -q "^outside "' _ "$CREW"
check "  and says no pane is bound to that role" bash -c 'CREW_SESSION=t CREW_AGENT=absent TMUX_PANE=%999999 "$1" whoami | grep -q "^why: no pane is bound to role absent"' _ "$CREW"
check "identity fallback refuses a different crew env" bash -c 'CREW_SESSION=other CREW_AGENT=impl TMUX_PANE=%999999 "$1" -s t whoami | grep -q "^outside "' _ "$CREW"
check "  and names the mismatched session" bash -c 'CREW_SESSION=other CREW_AGENT=impl TMUX_PANE=%999999 "$1" -s t whoami | grep -q "^why: CREW_SESSION=other does not match crew t"' _ "$CREW"
check "whoami explains a missing CREW_AGENT" bash -c "env -u CREW_AGENT -u TMUX_PANE '$CREW' -s t whoami | grep -q '^why: no CREW_AGENT set'"
tmux kill-pane -t "$foreign_pane"

for i in $(seq 1 15); do as lead task add --to rev "task $i" >/dev/null 2>&1 & done; wait
check "15 parallel adds → 15 unique ids" test "$(cut -f1 "$D/board.tsv" | sort -u | wc -l | tr -d ' ')" = 15
for i in $(seq 1 15); do printf 'STATUS: DONE\n' > "$D/out/T$i-rev.md"; done
for i in $(seq 1 15); do as rev task set "T$i" done >/dev/null 2>&1 & done; wait
check "15 parallel sets all applied"    test "$(awk -F'\t' '$3=="done"' "$D/board.tsv" | wc -l | tr -d ' ')" = 15
check "worker can't set another's task" bash -c "! CREW_SESSION=t CREW_AGENT=impl '$CREW' task set T1 working"
check "no stale board lock"             test ! -e "$D/.board.lock"
check "task message has absolute path"  grep -qF "Write $D/out/T1-rev.md" "$D/inbox/rev.md"
id=$(as lead task add --to impl --out R1-impl.md "review round 1")
check "task add --out sets the one path" awk -F'\t' -v id="$id" '$1==id && $5=="out/R1-impl.md"{f=1} END{exit !f}' "$D/board.tsv"
check "task message uses the --out path" grep -qF "Write $D/out/R1-impl.md" "$D/inbox/impl.md"
check "task add rejects --out outside out/" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' task add --to impl --out ../x.md oops"
as impl task set "$id" done --evidence out/R1-tests.log >/dev/null 2>&1 || true
check "task set done refuses an unwritten result" bash -c "! CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $id done"
printf 'STATUS: DONE — verified\n' > "$D/out/R1-impl.md"
as impl task set "$id" done --evidence out/R1-tests.log >/dev/null
check "task set --evidence is stored"   awk -F'\t' -v id="$id" '$1==id && $7=="out/R1-tests.log"{f=1} END{exit !f}' "$D/board.tsv"
check "board shows EVIDENCE column"     bash -c "'$CREW' -s t board | head -1 | grep -q EVIDENCE"

# C2: done gate + {id} placeholder + next-id
gate=$(as lead task add --to impl --out gate.md "gate check")
check "next-id predicts the next add"  test "$(as lead task next-id)" = "T$(( $(wc -l < "$D/board.tsv") + 1 ))"
check "task set done refuses a missing result" bash -c "! CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $gate done"
check "  and leaves the task open"     test "$(awk -F'\t' -v id="$gate" '$1==id{print $3}' "$D/board.tsv")" = queued
: > "$D/out/gate.md"
check "empty result gets the documented error" bash -c "CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $gate done 2>&1 | grep -q 'stays open'"
check "  and the empty result stays open" test "$(awk -F'\t' -v id="$gate" '$1==id{print $3}' "$D/board.tsv")" = queued
printf '   \n\t\n\n' > "$D/out/gate.md"
check "whitespace-only result gets the documented error" bash -c "CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $gate done 2>&1 | grep -q 'stays open'"
check "  and the whitespace result stays open" test "$(awk -F'\t' -v id="$gate" '$1==id{print $3}' "$D/board.tsv")" = queued
printf 'STATUS: BLOCKED — no time\n' > "$D/out/gate.md"
check "task set done refuses a BLOCKED result" bash -c "! CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $gate done"
check "  and the error says it stays open" bash -c "CREW_SESSION=t CREW_AGENT=impl '$CREW' task set $gate done 2>&1 | grep -q 'stays open'"
printf 'STATUS: DONE — verified\n' > "$D/out/gate.md"
as impl task set "$gate" done >/dev/null
check "a STATUS: DONE result passes"  awk -F'\t' -v id="$gate" '$1==id && $3=="done"{f=1} END{exit !f}' "$D/board.tsv"
crlf=$(as lead task add --to impl --out crlf.md "crlf check")
printf 'verified\r\nSTATUS: DONE\r\n\r\n' > "$D/out/crlf.md"
as impl task set "$crlf" done >/dev/null
check "a CRLF result with a blank CR row passes" awk -F'\t' -v id="$crlf" '$1==id && $3=="done"{f=1} END{exit !f}' "$D/board.tsv"
fgate=$(as lead task add --to impl --out fgate.md "force check")
as impl task set "$fgate" done --force >/dev/null
check "--force closes without a result" awk -F'\t' -v id="$fgate" '$1==id && $3=="done"{f=1} END{exit !f}' "$D/board.tsv"
check "  and notes the force in the log" bash -c "grep -qF 'set $fgate → done' '$D/channel.log' && grep -qF '[forced]' '$D/channel.log'"
vgate=$(as lead task add --to rev --out verdict.md "review check")
printf 'FINAL: AGREE\n' > "$D/out/verdict.md"
as rev task set "$vgate" done >/dev/null
check "a FINAL: verdict passes the gate" awk -F'\t' -v id="$vgate" '$1==id && $3=="done"{f=1} END{exit !f}' "$D/board.tsv"
ph=$(as lead task add --to rev --out out/{id}-plan.md --msg "also write out/{id}-notes.md" "placeholder task")
check "task add --out expands {id}"  awk -F'\t' -v id="$ph" '$1==id && $5=="out/" id "-plan.md"{f=1} END{exit !f}' "$D/board.tsv"
check "task add --msg expands {id}"  grep -qF "out/$ph-notes.md" "$D/inbox/rev.md"

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

# install.sh: crew on PATH plus the shared skill into each agent's skills dir.
inst=$(mktemp -d "${TMPDIR:-/tmp}/crew-install.XXXXXX")
mkdir -p "$inst/.claude" "$inst/.codex" "$inst/.pi"
HOME="$inst" "$ROOT/install.sh" >/dev/null 2>&1
check "install links crew onto PATH"    test "$(readlink "$inst/.local/bin/crew")" = "$ROOT/bin/crew"
check "install links Claude skill"      test "$(readlink "$inst/.claude/skills/crew")" = "$ROOT/skills/crew"
check "install links shared skill"      test "$(readlink "$inst/.agents/skills/crew")" = "$ROOT/skills/crew"
check "install links pi skill"          test "$(readlink "$inst/.pi/agent/skills/crew")" = "$ROOT/skills/crew"
rm "$inst/.agents/skills/crew"; mkdir "$inst/.agents/skills/crew"; touch "$inst/.agents/skills/crew/keep"
HOME="$inst" "$ROOT/install.sh" >/dev/null 2>&1
check "install keeps a real skill dir"  test -f "$inst/.agents/skills/crew/keep"
mkdir "$inst/other"; rm "$inst/.pi/agent/skills/crew"; ln -s "$inst/other" "$inst/.pi/agent/skills/crew"
out=$(HOME="$inst" "$ROOT/install.sh" 2>&1)
check "install keeps a foreign symlink" test "$(readlink "$inst/.pi/agent/skills/crew")" = "$inst/other"
check "  and says so"                   bash -c "printf '%s' \"\$1\" | grep -q 'left it alone'" _ "$out"
rm "$inst/.pi/agent/skills/crew"; ln -s "$inst/gone" "$inst/.pi/agent/skills/crew"
out=$(HOME="$inst" "$ROOT/install.sh" 2>&1)
check "install keeps a dangling symlink" test "$(readlink "$inst/.pi/agent/skills/crew")" = "$inst/gone"
check "  and says so"                   bash -c "printf '%s' \"\$1\" | grep -q 'left it alone'" _ "$out"
rm -rf "$inst"

# A doorbell must never be typed into an editor holding an unsubmitted draft:
# ring()'s send-keys would append it to the draft and submit both. The
# fixtures are symlinks to /bin/sh and /bin/cat with the process names the
# detector looks for (a copy of an Apple binary is killed by macOS).
mkdir -p "$CREW_HOME/bin"
ln -s /bin/sh "$CREW_HOME/bin/claude"
printf '%s\n' 'while :; do printf "❯ "; read -r line; done' > "$CREW_HOME/bin/editor.sh"
ln -s /bin/cat "$CREW_HOME/bin/codex"
ln -s /bin/cat "$CREW_HOME/bin/pi"
"$CREW" -s t add "cl=$CREW_HOME/bin/claude $CREW_HOME/bin/editor.sh" \
  "cx=$CREW_HOME/bin/codex" "piu=$CREW_HOME/bin/pi >/dev/null" \
  "pidraft=$CREW_HOME/bin/pi >/dev/null" "flat=cat >/dev/null" >/dev/null 2>&1
cl=$(awk -F'\t' '$1=="cl"{print $2}' "$D/panes")
cx=$(awk -F'\t' '$1=="cx"{print $2}' "$D/panes")
piu=$(awk -F'\t' '$1=="piu"{print $2}' "$D/panes")
pidraft=$(awk -F'\t' '$1=="pidraft"{print $2}' "$D/panes")
flat=$(awk -F'\t' '$1=="flat"{print $2}' "$D/panes")
dashes() { awk -v n="$(( $(tmux display -p -t "$1" '#{pane_width}') - 2 ))" 'BEGIN { for (i = 0; i < n; i++) printf "─" }'; }
ndashes() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "─" }'; }
type_row() { # never type without an explicit pane: an empty target is the caller's pane
  [ -n "$1" ] || { echo "FAIL  type_row called without a pane (fixture add failed?)"; exit 1; }
  tmux send-keys -t "$1" -l "$2"; tmux send-keys -t "$1" Enter; sleep 0.2; }
[ -n "$cl" ] && [ -n "$cx" ] && [ -n "$piu" ] && [ -n "$pidraft" ] && [ -n "$flat" ] || {
  echo "FAIL  fixture panes missing ($cl/$cx/$piu/$pidraft/$flat): not typing anywhere"; exit 1; }
box() { # pane [content] — a pi editor box, cursor left below it
  type_row "$1" "$(dashes "$1")"
  [ -z "${2:-}" ] || type_row "$1" "$2"
  type_row "$1" "$(dashes "$1")"
}

# pi's box parser on synthetic frames (one argument per pane row; the dims
# argument is "pane_width pane_height cursor_y"). A missed border here is a
# doorbell typed into a draft.
. "$ROOT/share/crew/pane.sh"
pi_box() { # want(w|idle) dims row...
  local want="$1" dims="$2" got; shift 2
  got=$(printf '%s\n' "$@" | pi_box_draft "$dims")
  case "$want" in idle) [ -z "$got" ] ;; *) [ -n "$got" ] ;; esac
}
check "pi parser: 100-of-120 dashes row is content, not a border" pi_box w "120 5 4" "$(ndashes 118)" "$(ndashes 100)" "$(ndashes 118)" "" ""
check "pi parser: a labelled top border still counts" pi_box w "148 5 4" "$(printf '%s  Working  %s' "$(ndashes 62)" "$(ndashes 66)")" "draft" "$(ndashes 146)" "" ""
check "pi parser: the cursor row is never a border" pi_box w "20 3 1" "$(ndashes 18)" "$(ndashes 20)" "$(ndashes 18)"
check "pi parser: an idle box is idle" pi_box idle "120 5 4" "$(ndashes 118)" "" "$(ndashes 118)" "" ""
ptext() { # want dims row...
  local want="$1" dims="$2" got; shift 2
  got=$(printf '%s\n' "$@" | pi_box_text "$dims")
  [ "$got" = "$want" ]
}
check "pi text: wrapped draft rows join"  ptext "one two" "120 5 4" "$(ndashes 118)" "one" "two" "$(ndashes 118)" ""
check "pi text: an idle box is empty"     ptext "" "120 4 2" "$(ndashes 118)" "" "$(ndashes 118)" ""
check "claude text: after the prompt mark" test "$(printf '❯ write the answer\n' | prompt_row_text '❯' '')" = "write the answer"
claude_suggestion_text='Try "create a util logging.py that..."'
claude_suggestion=$(printf '\033[39m❯\302\240\033[2m%s\033[0m' "$claude_suggestion_text")
claude_typed_try=$(printf '\033[39m❯\302\240%s\033[0m' "$claude_suggestion_text")
claude_color_two=$(printf '\033[39m❯\302\240\033[38;5;2m%s\033[0m' "$claude_suggestion_text")
claude_dim_color=$(printf '\033[39m❯\302\240\033[2;90m%s\033[0m' "$claude_suggestion_text")
claude_mixed=$(printf '\033[39m❯\302\240\033[2m%s\033[0m typed text' "$claude_suggestion_text")
claude_reset22=$(printf '\033[39m❯\302\240\033[2m%s\033[22m typed text' "$claude_suggestion_text")
claude_generated_ghost=$(printf '\033[39m❯\302\240\033[2minclude alias memory, apply to any unmatched transfer\033[0m')
claude_context_suggestion=$(printf '\033[39m❯\302\240\033[2myes, keep unmatched moves as pending transfers\033[0m')
claude_text_is() { # expected text, ANSI prompt row...
  local want="$1" got; shift
  got=$(printf '%s\n' "$@" | pane_editor_text claude "")
  [ "$got" = "$want" ]
}
check "Claude's dim suggestion is an idle editor" claude_text_is "" "$claude_suggestion"
check "Claude's contextual yes suggestion is idle" claude_text_is "" "$claude_context_suggestion"
check "a typed Try suggestion remains a draft" claude_text_is "$claude_suggestion_text" "$claude_typed_try"
check "color index 2 is not mistaken for dim text" claude_text_is "$claude_suggestion_text" "$claude_color_two"
check "combined dim/color style stays a draft" claude_text_is "$claude_suggestion_text" "$claude_dim_color"
check "mixed dim and normal text remains a draft" claude_text_is "typed text" "$claude_mixed"
check "SGR intensity reset 22 restores draft protection" claude_text_is "typed text" "$claude_reset22"
check "Claude's generated ghost suggestion is idle" claude_text_is "" "$claude_generated_ghost"

# G2: pi's braille Working spinner in the top border used to kill the parser
# ("awk: towc: multibyte conversion failure", empty output read as free) and a
# crash now holds instead. The glyph is U+283C, built from its UTF-8 bytes.
braille=$(awk 'BEGIN { printf "%c%c%c", 226, 160, 188 }')
braille_top() { # width — a pi-shaped top border carrying the braille Working label
  local w="$1" label=" $braille Working " n left right
  n=$(( w - 2 - ${#label} ))
  [ $(( n * 100 )) -ge $(( w * 55 )) ] || { label=" $braille "; n=$(( w - 2 - ${#label} )); }
  left=$(( n * 55 / 100 )); right=$(( n - left ))
  printf '%s%s%s' "$(ndashes "$left")" "$label" "$(ndashes "$right")"
}
check "pi parser: a braille-labelled border still parses" pi_box w "120 5 4" "$(braille_top 120)" "draft text" "$(ndashes 118)" "" ""
check "pi parser: a braille-labelled idle box is idle" pi_box idle "120 5 4" "$(braille_top 120)" "" "$(ndashes 118)" "" ""
# G3 residual limit, documented in lode/cli/messaging.md: a full-width dashes
# draft row is only seen while the cursor is on it; with the cursor below the
# box reads idle. Pinned so a future fix has to change this case.
check "pi parser limit: full-width dashes draft, cursor below reads idle" pi_box idle "120 5 4" \
  "$(ndashes 118)" "$(ndashes 118)" "$(ndashes 118)" "" ""
# G2/T12: a crashed recogniser is a hold, not a free editor
check "pane_hold: a parser crash holds as unreadable" bash -c '
  tmux() { case "$1" in capture-pane) printf "frame\n" ;; *) printf "0\n" ;; esac }
  short_cli() { printf "pi"; }
  pane_cli() { printf "pi"; }
  . "$1/share/crew/pane.sh"
  pi_box_text() { printf "simulated parser error\n" >&2; return 2; }
  case "$(pane_hold %1)" in unreadable*) exit 0 ;; *) exit 1 ;; esac' _ "$ROOT"

# G1/T12: dialog UI rows, not phrases quoted in an agent's transcript
dialog_says() { # want(yes|no) row...
  local want="$1" got=no; shift
  printf '%s\n' "$@" | dialog_capture && got=yes
  [ "$got" = "$want" ]
}
check "dialogs: a codex picker footer on the last row holds" dialog_says yes \
  "  1. Switch to gpt-6-luna" "› 2. Keep current model" "  3. Never show again" "  enter select · esc back"
check "dialogs: a claude card question above a tall option list holds" dialog_says yes \
  "Do you want to proceed?" "❯ 1. Yes" "2. Always allow" "3. No" "   Esc to cancel"
check "dialogs: the claude trust wording holds" dialog_says yes \
  "│ Do you trust the files in this folder?" "│ ❯ 1. Yes, I trust this folder" "│   2. No, exit"
ansi_dialog=$(printf '\033[31mDo you want to proceed?\033[0m')
check "dialogs: SGR styling does not hide a Claude approval" dialog_says yes "$ansi_dialog"
check "pane hold: ANSI approval takes precedence over dim suggestions" bash -c '
  tmux() { case "$1" in
    capture-pane) printf "\\033[31mDo you want to proceed?\\033[0m\\n\\033[39m❯\\302\\240\\033[2myes, keep unmatched moves as pending transfers\\033[0m\\n" ;;
    display-message) printf "0\\n" ;;
  esac; }
  short_cli() { printf claude; }
  pane_cli() { printf claude; }
  . "$1/share/crew/pane.sh"
  case "$(pane_hold %1)" in dialog*) exit 0 ;; *) exit 1 ;; esac' _ "$ROOT"
check "dialogs: a startup footer on the last row holds" dialog_says yes "Trust this folder?" "Enter to confirm · Esc to cancel"
check "dialogs: a don't-ask-again option row holds" dialog_says yes \
  "❯ 2. Yes, and don't ask again for this project"
check "dialogs: prose quoting enter select is not a dialog" dialog_says no \
  " narrow the dialog region (the enter select regression from earlier),"
check "dialogs: prose quoting enter confirm mid-sentence is not one" dialog_says no \
  " - The nt helper renders enter confirm · Esc cancel but is used by oth"
check "dialogs: a question quoted mid-sentence is not one" dialog_says no \
  "the report says: Do you want to proceed? is what Claude shows"
check "dialogs: a stale footer four rows up is not one" dialog_says no \
  "  enter select · esc back" "one" "two" "three"

# G4: zero-padded waits keep their value; 0 stays the zero wait
ring_secs_is() { # want value
  local got; got=$(CREW_RING_WAIT="$2" ring_secs)
  [ "$got" = "$1" ]
}
check "ring_secs: 00000 is the zero wait"    ring_secs_is 0 00000
check "ring_secs: 000030 is 30"              ring_secs_is 30 000030
check "ring_secs: 0008 is 8"                 ring_secs_is 8 0008
check "ring_secs: 3601 caps at 3600"         ring_secs_is 3600 3601
check "ring_secs: non-digits fall back to 30" ring_secs_is 30 abc

box "$piu"
as lead send piu "pi-idle" >/dev/null 2>&1
check "an idle pi editor box gets its doorbell" screen_has "$piu" "[crew] lead → piu: pi-idle"
box "$flat" 'text between dashed rules'    # a cat pane: the pi detector must not run on it
as lead send flat "flat-idle" >/dev/null 2>&1
check "a non-pi pane with dashed rows is not held" screen_has "$flat" "[crew] lead → flat: flat-idle"

# codex: its placeholder is idle, real text is a draft. This pane echoes
# what cat reads, so a doorbell submitted with the draft would show a second
# copy of the draft row (the >/dev/null fixtures cannot catch that).
tmux send-keys -t "$cx" -l '› Ask Codex to do anything'; sleep 0.3
as lead send cx "codex-idle" >/dev/null 2>&1
check "codex's placeholder is not a draft"         screen_has "$cx" "codex-idle"
tmux send-keys -t "$cx" Enter; sleep 0.2
tmux send-keys -t "$cx" -l '› buy milk'; sleep 0.3
check "codex draft: exits 0 and types nothing" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send cx held-cx && ! tmux capture-pane -p -J -t $cx | grep -qF 'held-cx'"
check "  the draft is still exactly one copy"      bash -c "test \$(tmux capture-pane -p -J -t $cx | grep -oF '› buy milk' | wc -l) -eq 1"
check "  the message is in the inbox"              grep -q held-cx "$D/inbox/cx.md"
check "  and the log names the draft"               grep -q 'cx not rung: .*unsubmitted draft' "$D/channel.log"

# claude: dim prompt suggestions are idle, typed drafts hold the doorbell,
# the human's Enter clears a draft during the hold, and dialogs/modes hold.
claude_suggestion_script="$CREW_HOME/claude-suggestion.sh"
cat > "$claude_suggestion_script" <<'CLAUDE'
#!/bin/sh
prompt() {
  printf '❯ \302\240\033[2mTry "create a util logging.py that..."\033[0m\n'
}
prompt
while IFS= read -r line; do
  printf 'received:%s\n' "$line"
  prompt
done
CLAUDE
"$CREW" -s t add "clg=$CREW_HOME/bin/claude $claude_suggestion_script" >/dev/null 2>&1
clg=$(awk -F'\t' '$1=="clg"{print $2}' "$D/panes")
check "Claude dim suggestion does not block startup intro" screen_has "$clg" "received:[crew] You are agent 'clg'"
"$CREW" -s t status > "$CREW_HOME/status-claude-suggestion"
check "status does not flag a dim suggestion as a draft" bash -c "! awk '\$1==\"clg\" && /draft pending/' '$CREW_HOME/status-claude-suggestion' | grep -q clg"
as lead send clg "claude-suggestion-idle" >/dev/null 2>&1
check "a Claude dim suggestion accepts a doorbell" screen_has "$clg" "received:[crew] lead → clg: claude-suggestion-idle"
as lead send cl "claude-idle" >/dev/null 2>&1
check "an empty claude editor gets its doorbell" screen_has "$cl" "[crew] lead → cl: claude-idle"
tmux send-keys -t "$cl" -l 'Try "create a util logging.py that..."'; sleep 0.3
check "Claude draft beginning with Try stays protected" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send cl held-cl && ! tmux capture-pane -p -J -t $cl | grep -qF 'held-cl'"
check "  the Try draft is still exactly one copy"      bash -c "test \$(tmux capture-pane -p -J -t $cl | grep -oF 'Try' | wc -l) -eq 1"
check "  its row carries no [crew] doorbell"           bash -c "! tmux capture-pane -p -J -t $cl | grep -F 'Try' | grep -qF '[crew]'"
check "  the message is in the inbox"           grep -q held-cl "$D/inbox/cl.md"
check "  and the log names the draft"            grep -q 'cl not rung: .*unsubmitted draft' "$D/channel.log"
check "a draft that clears during the hold rings once" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=5 '$CREW' send cl clear-cl >/dev/null 2>&1 & sleep 0.4; tmux send-keys -t $cl Enter; wait; sleep 0.5; test \$(tmux capture-pane -p -J -t $cl | grep -cF '[crew] lead → cl: clear-cl') = 1"
tmux copy-mode -t "$cl"; sleep 0.3
check "copy mode: exits 0 and types nothing" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send cl copy-cl && ! tmux capture-pane -p -J -t $cl | grep -qF 'copy-cl'"
check "  the mode is still on"                   bash -c "test \"\$(tmux display -p -t $cl '#{pane_in_mode}')\" != 0"
check "  and the log names copy mode"            grep -q 'cl not rung: .*copy/choose mode' "$D/channel.log"
check "zero wait still refuses copy mode"       bash -c "start=\$SECONDS; CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=0 '$CREW' send cl zero-copy >/dev/null 2>&1; sleep 0.3; test \$((SECONDS - start)) -lt 5 && ! tmux capture-pane -p -J -t $cl | grep -qF 'zero-copy'"
tmux copy-mode -q -t "$cl"

# pi's draft is only a draft between the box's two borders
box "$pidraft" 'draft inside the box'
check "pi draft between the borders holds" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send pidraft held-pi && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'held-pi'"
check "  and the log names the draft"       grep -q 'pidraft not rung: .*unsubmitted draft' "$D/channel.log"

# F1: a draft row that is mostly dashes (100 of 120 cols) is content, not the
# box's top border. 70 % is > the old 60 % threshold and < width - 3.
pw=$(tmux display -p -t "$pidraft" '#{pane_width}')
box "$pidraft" "$(ndashes $((pw * 7 / 10)))"
check "a dashes-only pi draft row holds" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send pidraft held-dash && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'held-dash'"
check "  and the log names the draft"     grep -q 'pidraft not rung: .*unsubmitted draft' "$D/channel.log"

# G2 end to end: a real-shaped braille Working border, a draft between the
# borders. The reason must be the draft, not an unreadable editor.
type_row "$pidraft" "$(braille_top "$pw")"
type_row "$pidraft" 'draft under a braille border'
type_row "$pidraft" "$(dashes "$pidraft")"
check "a braille-bordered pi draft holds" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 '$CREW' send pidraft held-braille && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'held-braille' && ! grep -q 'pidraft not rung: .*could not read' '$D/channel.log'"

# CREW_RING_WAIT=0 means no waiting, not no protection: one check, and a pane
# that is not free (a draft included) is refused at once.
box "$pidraft" 'draft for the zero wait'
check "CREW_RING_WAIT=0 refuses a draft at once" bash -c "start=\$SECONDS; CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=0 '$CREW' send pidraft zero-wait >/dev/null 2>&1; sleep 0.4; test \$((SECONDS - start)) -lt 5 && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'zero-wait'"
check "  the message is in the inbox"    grep -q zero-wait "$D/inbox/pidraft.md"
check "  and the log names the draft"    grep -q 'pidraft not rung: .*unsubmitted draft' "$D/channel.log"
# web.ts sets CREW_RING_WAIT=0 for its child, so an HTTP request never blocks;
# with no waiting its draft is refused instead of typed into
box "$pidraft" 'draft for the web path'
check "the web spawn's env refuses a draft, promptly" bash -c "start=\$SECONDS; CREW_VIA=web CREW_RING_WAIT=0 CREW_SESSION=t CREW_AGENT=lead '$CREW' send pidraft web-wait >/dev/null 2>&1; sleep 0.4; test \$((SECONDS - start)) -lt 5 && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'web-wait'"
check "  and its message is in the inbox" grep -q web-wait "$D/inbox/pidraft.md"
check "CREW_VIA=web alone is not a transport exemption" bash -c "CREW_VIA=web CREW_RING_WAIT=1 CREW_SESSION=t CREW_AGENT=lead '$CREW' send pidraft web-hold >/dev/null 2>&1 && ! tmux capture-pane -p -J -t $pidraft | grep -qF 'web-hold'"
check "web.ts sets CREW_RING_WAIT=0 for its child" grep -q 'CREW_RING_WAIT: "0"' "$ROOT/share/crew/web.ts"

# F2: CREW_RING_WAIT must not reach bash arithmetic as octal, and a huge
# value must not overflow into a negative slot count.
tmux copy-mode -t "$cl"
err=$(CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=08 "$CREW" send cl octal-cl 2>&1 >/dev/null); rc=$?
check "CREW_RING_WAIT=08 exits 0 (no octal abort)" test "$rc" = 0
check "  it warns and logs like any blocked send" bash -c "printf '%s' \"\$1\" | grep -q 'not ringing cl' && grep -q 'cl not rung: .*copy/choose mode' '$D/channel.log'" _ "$err"
check "  and the message is in the inbox"        grep -q octal-cl "$D/inbox/cl.md"
err=$(CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=99999999999999999999 "$CREW" send cl huge-cl 2>&1 >/dev/null); rc=$?
check "a huge CREW_RING_WAIT exits 0 and warns" test "$rc" = 0
check "  and its message is in the inbox"       grep -q huge-cl "$D/inbox/cl.md"
tmux copy-mode -q -t "$cl"
tmux send-keys -t "$cl" -l 'draft for the huge wait'; sleep 0.3
check "a huge CREW_RING_WAIT holds, then rings when the draft clears" bash -c '
  CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=99999999999999999999 "$1" send cl huge-wait >/dev/null 2>&1 &
  pid=$!; sleep 1; ok=1
  tmux capture-pane -p -J -t "$2" | grep -qF huge-wait && ok=0
  tmux send-keys -t "$2" Enter
  wait $pid || ok=0
  sleep 0.6
  tmux capture-pane -p -J -t "$2" | grep -qF "[crew] lead → cl: huge-wait" || ok=0
  [ $ok = 1 ]' _ "$CREW" "$cl"

# T6 6b: a non-numeric CREW_RING_WAIT falls back to 30 and still holds
tmux send-keys -t "$cl" -l 'draft for abc'; sleep 0.3
check "non-numeric CREW_RING_WAIT still holds" bash -c '
  CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=abc "$1" send cl abc-cl >/dev/null 2>&1 &
  sleep 1; ok=1
  tmux capture-pane -p -J -t "$2" | grep -qF abc-cl && ok=0
  tmux send-keys -t "$2" Enter
  wait; sleep 0.6
  tmux capture-pane -p -J -t "$2" | grep -qF "[crew] lead → cl: abc-cl" || ok=0
  [ $ok = 1 ]' _ "$CREW" "$cl"

# T6 6a: an intro goes through the same hold
draftrev=$(tmux split-window -d -P -F '#{pane_id}' -t "$cl" "$CREW_HOME/bin/claude $CREW_HOME/bin/editor.sh")
sleep 0.5
tmux send-keys -t "$draftrev" -l 'draft left in a fresh pane'; sleep 0.3
err=$(CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=1 "$CREW" -s t add "draftrev=$draftrev" 2>&1 >/dev/null)
check "a held intro is not typed into the draft" bash -c "! tmux capture-pane -p -J -t $draftrev | grep -q \"You are agent 'draftrev'\""
check "  the intro is not appended to the draft"  bash -c "! tmux capture-pane -p -J -t $draftrev | grep -qF '[crew]'"
check "  the draft is still exactly one copy"     bash -c "test \$(tmux capture-pane -p -J -t $draftrev | grep -oF 'draft left in a fresh pane' | wc -l) -eq 1"
check "  and crew says the intro was not typed"  bash -c "printf '%s' \"\$1\" | grep -q 'nothing typed into draftrev'" _ "$err"

# C6: crew's own startup line can be left as a draft by a CLI that swallowed
# ring's Enter (seen with pi). The intro retries once, only while the editor
# still holds exactly crew's line, then warns; status/watch flag the draft.
swallow="$CREW_HOME/swallow-claude.sh"; swallow_out="$CREW_HOME/swallow-out"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "❯ "' \
  'read -r line || exit 0' \
  'printf "\r\033[K❯ %s" "$line"' \
  'read -r _ || exit 0' \
  'printf "%s\n" "$line" >> "$1"' \
  'printf "\r\033[K❯ \n"' \
  'while :; do sleep 1; done' > "$swallow"
err=$("$CREW" -s t add "sw=$CREW_HOME/bin/claude $swallow $swallow_out" 2>&1 >/dev/null)
for i in $(seq 1 25); do [ -s "$swallow_out" ] && break; sleep 0.2; done
check "a swallowed startup Enter is retried"  bash -c "test \$(wc -l < '$swallow_out' | tr -d ' ') = 1"
check "  it submitted exactly crew's intro"  bash -c "grep -q \"You are agent 'sw'\" '$swallow_out' && test \$(grep -c 'You are agent' '$swallow_out') = 1"
check "  and no warning was printed"        bash -c "! printf '%s' \"\$1\" | grep -q 'startup draft'" _ "$err"

never="$CREW_HOME/never-claude.sh"; never_out="$CREW_HOME/never-enters"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "❯ "' \
  'read -r line || exit 0' \
  'printf "\r\033[K❯ %s" "$line"' \
  'while read -r _; do printf "x\n" >> "$1"; done' > "$never"
err=$("$CREW" -s t add "nev=$CREW_HOME/bin/claude $never $never_out" 2>&1 >/dev/null)
nev=$(awk -F'\t' '$1=="nev"{print $2}' "$D/panes")
for i in $(seq 1 25); do [ -s "$never_out" ] && break; sleep 0.2; done
sleep 0.3   # enough for a looping retry to show up as a second Enter
check "a startup line that never submits warns" bash -c "printf '%s' \"\$1\" | grep -qF 'tmux send-keys -t $nev Enter'" _ "$err"
check "  and says the draft blocks doorbells"   bash -c "printf '%s' \"\$1\" | grep -q 'startup draft'" _ "$err"
check "  and only one extra Enter was sent"    bash -c "test \$(wc -l < '$never_out' | tr -d ' ') = 1"
check "  and the pane still holds the draft"   bash -c "tmux capture-pane -p -J -t $nev | grep -q \"You are agent 'nev'\""
"$CREW" -s t status > "$CREW_HOME/c6-status"
check "status notes a pending draft"        bash -c "awk '\$1==\"nev\"' '$CREW_HOME/c6-status' | grep -q 'draft pending'"
check "  and says doorbells are held"       bash -c "awk '\$1==\"nev\"' '$CREW_HOME/c6-status' | grep -q 'doorbells are held'"
check "status has no draft note for sw"     bash -c "! awk '\$1==\"sw\"' '$CREW_HOME/c6-status' | grep -q 'draft pending'"
"$CREW" -s t watch --every 1 --quiet-after 0 > "$CREW_HOME/c6-watch" 2>&1 & c6_watch=$!
for i in $(seq 1 40); do grep -q 'nev draft pending' "$CREW_HOME/c6-watch" && break; sleep 0.2; done
check "watch reports the pending draft"      grep -q 'nev draft pending: doorbells are held' "$CREW_HOME/c6-watch"
kill "$c6_watch" 2>/dev/null; wait "$c6_watch" 2>/dev/null || true

# C6 refusal: a draft that is not crew's line (here: replaced after ring) must
# survive untouched — intro_submit presses nothing and says why.
foreign="$CREW_HOME/foreign-claude.sh"; foreign_enters="$CREW_HOME/foreign-enters"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "❯ "' \
  'read -r line || exit 0' \
  'printf "\033[2J\033[H❯ someone else is typing"' \
  'while read -r _; do printf "x\n" >> "$1"; done' > "$foreign"
err=$("$CREW" -s t add "fgn=$CREW_HOME/bin/claude $foreign $foreign_enters" 2> "$CREW_HOME/fgn-err" >/dev/null)
fgn=$(awk -F'\t' '$1=="fgn"{print $2}' "$D/panes")
sleep 0.3
check "a foreign draft gets no extra Enter"   test ! -s "$foreign_enters"
check "  the refusal names the foreign draft" grep -q "not crew's startup line" "$CREW_HOME/fgn-err"
check "  and the draft is intact, intro gone" bash -c "test \$(tmux capture-pane -p -J -t $fgn | grep -oF 'someone else is typing' | wc -l) -eq 1 && ! tmux capture-pane -p -J -t $fgn | grep -qF '[crew]'"

# R1: the draft note keeps pane_hold's precedence — a dialog or copy/choose
# mode is never read as a draft, even with a draft-looking row on screen.
tmux send-keys -t "$fgn" Enter; sleep 0.2
tmux send-keys -t "$fgn" "Do you want to proceed?" Enter; sleep 0.3
"$CREW" -s t status > "$CREW_HOME/c6-dialog-status"
check "a dialog pane gets no draft note" bash -c "! awk '\$1==\"fgn\"' '$CREW_HOME/c6-dialog-status' | grep -q 'draft pending'"
copymode="$CREW_HOME/copy-claude.sh"
printf '%s\n' '#!/bin/sh' 'printf "❯ copy-mode draft"' 'while read -r _; do :; done' > "$copymode"
CREW_RING_WAIT=1 "$CREW" -s t add "cpd=$CREW_HOME/bin/claude $copymode" >/dev/null 2>&1
cpd=$(awk -F'\t' '$1=="cpd"{print $2}' "$D/panes")
tmux copy-mode -t "$cpd"; sleep 0.3
"$CREW" -s t status > "$CREW_HOME/c6-copy-status"
check "a copy-mode pane gets no draft note" bash -c "! awk '\$1==\"cpd\"' '$CREW_HOME/c6-copy-status' | grep -q 'draft pending'"
tmux copy-mode -q -t "$cpd"; sleep 0.3
"$CREW" -s t status > "$CREW_HOME/c6-copy-status2"
check "  copy mode exit restores the draft note" bash -c "awk '\$1==\"cpd\"' '$CREW_HOME/c6-copy-status2' | grep -q 'draft pending'"

# R2: an editor that clears between the last pane_hold and draft_text is not a
# foreign draft — nothing typed, no refusal warning.
sed -n '/^intro_submit()/,/^}/p' "$CREW" > "$CREW_HOME/intro-submit.sh"
check "a cleared editor prints no refusal" bash -c '
  . "$1/intro-submit.sh"
  TAB=$(printf "\t")
  pane_hold() { printf "draft\tunsubmitted draft in the editor"; }
  owns_pane() { return 0; }
  draft_text() { printf ""; }
  tmux() { :; }
  err=$(intro_submit r %1 "[crew] hi" 2>&1)
  [ -z "$err" ]' _ "$CREW_HOME"

# A pane showing an approval prompt gets no doorbell (a digit would pick an option).
rev=$(awk -F'\t' '$1=="rev"{print $2}' "$D/panes")
tmux send-keys -t "$rev" "Do you want to proceed?" Enter; sleep 0.3
as lead send rev "held-msg" >/dev/null 2>&1; sleep 0.3
check "no ring into an approval prompt" bash -c "! tmux capture-pane -p -J -t $rev | grep -q held-msg"
check "  but it's in the inbox"         grep -q held-msg "$D/inbox/rev.md"
check "  and the log says so"           grep -q 'rev not rung: pane .* approval prompt' "$D/channel.log"
check "zero wait still refuses an approval" bash -c "start=\$SECONDS; CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=0 '$CREW' send rev zero-approval >/dev/null 2>&1; sleep 0.3; test \$((SECONDS - start)) -lt 5 && ! tmux capture-pane -p -J -t $rev | grep -qF 'zero-approval'"
check "  and its message stays in the inbox" grep -q zero-approval "$D/inbox/rev.md"

# Simulate pane-id reuse: rev's pane loses its crew labels (as a fresh pane would).
tmux set-option -p -u -t "$rev" @crew_role; tmux set-option -p -u -t "$rev" @crew_session
tmux send-keys -t "$rev" C-c; sleep 0.3; tmux send-keys -t "$rev" "clear" Enter; sleep 0.3
check "override refuses a reused pane" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead rev"
check "override refuses a stale pane reference" bash -c "! CREW_SESSION=t CREW_AGENT=lead '$CREW' override lead $rev"
as lead send rev "should not ring" >/dev/null 2>&1
check "no ring into a reused pane"      bash -c "! tmux capture-pane -p -t $rev | grep -q 'should not ring'"
check "message still saved to inbox"    grep -q 'should not ring' "$D/inbox/rev.md"
check "  and the log says so"           grep -q 'rev not rung: pane .* gone or now belongs' "$D/channel.log"
check "zero wait still refuses a reused pane" bash -c "CREW_SESSION=t CREW_AGENT=lead CREW_RING_WAIT=0 '$CREW' send rev zero-reuse >/dev/null 2>&1; ! tmux capture-pane -p -t $rev | grep -q 'zero-reuse'"
check "peek refuses a reused pane"     bash -c "! '$CREW' -s t peek rev"
check "identity fallback refuses a reused role pane" bash -c 'CREW_SESSION=t CREW_AGENT=rev TMUX_PANE=%999999 "$1" whoami | grep -q "^outside "' _ "$CREW"
check "  and says the role pane is not owned" bash -c 'CREW_SESSION=t CREW_AGENT=rev TMUX_PANE=%999999 "$1" whoami 2>/dev/null | grep -q "^why: pane .* is not owned by role rev"' _ "$CREW"
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
check "add uses the original --here window" env TMUX_PANE="$self" "$CREW" add rev=cat
self_added=$(awk -F'\t' '$1=="rev"{print $2}' "$CREW_HOME/s/panes")
check "added pane shares caller's window" test "$(tmux display -p -t "$self_added" '#{window_id}')" = "$(tmux display -p -t "$self" '#{window_id}')"
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
adopt_lead=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
adopt_rev=$(tmux split-window -d -P -F '#{pane_id}' -t "$adopt_lead" cat)
adopt_ref=$(tmux display -p -t "$adopt_rev" '#{session_name}:#{window_index}.#{pane_index}')
check "adopt resolves id and session/window/index refs" "$CREW" adopt existing lead="$adopt_lead" rev="$adopt_ref"
check "adopt records resolved ids and detected CLI" awk -F'\t' -v p="$adopt_rev" '$1=="rev" && $2==p && $3=="cat" && $4=="adopted"{f=1} END{exit !f}' "$CREW_HOME/existing/panes"
check "adopt renders a live roster pointer" grep -qF "$CREW_HOME/existing/panes" "$CREW_HOME/existing/roles/lead.md"
"$CREW" -s existing down >/dev/null 2>&1

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

# Grow a running crew, preserving custom instructions and adopting safely.
"$CREW" up expand --in "$TS" lead=cat rev=cat >/dev/null 2>&1
E="$CREW_HOME/expand"
expand_win=$(awk -F'=' '$1=="window"{print $2}' "$E/meta")
sed 's/\. The human is/. Keep this custom instruction. The human is/' "$E/roles/lead.md" > "$E/roles/lead.md.tmp"
mv "$E/roles/lead.md.tmp" "$E/roles/lead.md"
printf '\nExtra custom instructions.\n' >> "$E/roles/lead.md"
cp "$E/roles/lead.md" "$CREW_HOME/expand-lead-before-add"
adopted=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
spec="printf 'verbatim → spec\\n' | cat; cat"
check "add spawns and adopts in one batch" "$CREW" -s expand add "rev2=$spec" "test=$adopted"
spawned=$(awk -F'\t' '$1=="rev2"{print $2}' "$E/panes")
check "add records the verbatim CLI" test "$(awk -F'\t' '$1=="rev2"{print $3}' "$E/panes")" = "$spec"
check "add records spawned origin" awk -F'\t' '$1=="rev2" && $4=="spawned"{f=1} END{exit !f}' "$E/panes"
check "add starts the exact command" screen_has "$spawned" 'verbatim → spec'
check "add uses the crew's recorded window" test "$(tmux display -p -t "$spawned" '#{window_id}')" = "$expand_win"
check "add labels the adopted pane" test "$(tmux display -p -t "$adopted" '#{@crew_session}/#{@crew_role}')" = expand/test
check "add records adopted origin" awk -F'\t' '$1=="test" && $4=="adopted"{f=1} END{exit !f}' "$E/panes"
check "add rings the spawned agent's intro" screen_has "$spawned" "You are agent 'rev2'"
check "add rings the adopted agent's intro" screen_has "$adopted" "You are agent 'test'"
check "add uses the base role template" grep -q 'You review' "$E/roles/rev2.md"
check "add renders a live roster pointer in new role files" grep -qF "For the current roster, read \`$E/panes\`" "$E/roles/rev2.md"
check "add leaves existing role files unchanged" cmp "$E/roles/lead.md" "$CREW_HOME/expand-lead-before-add"
check "add preserves other custom instructions" grep -qF 'Extra custom instructions.' "$E/roles/lead.md"
check "add logs a sys event" awk -F'\t' '$2=="sys" && $5~/added agents to expand: rev2 test/{f=1} END{exit !f}' "$E/channel.log"
cp "$E/panes" "$CREW_HOME/expand-before-invalid"
pane_count=$(tmux list-panes -s -t "$TS" | wc -l)
check "add refuses existing roles before spawning" bash -c '! "$1" -s expand add fresh=cat rev=cat' _ "$CREW"
check "add refuses duplicate new roles" bash -c '! "$1" -s expand add fresh=cat fresh=cat' _ "$CREW"
check "add rejects a missing pane before spawning" bash -c '! "$1" -s expand add fresh=cat test2=%999999' _ "$CREW"
check "add rejects a pane already in this crew" bash -c '! "$1" -s expand add test2="$2"' _ "$CREW" "$adopted"
check "invalid add preserves bindings" cmp "$E/panes" "$CREW_HOME/expand-before-invalid"
check "invalid add creates no panes" test "$(tmux list-panes -s -t "$TS" | wc -l)" = "$pane_count"
unlabelled=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
check "add rejects the same pane twice" bash -c '! "$1" -s expand add a="$2" b="$2"' _ "$CREW" "$unlabelled"
check "invalid batch leaves adopted target unlabelled" test -z "$(tmux display -p -t "$unlabelled" '#{@crew_role}')"
cp "$E/meta" "$CREW_HOME/expand-original-meta"
unowned_win=$(tmux display -p -t "$unlabelled" '#{window_id}')
sed "s/^window=.*/window=$unowned_win/" "$E/meta" > "$E/meta.tmp"
mv "$E/meta.tmp" "$E/meta"
check "add falls back from an unowned stored window" "$CREW" -s expand add fallback=cat
fallback_pane=$(awk -F'\t' '$1=="fallback"{print $2}' "$E/panes")
check "fallback uses the first owned pane's window" test "$(tmux display -p -t "$fallback_pane" '#{window_id}')" = "$expand_win"
mv "$CREW_HOME/expand-original-meta" "$E/meta"
tmux set-option -p -t "$unlabelled" @crew_session other
tmux set-option -p -t "$unlabelled" @crew_role worker
check "add rejects another crew's pane" bash -c '! "$1" -s expand add a="$2"' _ "$CREW" "$unlabelled"
tmux kill-pane -t "$unlabelled"
check "failed validation releases panes lock" test ! -e "$E/.panes.lock"
mkdir "$E/.panes.lock"
check "add respects the panes lock" bash -c '! "$1" -s expand add locked=cat' _ "$CREW"
check "add leaves another caller's lock alone" test -d "$E/.panes.lock"
rmdir "$E/.panes.lock"
"$CREW" -s expand add parallel1=cat >/dev/null 2>&1 & add1=$!
"$CREW" -s expand add parallel2=cat >/dev/null 2>&1 & add2=$!
check "first concurrent add succeeds" wait "$add1"
check "second concurrent add succeeds" wait "$add2"
check "concurrent adds preserve both roles" test "$(awk -F'\t' '$1~/^parallel[12]$/{n++} END{print n}' "$E/panes")" = 2
roster_path=$(sed -n 's/^For the current roster, read `\([^`]*\)`.*$/\1/p' "$E/roles/lead.md")
check "existing roster pointer sees concurrent additions" test "$(awk -F'\t' '$1~/^parallel[12]$/{n++} END{print n}' "$roster_path")" = 2
check "concurrent adds leave custom role files untouched" cmp "$E/roles/lead.md" "$CREW_HOME/expand-lead-before-add"
err=$("$CREW" -s expand add "dialog=printf 'Trust this folder?\\nEnter to confirm\\n'; cat" "failed=true" 2>&1 >/dev/null)
added_dialog=$(awk -F'\t' '$1=="dialog"{print $2}' "$E/panes")
added_failed=$(awk -F'\t' '$1=="failed"{print $2}' "$E/panes")
check "add does not type an intro into startup dialogs" bash -c '! tmux capture-pane -p -J -t "$1" | grep -q "You are agent"' _ "$added_dialog"
check "add explains startup dialogs and failed commands" bash -c 'printf "%s" "$1" | grep -q "startup dialog" && printf "%s" "$1" | grep -q "back at a shell prompt"' _ "$err"
check "add sends no intro after a failed command" bash -c '! tmux capture-pane -p -J -t "$1" | grep -q "You are agent"' _ "$added_failed"
"$CREW" -s expand down >/dev/null 2>&1
check "down closes a pane created by add" bash -c '! tmux display -p -t "$1" "#{pane_id}" | grep -q .' _ "$spawned"
check "down keeps a pane adopted by add" test "$(tmux display -p -t "$adopted" '#{pane_id}')" = "$adopted"
check "down unlabels a pane adopted by add" test -z "$(tmux display -p -t "$adopted" '#{@crew_role}')"
check "add refuses ended crews" bash -c '! "$1" -s expand add later=cat' _ "$CREW"

# Removing a role: close spawned panes, block its open tasks, keep the files.
"$CREW" up rm --in "$TS" lead=cat impl=cat rev=cat >/dev/null 2>&1
R="$CREW_HOME/rm"
asr() { local role="$1"; shift; CREW_SESSION=rm CREW_AGENT="$role" "$CREW" "$@"; }
check "rev template carries the review-only marker" grep -q 'crew:review-only' "$ROOT/share/crew/roles/rev.md"
check "rendered role file keeps the marker" grep -q 'crew:review-only' "$R/roles/rev.md"
rm_err=$(asr lead task add --to rev "ship the fix" 2>&1 >/dev/null)
check "task add warns for a review-only owner" bash -c 'printf "%s" "$1" | grep -q review-only' _ "$rm_err"
check "  and still records the task"    awk -F'\t' '$2=="rev"{f=1} END{exit !f}' "$R/board.tsv"
rm_err=$(asr lead task add --to rev "REVIEW round 1 of the fix" 2>&1 >/dev/null)
check "task add stays quiet for a review title" test -z "$rm_err"
rm_err=$(asr lead task add --to rev --msg "audit the diff" "check this" 2>&1 >/dev/null)
check "task add stays quiet for a review --msg" test -z "$rm_err"
rm_err=$(asr lead task add --to impl "impl open one" 2>&1 >/dev/null)
check "task add does not warn for impl" test -z "$rm_err"
asr lead task add --to impl "impl open two" >/dev/null 2>&1
asr impl task set T5 working >/dev/null 2>&1
asr lead task add --to impl "impl finished" >/dev/null 2>&1
asr impl task set T6 done --force >/dev/null 2>&1
printf 'kept\n' > "$R/out/impl-result.md"
rm_impl=$(awk -F'\t' '$1=="impl"{print $2}' "$R/panes")
check "remove refuses lead"             bash -c '! "$1" -s rm remove lead' _ "$CREW"
check "remove refuses an unknown role"  bash -c '! "$1" -s rm remove nobody' _ "$CREW"
check "remove refuses a worker caller"  bash -c '! CREW_SESSION=rm CREW_AGENT=rev "$1" remove rev' _ "$CREW"
check "refused removals change nothing" awk -F'\t' '$1=="lead" || $1=="impl"{n++} END{exit !(n==2)}' "$R/panes"
asr lead remove impl >/dev/null
check "remove closes a spawned pane"    bash -c '! tmux display -p -t "$1" "#{pane_id}" | grep -q .' _ "$rm_impl"
rm_roster=$(awk -F'\t' '$1=="impl"{print $1}' "$R/panes")
check "remove drops the roster row"     test -z "$rm_roster"
rm_states=$(awk -F'\t' '$2=="impl"{print $1 ":" $3}' "$R/board.tsv" | tr '\n' ' ')
check "remove blocks queued and working tasks" test "$rm_states" = "T4:blocked T5:blocked T6:done "
check "remove logs the removal and blocked tasks" grep -q 'removed impl.*blocked: T4 T5' "$R/channel.log"
check "remove keeps the inbox and out/ files" test -f "$R/inbox/impl.md" -a -f "$R/out/impl-result.md"
rm_adopted=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
asr lead add test="$rm_adopted" >/dev/null 2>&1
asr lead remove test >/dev/null
check "remove keeps an adopted pane open" test "$(tmux display -p -t "$rm_adopted" '#{pane_id}')" = "$rm_adopted"
check "  and unlabels it"                test -z "$(tmux display -p -t "$rm_adopted" '#{@crew_role}')"
tmux kill-pane -t "$rm_adopted"
asr lead add keep=cat >/dev/null 2>&1
rm_keep=$(awk -F'\t' '$1=="keep"{print $2}' "$R/panes")
asr lead remove keep --keep-pane >/dev/null
check "remove --keep-pane keeps a spawned pane" test "$(tmux display -p -t "$rm_keep" '#{pane_id}')" = "$rm_keep"
check "  and unlabels it"                test -z "$(tmux display -p -t "$rm_keep" '#{@crew_role}')"
rm_keep_row=$(awk -F'\t' '$1=="keep"' "$R/panes")
check "  and still drops the roster row" test -z "$rm_keep_row"
tmux kill-pane -t "$rm_keep"
# A one-step override verifies a spawned CLI before changing the binding.
"$CREW" up swap --in "$TS" lead=cat impl=cat rev=cat >/dev/null 2>&1
SW="$CREW_HOME/swap"
swap_lead=$(awk -F'\t' '$1=="lead"{print $2}' "$SW/panes")
swap_impl=$(awk -F'\t' '$1=="impl"{print $2}' "$SW/panes")
cp "$SW/panes" "$CREW_HOME/swap-before-refusal"
swap_count=$(tmux list-panes -t "$(tmux display-message -p -t "$swap_lead" '#{window_id}')" -F '#{pane_id}' | wc -l | tr -d ' ')
err=$(CREW_SESSION=swap CREW_AGENT=rev "$CREW" -s swap override lead impl 2>&1 >/dev/null) || true
check "override refusal echoes the two-argument command" bash -c 'printf "%s" "$1" | grep -q "crew -s swap override lead impl"' _ "$err"
err=$(CREW_SESSION=swap CREW_AGENT=rev "$CREW" -s swap override lead=cat 2>&1 >/dev/null) || true
check "override refusal echoes the role=spec command" bash -c 'printf "%s" "$1" | grep -q "crew -s swap override lead=cat"' _ "$err"
check "refused overrides do not spawn panes" test "$(tmux list-panes -t "$(tmux display-message -p -t "$swap_lead" '#{window_id}')" -F '#{pane_id}' | wc -l | tr -d ' ')" = "$swap_count"
check "refused overrides preserve bindings" cmp "$SW/panes" "$CREW_HOME/swap-before-refusal"
cp "$SW/panes" "$CREW_HOME/swap-before-failed-start"
err=$(CREW_VIA=web "$CREW" -s swap override impl=no-such-cli-xyz 2>&1 >/dev/null) || true
check "override closes a command that returns to the shell" bash -c 'printf "%s" "$1" | grep -q "did not start"' _ "$err"
check "failed override preserves bindings" cmp "$SW/panes" "$CREW_HOME/swap-before-failed-start"
check "failed override closes the pane" test "$(tmux list-panes -t "$(tmux display-message -p -t "$swap_lead" '#{window_id}')" -F '#{pane_id}' | wc -l | tr -d ' ')" = "$swap_count"
printf 'handover\n' > "$SW/out/handover-impl.md"
human "$CREW" -s swap override impl=cat
swap_impl2=$(awk -F'\t' '$1=="impl"{print $2}' "$SW/panes")
check "override role=spec binds a spawned successor" awk -F'\t' -v p="$swap_impl2" '$1=="impl" && $2==p && $4=="spawned"{f=1} END{exit !f}' "$SW/panes"
check "override role=spec labels the successor" test "$(tmux display-message -p -t "$swap_impl2" '#{@crew_role}')" = impl
check "override role=spec detaches the old pane" test -z "$(tmux display-message -p -t "$swap_impl" '#{@crew_role}')"
check "override role=spec keeps the old pane open" test "$(tmux display-message -p -t "$swap_impl" '#{pane_id}')" = "$swap_impl"
check "override context names an existing handover file" grep -qF 'out/handover-impl.md' "$SW"/out/override-impl-*.md
check "override starts the successor before notifying" screen_has "$swap_impl2" "You are agent 'impl'"
"$CREW" -s swap down >/dev/null 2>&1
tmux kill-pane -t "$swap_impl" 2>/dev/null || true

# a pane that exists but no longer carries the role's labels: leave it alone
asr lead add reused=cat >/dev/null 2>&1
rm_reused=$(awk -F'\t' '$1=="reused"{print $2}' "$R/panes")
tmux set-option -p -t "$rm_reused" @crew_session other
tmux set-option -p -t "$rm_reused" @crew_role other
rm_before=$(tmux capture-pane -p -J -t "$rm_reused" | cksum)
rm_err=$(asr lead remove reused 2>&1 >/dev/null)
check "remove leaves a reused pane open" test "$(tmux display -p -t "$rm_reused" '#{pane_id}')" = "$rm_reused"
check "  and does not touch its screen"  test "$(tmux capture-pane -p -J -t "$rm_reused" | cksum)" = "$rm_before"
rm_reused_row=$(awk -F'\t' '$1=="reused"' "$R/panes")
check "  and still drops the roster row" test -z "$rm_reused_row"
check "  and warns on stderr"            bash -c 'printf "%s" "$1" | grep -q "no longer carries"' _ "$rm_err"
tmux kill-pane -t "$rm_reused"
rm_ghost=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
asr lead add ghost="$rm_ghost" >/dev/null 2>&1
tmux kill-pane -t "$rm_ghost"
rm_ghost_state=$("$CREW" -s rm status | awk '$1=="ghost"{print $5}')
check "status shows gone for a missing pane" test "$rm_ghost_state" = gone
"$CREW" -s rm down >/dev/null 2>&1

# Listing and sweeping only inspect pane identity, including reused ids.
fixture() {
  local name="$1" dir="$CREW_HOME/$1"
  mkdir -p "$dir/out"
  printf 'mode=adopt\ncwd=%s/projects/crew\n' "$HOME" > "$dir/meta"
  : > "$dir/panes"; : > "$dir/board.tsv"; : > "$dir/channel.log"
}
fixture_label() {
  tmux set-option -p -t "$2" @crew_session "$1"
  tmux set-option -p -t "$2" @crew_role lead
  printf 'lead\t%s\tcat\tadopted\n' "$2" >> "$CREW_HOME/$1/panes"
}
fixture_snapshot() {
  local name file
  for name in a-ended ls-up ls-partial ls-stale ls-empty; do
    for file in "$CREW_HOME/$name"/*; do
      [ ! -f "$file" ] || cksum "$file"
    done
  done
  cksum "$CREW_HOME/.current"
  tmux list-panes -s -t "$TS" -F '#{pane_id} #{@crew_session}/#{@crew_role}'
  for pane in "$ls_up" "$ls_partial" "$ls_reused"; do tmux capture-pane -p -t "$pane" | cksum; done
}
for name in a-ended ls-up ls-partial ls-stale ls-empty; do fixture "$name"; done
touch "$CREW_HOME/a-ended/ended"
ls_up=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
ls_partial=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
ls_reused=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
fixture_label ls-up "$ls_up"
fixture_label ls-partial "$ls_partial"
tmux set-option -p -t "$ls_reused" @crew_session unrelated
tmux set-option -p -t "$ls_reused" @crew_role other
printf 'gone\t%%999999\tcat\tspawned\nreused\t%s\tcat\tspawned\n' "$ls_reused" >> "$CREW_HOME/ls-partial/panes"
printf 'gone\t%%999999\tcat\tspawned\nreused\t%s\tcat\tspawned\n' "$ls_reused" >> "$CREW_HOME/ls-stale/panes"
printf 'T1\tlead\tdone\t-\tout/T1.md\tdone task\t-\nT2\tlead\tqueued\t-\tout/T2.md\topen task\t-\nT3\tlead\tworking\t-\tout/T3.md\tworking task\t-\n' > "$CREW_HOME/ls-up/board.tsv"
fixture_epoch=$(date '+%s')
for entry in ls-up:300 ls-partial:7200 ls-stale:172800; do
  name="${entry%:*}"; age="${entry#*:}"
  printf '%s\tsys\t-\t-\tfixture\n' "$(date -r "$((fixture_epoch - age))" '+%Y-%m-%dT%H:%M:%S')" > "$CREW_HOME/$name/channel.log"
done
printf 'cwd=%s/%s→long-project\n' "$HOME" "$(printf '%044d' 0)" > "$CREW_HOME/ls-stale/meta"
printf 'ls-stale\n' > "$CREW_HOME/.current"
before_listing=$(fixture_snapshot)
listing="$CREW_HOME/listing"
check "ls succeeds" bash -c '"$1" ls > "$2"' _ "$CREW" "$listing"
check "ls is read-only for state files and pane labels" test "$(fixture_snapshot)" = "$before_listing"
check "ls shows up when every pane is owned" awk '$1=="ls-up" && $3=="up"{f=1} END{exit !f}' "$listing"
check "ls shows partial when only some panes are owned" awk '$1=="ls-partial" && $3=="partial"{f=1} END{exit !f}' "$listing"
check "ls shows stale when no pane is owned" awk '$1=="ls-stale" && $3=="stale"{f=1} END{exit !f}' "$listing"
check "ls shows an empty roster as stale" awk '$1=="ls-empty" && $3=="stale"{f=1} END{exit !f}' "$listing"
check "ls shows ended state" awk '$1=="a-ended" && $3=="ended"{f=1} END{exit !f}' "$listing"
check "ls keeps ended crews after active crews" awk '$3=="ended"{ended=1} $3~/^(up|partial|stale)$/{if(ended) exit 1}' "$listing"
check "ls marks each agent alive, gone or reused" awk '$1=="ls-partial" && /lead=cat\(alive\)/ && /gone=cat\(gone\)/ && /reused=cat\(reused\)/{f=1} END{exit !f}' "$listing"
check "ls shortens HOME in project paths" grep -qF '~/projects/crew' "$listing"
check "ls project truncation remains valid UTF-8" iconv -f UTF-8 -t UTF-8 "$listing"
check "ls project truncation retains the full arrow" grep -qF '→l…' "$listing"
check "ls shows done, total and open task counts" awk '$1=="ls-up" && /1\/3 \(2 open\)/{f=1} END{exit !f}' "$listing"
check "ls shows relative minute activity" awk '$1=="ls-up" && $NF=="5m"{f=1} END{exit !f}' "$listing"
check "ls shows relative hour activity" awk '$1=="ls-partial" && $NF=="2h"{f=1} END{exit !f}' "$listing"
check "ls shows relative day activity" awk '$1=="ls-stale" && $NF=="2d"{f=1} END{exit !f}' "$listing"
check "ls tolerates an empty activity log" awk '$1=="ls-empty" && $NF=="-"{f=1} END{exit !f}' "$listing"
check "ls hints at explicit stale crew cleanup" grep -qF '2 stale crews: crew sweep --apply' "$listing"
check "ls --live succeeds" bash -c '"$1" ls --live > "$2"' _ "$CREW" "$CREW_HOME/listing-live"
check "ls --live lists only up and partial rows" awk '$1=="ls-up"{up=1} $1=="ls-partial"{partial=1} $3~/^(ended|stale)$/{bad=1} END{exit !(up && partial && !bad)}' "$CREW_HOME/listing-live"
check "ls rejects unknown flags" bash -c '! "$1" ls --bogus' _ "$CREW"
check "sweep dry run succeeds" bash -c '"$1" sweep > "$2"' _ "$CREW" "$CREW_HOME/sweep-dry"
check "sweep dry run changes no files or pane labels" test "$(fixture_snapshot)" = "$before_listing"
check "sweep dry run names stale crews" grep -qF 'ls-stale: stale; would mark ended (dry run)' "$CREW_HOME/sweep-dry"
check "sweep reports partial crews without sweeping" grep -qF 'ls-partial: partial; kept' "$CREW_HOME/sweep-dry"
before_panes=$(tmux list-panes -s -t "$TS" -F '#{pane_id} #{@crew_session}/#{@crew_role}')
before_screens=$(for pane in "$ls_up" "$ls_partial" "$ls_reused"; do tmux capture-pane -p -t "$pane" | cksum; done)
mkdir "$CREW_HOME/ls-empty/.panes.lock"
check "sweep --apply respects the panes lock" bash -c '! "$1" sweep --apply' _ "$CREW"
check "sweep leaves another caller's lock alone" test -d "$CREW_HOME/ls-empty/.panes.lock"
check "blocked sweep preserves stale crew state" test ! -e "$CREW_HOME/ls-empty/ended"
rmdir "$CREW_HOME/ls-empty/.panes.lock"
check "sweep --apply succeeds" "$CREW" sweep --apply
check "sweep --apply ends a stale crew" test -f "$CREW_HOME/ls-stale/ended"
check "sweep --apply ends an empty stale crew" test -f "$CREW_HOME/ls-empty/ended"
check "sweep keeps partial crews running" test ! -e "$CREW_HOME/ls-partial/ended"
check "sweep keeps healthy crews running" test ! -e "$CREW_HOME/ls-up/ended"
check "sweep clears a swept current crew" test ! -e "$CREW_HOME/.current"
check "sweep logs an explicit system event" awk -F'\t' '$2=="sys" && $5~/crew sweep: marked ended/{f=1} END{exit !f}' "$CREW_HOME/ls-stale/channel.log"
check "sweep preserves crew results and files" test -f "$CREW_HOME/ls-stale/panes"
check "sweep never types into, unlabels or kills panes" test "$(tmux list-panes -s -t "$TS" -F '#{pane_id} #{@crew_session}/#{@crew_role}')" = "$before_panes"
check "sweep leaves pane screens unchanged" test "$(for pane in "$ls_up" "$ls_partial" "$ls_reused"; do tmux capture-pane -p -t "$pane" | cksum; done)" = "$before_screens"
check "sweep releases its panes lock" test ! -e "$CREW_HOME/ls-stale/.panes.lock"
printf 'ls-up\n' > "$CREW_HOME/.current"
check "repeated sweep succeeds" "$CREW" sweep --apply
check "sweep preserves an unrelated current crew" test "$(cat "$CREW_HOME/.current")" = ls-up
check "sweep rejects unknown flags" bash -c '! "$1" sweep --bogus' _ "$CREW"
mkdir "$CREW_HOME/empty-root"
check "ls handles empty active and ended row arrays" env CREW_HOME="$CREW_HOME/empty-root" "$CREW" ls
check "install works with scratch bin and skill destinations" env CREW_BIN_DIR="$CREW_HOME/install-bin" CLAUDE_SKILLS_DIR="$CREW_HOME/install-skills" "$ROOT/install.sh"
check "installed symlink finds the sourced listing module" env CREW_HOME="$CREW_HOME/empty-root" "$CREW_HOME/install-bin/crew" ls

. "$ROOT/test/watch.sh"
. "$ROOT/test/timers.sh"
. "$ROOT/test/semaphore.sh"

[ "$fail" = 0 ] && echo "all passed" || { echo "some checks failed"; exit 1; }
