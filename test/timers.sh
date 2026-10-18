# Sourced by smoke.sh, using only its scratch home and detached session.
. "$ROOT/share/crew/timers.sh"
check 'timer module syntax (bash 3.2)' bash -n "$ROOT/share/crew/timers.sh"
check 'timer durations parse decimal leading zeros' test "$(timer_duration 08m)" = 480
for invalid in 0 0m -1 1day ''; do
  check "timer rejects duration [$invalid]" bash -c '. "$1/share/crew/timers.sh"; ! timer_duration "$2"' _ "$ROOT" "$invalid"
done
for invalid in 24:00 12:60 noon +0 +bad; do
  check "timer rejects time $invalid" bash -c '. "$1/share/crew/timers.sh"; ! timer_when "$2"' _ "$ROOT" "$invalid"
done
check 'timer parses next local HH:MM occurrence' bash -c '. "$1/share/crew/timers.sh"; due=$(timer_when "$(date +%H:%M)") && [ "$due" -gt "$(date +%s)" ] && [ "$due" -le "$(( $(date +%s)+90000 ))" ]' _ "$ROOT"
check 'timers command has help' bash -c '"$1" timers --help | grep -q "crew at"' _ "$CREW"
"$CREW" up timer-test --in "$TS" lead=cat worker=cat >/dev/null 2>&1
timer_dir="$CREW_HOME/timer-test"
timer_lead=$(awk -F'\t' '$1=="lead"{print $2}' "$timer_dir/panes")
timer_worker=$(awk -F'\t' '$1=="worker"{print $2}' "$timer_dir/panes")
sed -n '/^owns_pane()/,/^}/p' "$CREW" > "$CREW_HOME/timer-ownership.sh"
. "$CREW_HOME/timer-ownership.sh"
timer_until() { local i=0
  until "$@" >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 80 ] || return 1; sleep 0.1; done
}
timer_count() { [ "$(grep -cF "$2" "$1" 2>/dev/null)" -ge "$3" ]; }
timer_gone() {
  local pid started
  IFS="$(printf '\t')" read -r pid started < "$timer_dir/timers/$1/owner"
  ! kill -0 "$pid" 2>/dev/null
}
timer_marked() { [ -f "$timer_dir/timers/$1/$2" ]; }
timer_send_fixture() {
  local S=timer-test
  owns_pane "$timer_worker" worker || return 1
  tmux send-keys -t "$timer_worker" -l -- "$1"
  tmux send-keys -t "$timer_worker" Enter
  sleep 0.2
}
check 'timer rejects unknown role' bash -c '! "$1" -s timer-test at +1s nobody nope' _ "$CREW"
check 'timer requires message' bash -c '! "$1" -s timer-test every 1s worker' _ "$CREW"
# Message text is data, even when it contains shell syntax and newlines.
timer_message='literal $(touch SHOULD_NOT_EXIST) `echo not-executed`
second line'
timer_once=$("$CREW" -s timer-test at +1s worker "$timer_message")
check 'one-shot returns an id' bash -c 'case "$1" in timer-*) exit 0;; *) exit 1;; esac' _ "$timer_once"
check 'timer listing includes scheduled message' bash -c '"$1" -s timer-test timers | grep -qF "literal \$(touch SHOULD_NOT_EXIST)"' _ "$CREW"
check 'one-shot delivers the complete message' timer_until grep -qF 'second line' "$timer_dir/inbox/worker.md"
check 'one-shot gets a done marker' timer_until timer_marked "$timer_once" done
check 'timer message shell syntax is never executed' test ! -e "$ROOT/SHOULD_NOT_EXIST"
check 'one-shot rings owned worker' screen_has "$timer_worker" '[crew] timer → worker: literal'
timer_self=$(TMUX_PANE="$timer_lead" "$CREW" -s timer-test at +1s lead self-timer)
check 'timer rings its launching lead pane' timer_until screen_has "$timer_lead" '[crew] timer → lead: self-timer'
timer_repeat=$("$CREW" -s timer-test every 1s worker repeat-timer)
check 'recurring timer delivers twice' timer_until timer_count "$timer_dir/inbox/worker.md" repeat-timer 2
check 'cancel recurring timer' "$CREW" -s timer-test timers cancel "$timer_repeat"
check 'cancel terminates the recorded worker process' timer_until timer_gone "$timer_repeat"
timer_before=$(grep -cF repeat-timer "$timer_dir/inbox/worker.md")
sleep 1.4
check 'cancel prevents later repeated messages' test "$(grep -cF repeat-timer "$timer_dir/inbox/worker.md")" = "$timer_before"
check 'listing reports cancelled timer' bash -c '"$1" -s timer-test timers | grep "$2" | grep -q cancelled' _ "$CREW" "$timer_repeat"
timer_pending=$("$CREW" -s timer-test at +30m worker never-deliver)
check 'cancel pending one-shot' "$CREW" -s timer-test timers cancel "$timer_pending"
check 'cancel rejects path traversal' bash -c '! "$1" -s timer-test timers cancel ../../panes' _ "$CREW"
# Recognised approval prompts and reused panes retain only inbox delivery.
timer_send_fixture 'Would you like to run the following command?'
timer_dialog_before=$(tmux capture-pane -p -t "$timer_worker" | cksum)
timer_dialog=$("$CREW" -s timer-test at +1s worker held-timer)
check 'held timer reaches inbox' timer_until grep -q held-timer "$timer_dir/inbox/worker.md"
check 'held timer is logged as not rung' timer_until grep -q 'worker not rung' "$timer_dir/channel.log"
check 'timer does not answer approval prompt' test "$(tmux capture-pane -p -t "$timer_worker" | cksum)" = "$timer_dialog_before"
tmux set-option -p -t "$timer_worker" @crew_session unrelated
timer_stale=$("$CREW" -s timer-test at +1s worker stale-timer)
check 'stale-pane timer still preserves inbox' timer_until grep -q stale-timer "$timer_dir/inbox/worker.md"
check 'stale-pane timer never types' test "$(tmux capture-pane -p -t "$timer_worker" | cksum)" = "$timer_dialog_before"
tmux set-option -p -t "$timer_worker" @crew_session timer-test
# A corrupt/reused pid record must never signal a different process.
timer_foreign=$("$CREW" -s timer-test at +30m worker foreign-pid-timer)
IFS="$(printf '\t')" read -r timer_actual_pid timer_started < "$timer_dir/timers/$timer_foreign/owner"
printf '%s\t%s\n' "$$" "$(ps -p $$ -o lstart=)" > "$timer_dir/timers/$timer_foreign/owner"
check 'cancel rejects an unrelated pid identity' "$CREW" -s timer-test timers cancel "$timer_foreign"
check 'unrelated process survives timer cancellation' kill -0 "$$"
# Restore the original owner so down can terminate that sleeping worker.
printf '%s\t%s\n' "$timer_actual_pid" "$timer_started" > "$timer_dir/timers/$timer_foreign/owner"
timer_shutdown=$("$CREW" -s timer-test every 30m worker after-shutdown)
"$CREW" -s timer-test down >/dev/null 2>&1
check 'down marks recurring timers cancelled' timer_marked "$timer_shutdown" cancelled
check 'down terminates the timer worker' timer_until timer_gone "$timer_shutdown"
check 'ended crews reject new timers' bash -c '! "$1" -s timer-test at +1s worker after-end' _ "$CREW"
check 'shutdown timer never delivers' bash -c '! grep -q after-shutdown "$1"' _ "$timer_dir/inbox/worker.md"
