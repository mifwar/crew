# Sourced by smoke.sh, sharing only its scratch CREW_HOME and detached session.
. "$ROOT/share/crew/watch.sh"
observe_is() { local expected="$1" cli="$2" got; shift 2
  got=$(printf '%s\n' "$@" | pane_observation "$cli")
  [ "$got" = "$expected" ]
}
check 'watch syntax (bash 3.2)' bash -n "$ROOT/share/crew/watch.sh"
check 'observer reads Codex context and quota' observe_is 'idle|context 38% used; 5h 62% left|' codex '› Ask Codex to do anything' 'Context 38% used · 5h 62% left'
check 'observer reads pi context' observe_is 'idle|42%/1.0m|' pi '──────────────────' '' '──────────────────' '42%/1.0M'
check 'observer reads Claude context' observe_is 'idle|context left until auto-compact: 21%|' claude '❯ ' 'Context left until auto-compact: 21%'
check 'observer reads percentage-first context' observe_is 'idle|13% context left|' claude '❯ ' '13% context left'
styled_blanks=$(awk 'BEGIN { for (i=0; i<30; i++) printf "\033[2m  \033[0m\n" }')
check 'observer ignores styled whitespace-only rows' observe_is 'error||Connection error' codex 'Connection error' "$styled_blanks"
check 'observer does not call a working editor idle' observe_is 'busy||' codex 'Working… esc to interrupt' '› '
check 'transcript working text does not suppress an idle prompt' observe_is 'idle||' codex 'I am working on the assigned task.' '› '
for prose in 'Working tree is clean.' 'Thinking through the result is complete.'; do
  check "completed response stays idle: $prose" observe_is 'idle||' codex "$prose" '› Ask Codex to do anything'
done
check 'watch notification echo does not mark lead errored' observe_is 'idle||' codex '[crew] watch → lead: worker errored with an open task: Connection error' '› '
check 'healthy quota description stays idle' observe_is 'idle||' codex '5h quota: 62% left' '› '
check 'healthy context limit description stays idle' observe_is 'idle||' codex 'Context limit is 1.0M tokens.' '› '
check 'healthy rate limit description stays idle' observe_is 'idle||' codex 'Rate limit: 62% remaining.' '› '
check 'quoted error prose stays idle' observe_is 'idle||' codex 'The old Connection error has been resolved.' '› '
check 'error UI prefix remains recognised' observe_is 'error||Connection error' codex '⚠ Error: Connection error' '› '
check 'quota exhaustion stays an error' observe_is 'error||quota' codex 'You have exceeded your quota.' '› '
for phrase in 'Retry failed' 'Connection error' 'Request timed out' 'Context limit reached' 'Rate limit exceeded' 'Quota exhausted'; do
  check "observer recognises $phrase" bash -c '. "$1/share/crew/watch.sh"; result=$(printf "%s\n" "$2" | pane_observation codex); case "$result" in error\|*) exit 0;; *) exit 1;; esac' _ "$ROOT" "$phrase"
done
check 'observer recognises a Codex provider limit banner' observe_is 'error||provider limit' codex '■ You’ve hit your usage limit. Upgrade to Pro' '› Ask Codex to do anything'
check 'observer recognises a Claude provider limit banner' observe_is 'error||provider limit' claude '❯ ' 'You’ve hit your limit · resets 3pm'
check 'observer recognises a usage limit row' observe_is 'error||provider limit' claude 'Usage limit reached. Try again later.'
check 'observer recognises a 429 rate limit row' observe_is 'error||rate limit' pi '429 rate limit exceeded, retrying'
check 'duration handles leading zero minutes' test "$(watch_duration 08m)" = 480
check 'watch rejects a zero interval' bash -c '! "$1" -s t watch --every 0' _ "$CREW"
check 'watch rejects missing duration' bash -c '! "$1" -s t watch --quiet-after' _ "$CREW"
check 'watch rejects malformed duration' bash -c '! "$1" -s t watch --quiet-after 1day' _ "$CREW"
check 'watch has command help' bash -c '"$1" watch --help | grep -q quiet-after' _ "$CREW"

watch_mock="$CREW_HOME/watch-mock.sh"
printf '%s\n' '#!/bin/sh' 'printf "› \nContext 38%% used · 5h 62%% left\n"' 'cat >/dev/null' > "$watch_mock"
"$CREW" up watch-test --in "$TS" lead=cat "worker=sh $watch_mock" >/dev/null 2>&1
watch_dir="$CREW_HOME/watch-test"
watch_pane=$(awk -F'\t' '$1=="worker"{print $2}' "$watch_dir/panes")
watch_lead=$(awk -F'\t' '$1=="lead"{print $2}' "$watch_dir/panes")
sed -n '/^owns_pane()/,/^}/p' "$CREW" > "$CREW_HOME/watch-ownership.sh"
. "$CREW_HOME/watch-ownership.sh"
watch_board() {
  printf 'T1\tworker\t%s\t-\tout/test.md\twatch work\t-\n' "$1" > "$watch_dir/board.next"
  mv "$watch_dir/board.next" "$watch_dir/board.tsv"
}
watch_board_lead() {
  printf 'T1\tlead\t%s\t-\tout/test.md\tlead work\t-\n' "$1" > "$watch_dir/board.next"
  mv "$watch_dir/board.next" "$watch_dir/board.tsv"
}
watch_type() { # every new test path that types checks ownership first
  local S=watch-test
  [ -n "$watch_pane" ] && owns_pane "$watch_pane" worker || return 1
  tmux send-keys -t "$watch_pane" -l -- "$1"
  tmux send-keys -t "$watch_pane" Enter
  sleep 0.2
}
watch_type_lead() { # same ownership guard, lead's fixture pane
  local S=watch-test
  [ -n "$watch_lead" ] && owns_pane "$watch_lead" lead || return 1
  tmux send-keys -t "$watch_lead" -l -- "$1"
  tmux send-keys -t "$watch_lead" Enter
  sleep 0.2
}
watch_until() { local tries=0
  until grep -qF "$2" "$1"; do
    tries=$((tries+1)); [ "$tries" -lt 40 ] || return 1; sleep 0.2
  done
}
watch_stop() { kill "$watch_pid"; wait "$watch_pid" 2>/dev/null || true; }
watch_board working
"$CREW" -s watch-test status > "$CREW_HOME/watch-status"
check 'status flags idle with active work' grep -q 'IDLE with queued/working task' "$CREW_HOME/watch-status"
check 'status includes resource percentages' grep -q 'context 38% used; 5h 62% left' "$CREW_HOME/watch-status"

# Reuse the lead row's existing observation when adding its recovery hint.
watch_type_lead '› '
watch_board_lead working
"$CREW" -s watch-test status > "$CREW_HOME/watch-status-idle-lead"
check 'status flags an idle lead with active work' grep -q 'IDLE with queued/working task' "$CREW_HOME/watch-status-idle-lead"
check 'status hints how to recover an idle lead' grep -q 'crew -s watch-test override lead worker' "$CREW_HOME/watch-status-idle-lead"

# Provider-limit errors get the recovery command in status and watch output.
watch_type_lead '■ You’ve hit your usage limit. Upgrade to Pro.'
"$CREW" -s watch-test status > "$CREW_HOME/watch-status-lead"
check 'status flags a lead provider limit' grep -q 'ERROR: provider limit' "$CREW_HOME/watch-status-lead"
check 'status prints the lead recovery command' grep -q 'crew -s watch-test override lead worker' "$CREW_HOME/watch-status-lead"
"$CREW" -s watch-test watch --every 1 --quiet-after 0 > "$CREW_HOME/watch-lead" 2>&1 & watch_pid=$!
check 'watch prints the lead recovery command' watch_until "$CREW_HOME/watch-lead" 'override lead worker'
watch_stop
watch_board working

watch_log="$CREW_HOME/watch-events"
"$CREW" -s watch-test watch --every 1 --quiet-after 2s > "$watch_log" 2>&1 & watch_pid=$!
sleep 0.5
check 'watch waits for quiet threshold' bash -c '! grep -q "worker stuck" "$1"' _ "$watch_log"
check 'watch reports stuck work after quiet threshold' watch_until "$watch_log" 'worker stuck:'
sleep 1.5
check 'watch debounces unchanged stuck state' test "$(grep -c 'worker stuck:' "$watch_log")" = 1
watch_type 'Connection error'
check 'watch reports new error without another quiet wait' watch_until "$watch_log" 'worker errored with an open task: Connection error'
"$CREW" -s watch-test status > "$CREW_HOME/watch-status-error"
check 'status flags recent errors' grep -q 'ERROR: Connection error' "$CREW_HOME/watch-status-error"
sleep 1.2
check 'watch debounces error state' test "$(grep -c 'worker errored' "$watch_log")" = 1
watch_board done
# Blank rows flush the earlier error off the visible screen.
watch_type "$(printf '%060d' 0 | tr 0 '\n'; printf '› ')"
check 'watch reports an empty board' watch_until "$watch_log" 'board has no open tasks'
check 'watch reports idle with no open task' watch_until "$watch_log" 'worker idle with no open task'
# Clearing the error and reopening work re-arms the prior stuck notice.
watch_board queued
check 'watch re-arms stuck after error clears' bash -c '
  tries=0
  until [ "$(grep -c "worker stuck:" "$1")" = 2 ]; do
    tries=$((tries+1)); [ "$tries" -lt 40 ] || exit 1; sleep 0.2
  done' _ "$watch_log"
watch_board done
check 'watch re-arms the empty board after new work' bash -c '
  tries=0
  until [ "$(grep -c "board has no open tasks" "$1")" = 2 ]; do
    tries=$((tries+1)); [ "$tries" -lt 40 ] || exit 1; sleep 0.2
  done' _ "$watch_log"
watch_stop
check 'empty-board event is debounced' test "$(grep -c 'board has no open tasks' "$watch_log")" = 2

watch_tmp="$CREW_HOME/watch-tmp"; mkdir "$watch_tmp"
TMPDIR="$watch_tmp" TMUX_PANE="$watch_lead" "$CREW" -s watch-test watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/watch-ring" 2>&1 & watch_pid=$!
check 'watch ring uses lead inbox' watch_until "$watch_dir/inbox/lead.md" 'board has no open tasks'
watch_stop
check 'watch removes its cache on SIGTERM' bash -c 'test -z "$(ls -A "$1")"' _ "$watch_tmp"
check 'watch ring reaches the owned lead pane even from its background shell' screen_has "$watch_lead" '[crew] watch → lead:'
# A reused pane may not be read or rung by either new command path.
tmux set-option -p -t "$watch_lead" @crew_session unrelated
watch_before=$(tmux capture-pane -p -t "$watch_lead" | cksum)
"$CREW" -s watch-test watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/watch-stale" 2>&1 & watch_pid=$!
check 'watch refuses a reused lead doorbell' watch_until "$CREW_HOME/watch-stale" 'gone or now belongs to something else'
watch_stop
check 'watch never types into a reused lead' test "$(tmux capture-pane -p -t "$watch_lead" | cksum)" = "$watch_before"
tmux set-option -p -t "$watch_lead" @crew_session watch-test
"$CREW" -s watch-test status > "$CREW_HOME/watch-status-stale-lead"
check 'status hints a reused lead pane' grep -q 'if lead is dead' "$CREW_HOME/watch-status-stale-lead"
cp "$watch_dir/panes" "$CREW_HOME/watch-panes-before-missing-lead"
awk -F'\t' -v OFS='\t' '$1=="lead"{$2="%999999"} {print}' "$watch_dir/panes" > "$watch_dir/panes.next"
mv "$watch_dir/panes.next" "$watch_dir/panes"
"$CREW" -s watch-test status > "$CREW_HOME/watch-status-missing-lead"
check 'status hints a missing lead pane' grep -q 'if lead is dead' "$CREW_HOME/watch-status-missing-lead"
cp "$CREW_HOME/watch-panes-before-missing-lead" "$watch_dir/panes"
# A normal crew shutdown exits without an EXIT trap losing its local cache.
TMPDIR="$watch_tmp" "$CREW" -s watch-test watch --every 1 --quiet-after 0 > "$CREW_HOME/watch-ended" 2>&1 & watch_pid=$!
check 'watch starts before shutdown' watch_until "$CREW_HOME/watch-ended" 'board has no open tasks'
"$CREW" -s watch-test down >/dev/null 2>&1
check 'watch exits cleanly when the crew ends' wait "$watch_pid"
check 'watch removes its cache on normal exit' bash -c 'test -z "$(ls -A "$1")"' _ "$watch_tmp"
