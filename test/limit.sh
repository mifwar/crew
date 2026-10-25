# Sourced by smoke.sh; all panes and files remain in its scratch environment.
. "$ROOT/share/crew/limit.sh"
. "$ROOT/share/crew/watch.sh"
limit_banner="■ You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits
or try again at 11:15 AM."
limit_clock() { pane_observation "${1:-codex}" details | cut -d '|' -f4; }
limit_clock_is() { [ "$(printf '%s\n' "$2" | limit_clock)" = "$1" ]; }
check 'limit parser reads the exact wrapped Codex banner' limit_clock_is 11:15 "$limit_banner
› "
check 'limit parser converts noon' limit_clock_is 12:00 "You've hit your usage limit. Try again at 12:00 PM."
check 'limit parser converts midnight' limit_clock_is 00:00 "You've hit your usage limit. Try again at 12:00 AM."
check 'limit parser converts afternoon' limit_clock_is 23:59 "You've hit your usage limit. Try again at 11:59 PM."
check 'limit parser ignores crew echoes' limit_clock_is '' "[crew] watch → lead: $limit_banner"
check 'limit parser rejects prose' limit_clock_is '' "Earlier you hit your usage limit. Try again at 11:15 AM."
check 'limit parser rejects invalid hour' limit_clock_is '' "You've hit your usage limit. Try again at 13:15 AM."
check 'limit parser rejects invalid minute' limit_clock_is '' "You've hit your usage limit. Try again at 11:60 AM."
check 'limit parser reads a dated Codex reset' limit_clock_is '10-25 11:15' "You've hit your usage limit. Try again at 11:15 AM on October 25."
check 'limit parser reads a dated reset with a year' limit_clock_is '2026-10-25 11:15' "You've hit your usage limit. Try again at Oct 25th, 2026 11:15 AM."
check 'limit parser reads a dated reset wrapped across rows' limit_clock_is '10-25 11:15' "■ You've hit your usage limit. Try again at 11:15 AM on
October 25.
› "
check 'limit parser rejects an unknown month word' limit_clock_is '' "You've hit your usage limit. Try again at 11:15 AM on Octember 25."
check 'limit parser rejects a date without a day' limit_clock_is '' "You've hit your usage limit. Try again at 11:15 AM on October."
check 'limit parser rejects extra reset words' limit_clock_is '' "You've hit your usage limit. Try again at 11:15 AM tomorrow."
check 'limit parser leaves missing reset manual' limit_clock_is '' "You've hit your usage limit. Upgrade to Pro."
check 'Claude reset keeps its printed timezone' test "$(printf '%s\n' 'You’ve hit your limit · resets 3pm (Asia/Jakarta)' | limit_clock claude)" = '15:00 Asia/Jakarta'
check 'Claude reset accepts minutes and UTC' test "$(printf '%s\n' '❯ You’ve hit your limit · resets 3:30pm (UTC)' | limit_clock claude)" = '15:30 UTC'
check 'Claude dated reset is read' test "$(printf '%s\n' 'You’ve hit your limit · resets Oct 31 at 3pm' | limit_clock claude)" = '10-31 15:00'
check 'Claude dated reset keeps its timezone' test "$(printf '%s\n' 'You’ve hit your weekly limit · resets Oct 31, 3:30pm (Asia/Jakarta)' | limit_clock claude)" = '10-31 15:30 Asia/Jakarta'
check 'Claude weekly wording is a provider limit' test "$(printf '%s\n' 'Weekly limit reached ∙ resets Oct 31, 9am' | pane_observation claude details | cut -d '|' -f3,4)" = 'provider limit|10-31 09:00'
check 'relative reset is a limit without a reset time' test "$(printf '%s\n' 'Weekly limit reached ∙ resets in 3 days' | pane_observation claude details | cut -d '|' -f3,4)" = 'provider limit|'
check 'unknown CLI reset stays manual' test -z "$(printf '%s\n' "$limit_banner" | limit_clock pi)"
limit_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-24 11:15:30' +%s)
check 'reset grace includes the current reset minute' test "$(limit_reset_due 11:15 "$limit_epoch")" = "$((limit_epoch+30))"
check 'reset rollover uses the next local day' test "$(date -r "$(limit_reset_due 11:14 "$limit_epoch")" '+%Y-%m-%d %H:%M:%S')" = '2026-10-25 11:15:00'
limit_epoch_tz=$(TZ=Asia/Jakarta date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-24 11:15:30' +%s)
check 'reset respects a named timezone' test "$(limit_reset_due '04:15 UTC' "$limit_epoch_tz")" = "$(TZ=Asia/Jakarta limit_reset_due 11:15 "$limit_epoch_tz")"
check 'dated reset is that day plus grace' test "$(date -r "$(limit_reset_due '10-31 15:00' "$limit_epoch")" '+%Y-%m-%d %H:%M:%S')" = '2026-10-31 15:01:00'
check 'dated reset with a year is exact' test "$(limit_reset_due '2026-10-31 15:00' "$limit_epoch")" = "$(limit_reset_due '10-31 15:00' "$limit_epoch")"
check 'dated reset in the timezone it printed' test "$(limit_reset_due '10-31 15:00 UTC' "$limit_epoch")" = "$(( $(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-31 15:00:00' +%s) + 60 ))"
check 'a passed dated reset is due now, not next year' test "$(limit_reset_due '10-24 09:00' "$limit_epoch")" -le "$limit_epoch"
limit_december=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-12-30 10:00:00' +%s)
check 'a January reset seen in December is next year' test "$(date -r "$(limit_reset_due '01-02 09:00' "$limit_december")" +%Y)" = 2027
check 'an impossible date stays manual' bash -c '! limit_reset_due "02-30 15:00" "$1"' _ "$limit_epoch"
check 'a malformed reset stays manual' bash -c '! limit_reset_due "10-31 15:00 UTC extra" "$1"' _ "$limit_epoch"
check 'limit parser accepts the model-specific Codex banner' limit_clock_is 11:15 "│ You've hit your usage limit for ExampleModel. Try again at 11:15 AM."
check 'watch requires ringing for automatic wake' bash -c '! "$1" -s t watch --wake-on-limit' _ "$CREW"
check 'up refuses wake with no watcher' bash -c '! "$1" up invalid --no-watch --wake-on-limit lead=cat' _ "$CREW"
check 'up refuses wake with no lead' bash -c '! "$1" up invalid --wake-on-limit worker=cat' _ "$CREW"
check 'watch requires ringing for automatic handover' bash -c '! "$1" -s t watch --handover-on-limit cat' _ "$CREW"
check 'up refuses handover with no watcher' bash -c '! "$1" up invalid --no-watch --handover-on-limit cat lead=cat' _ "$CREW"
check 'up refuses max-wait without a handover spec' bash -c '! "$1" up invalid --max-wait 6h lead=cat' _ "$CREW"
check 'up refuses a pane as the handover spec' bash -c '! "$1" up invalid --handover-on-limit %12 lead=cat' _ "$CREW"
check 'up refuses role=spec as the handover spec' bash -c '! "$1" up invalid --handover-on-limit lead=cat lead=cat' _ "$CREW"
check 'up refuses a bad max-wait' bash -c '! "$1" up invalid --handover-on-limit cat --max-wait soon lead=cat' _ "$CREW"
check 'refused handover flags create no crew' test ! -d "$CREW_HOME/invalid"

# Exercise scheduling and claims without sleeping until a real quota reset.
# Delivery and ownership are the real shared helpers; only time comes from a
# backdated record. A tiny fixture capture stands in for Codex, whose real CLI
# cannot be forced to hit a usage limit reliably.
limit_mock="$CREW_HOME/limit-mock.sh"
printf '%s\n' '#!/bin/sh' 'cat "$1"' 'cat >/dev/null' > "$limit_mock"
printf '%s\n' "$limit_banner" '› ' > "$CREW_HOME/limit-screen"
CREW_WATCH_EVERY=60 "$CREW" up limit-test --in "$TS" --wake-on-limit "lead=sh $limit_mock $CREW_HOME/limit-screen" worker=cat >/dev/null 2>&1
limit_dir="$CREW_HOME/limit-test"
limit_pane=$(awk -F'\t' '$1=="lead"{print $2}' "$limit_dir/panes")
limit_id=$("$CREW" -s limit-test timers | awk '$2=="watch"{print $1}')
check 'up persists the wake opt-in on its watcher' test "$(awk -F'\t' '{print $4}' "$limit_dir/timers/$limit_id/config")" = 1
"$CREW" -s limit-test timers cancel "$limit_id" >/dev/null
# Share the command functions without executing CLI dispatch.
sed '/^# ---------- main ----------/,$d' "$CREW" > "$CREW_HOME/limit-functions.sh"
# bin/crew resolves its share directory relative to its own path, so use the
# real share explicitly for the sourced fixture.
limit_run() { # reset [moved|unknown] [handover-spec] [max-wait] — the wake helper with its real guards
  CREW_SHARE="$ROOT/share/crew" bash -c '
    . "$1"
    S=${LIMIT_CREW:-limit-test}; D="$CREW_HOME/$S"
    pane_scan_capture() { cat "$CREW_HOME/limit-screen"; }
    pane_capture() { cat "$CREW_HOME/limit-screen"; }
    pane_cli() { printf codex; }
    if [ "$4" = moved ]; then pane_of() { printf "%%999999"; }; fi
    reason="provider limit"; [ -n "$3" ] || [ "$4" = unknown ] || reason=""
    limit_wake_lead "$2" codex "$3" "$reason" "$5" "$6"
  ' _ "$CREW_HOME/limit-functions.sh" "${LIMIT_PANE:-$limit_pane}" "$1" "${2:-}" "${3:-}" "${4:-}"
}
limit_backdate() { printf '%s|11:15|1|0\n' "$limit_pane" > "$limit_dir/limit-wake/lead"; }
limit_attempts() {
  if [ -f "$limit_dir/inbox/lead.md" ]; then awk '/^Your printed usage-limit/{n++} END{print n+0}' "$limit_dir/inbox/lead.md"
  else printf '0\n'; fi
}
check 'limited lead schedules a wake without an immediate retry' limit_run 11:15
check 'schedule has no early retry' test "$(limit_attempts)" = 0
limit_backdate
check 'a changed role mapping refuses dispatch' limit_run 11:15 moved
check 'a successor gets no old-lead retry' test "$(limit_attempts)" = 0
limit_backdate
check 'lead receives a guarded retry after reset' limit_run 11:15
check 'retry is recorded exactly once' test "$(limit_attempts)" = 1
check 'retry message reaches the lead inbox' grep -q 'Retry your last request' "$limit_dir/inbox/lead.md"
check 'a fresh watcher does not repeat the same retry' limit_run 11:15
check 'persistent claim prevents duplicates' test "$(limit_attempts)" = 1
limit_backdate
printf '%s\n' "$limit_banner" '• Working (esc to interrupt)' '› ' > "$CREW_HOME/limit-screen"
check 'active generation defers a stale-banner retry' limit_run 11:15
check 'busy lead gets no retry' test "$(limit_attempts)" = 1
printf '%s\n' "$limit_banner" '› unfinished user draft' > "$CREW_HOME/limit-screen"
check 'draft holds the wake doorbell' limit_run 11:15
check 'held wake records a pending inbox reminder' test -f "$limit_dir/pending/lead"
check 'held wake logs the draft hold' grep -q 'unsubmitted draft' "$limit_dir/channel.log"
limit_backdate
printf '%s\n' "$limit_banner" 'Would you like to run the following command?' '› 1. Yes' > "$CREW_HOME/limit-screen"
check 'dialog holds the wake doorbell' limit_run 11:15
check 'held wake logs the approval hold' grep -q 'dialog or approval' "$limit_dir/channel.log"
limit_backdate
printf '%s\n' "$limit_banner" '› ' > "$CREW_HOME/limit-screen"
limit_before_stale=$(limit_attempts)
tmux set-option -p -t "$limit_pane" @crew_role foreign
check 'missing ownership refuses a wake' limit_run 11:15
check 'stale pane gets no retry message' test "$(limit_attempts)" = "$limit_before_stale"
tmux set-option -p -t "$limit_pane" @crew_role lead
check 'cleared banner rearms the wake record' limit_run ''
check 'clear removes the claim' test ! -f "$limit_dir/limit-wake/lead"

# Exercise the watch integration for both roles, including the default-off
# path. CLI processes/captures are fixtures; event, claim and delivery paths
# are the production helpers, operating solely on this disposable crew.
awk -F'\t' 'BEGIN{OFS="\t"} {$3="codex"; print}' "$limit_dir/panes" > "$limit_dir/panes.next"
mv "$limit_dir/panes.next" "$limit_dir/panes"
rm -f "$limit_dir/pending/lead"
limit_worker=$(awk -F'\t' '$1=="worker"{print $2}' "$limit_dir/panes")
limit_scan() { # ring? wake?
  CREW_SHARE="$ROOT/share/crew" bash -c '
    . "$1"
    S=limit-test; D="$CREW_HOME/$S"
    pane_scan_capture() {
      if [ "$1" = "$lead_pane" ]; then cat "$CREW_HOME/limit-lead-screen"
      else cat "$CREW_HOME/limit-screen"; fi
    }
    pane_capture() { pane_scan_capture "$1"; }
    pane_cli() { printf codex; }
    cache=$(mktemp -d "$CREW_HOME/limit-scan.XXXXXX")
    lead_pane="$2"
    watch_scan "$cache" 0 "$3" "$4"
    rm -rf "$cache"
  ' _ "$CREW_HOME/limit-functions.sh" "$limit_pane" "$1" "$2"
}
printf '%s\n' '› ' > "$CREW_HOME/limit-lead-screen"
limit_before_worker=$(limit_attempts)
check 'worker limit is handled by the watcher' limit_scan 1 1
check 'worker reset time reaches lead' grep -q 'worker errored: provider limit (reset 11:15 local)' "$limit_dir/inbox/lead.md"
check 'worker alert leaves the model-aware handover to lead' grep -q 'lead decides whether to wait or hand over with a suitable model' "$limit_dir/inbox/lead.md"
check 'worker does not schedule an automatic wake' test ! -f "$limit_dir/limit-wake/worker"
check 'worker does not trigger a retry' test "$(limit_attempts)" = "$limit_before_worker"
printf '%s\n' "$limit_banner" '› ' > "$CREW_HOME/limit-lead-screen"
check 'stdout watch does not schedule wakes' limit_scan 0 1
check 'stdout watch leaves claims absent' test ! -f "$limit_dir/limit-wake/lead"
check 'ringing watch schedules the opted-in lead' limit_scan 1 1
check 'watch integration creates the lead claim' test -f "$limit_dir/limit-wake/lead"
limit_backdate
check 'default-off watch does not dispatch a previous claim' limit_scan 1 0
check 'default-off leaves the retry count unchanged' test "$(limit_attempts)" = "$limit_before_worker"
check 'enabled watch dispatches a due lead claim' limit_scan 1 1
check 'watch integration retries lead exactly once' test "$(limit_attempts)" = "$((limit_before_worker+1))"
limit_backdate
limit_run 11:15 & limit_first=$!
limit_run 11:15 & limit_second=$!
wait "$limit_first"; wait "$limit_second"
check 'concurrent watchers claim only one retry' test "$(limit_attempts)" = "$((limit_before_worker+2))"
limit_run ''
touch "$limit_dir/ended"
check 'ended crew refuses scheduling' limit_run 11:15
check 'ended crew has no new claim' test ! -f "$limit_dir/limit-wake/lead"
"$CREW" -s limit-test down >/dev/null 2>&1

# Long limits hand lead over to the opted-in successor spec; short ones wake.
# The successor is a real `cat` pane spawned by the production override path.
CREW_WATCH_EVERY=60 "$CREW" up limit-handover --in "$TS" --handover-on-limit cat --max-wait 6h \
  "lead=sh $limit_mock $CREW_HOME/limit-screen" worker=cat >/dev/null 2>&1
LIMIT_CREW=limit-handover; export LIMIT_CREW
hand_dir="$CREW_HOME/limit-handover"
hand_lead=$(awk -F'\t' '$1=="lead"{print $2}' "$hand_dir/panes")
hand_id=$("$CREW" -s limit-handover timers | awk '$2=="watch"{print $1}')
check 'up persists the handover spec and max wait' test "$(cut -f4- "$hand_dir/timers/$hand_id/config")" = "1	cat	21600"
check 'handover implies the wake opt-in' grep -q "handover over 6h00m to 'cat'" "$hand_dir/timers/$hand_id/message"
"$CREW" -s limit-handover timers cancel "$hand_id" >/dev/null
LIMIT_PANE=$hand_lead; export LIMIT_PANE
hand_state() { cut -d '|' -f4 "$hand_dir/limit-wake/lead" 2>/dev/null; }
hand_screen() { # seconds-until-reset -> a dated Codex banner on the fixture screen
  printf "You've hit your usage limit. Try again at %s on %s.\n› \n" \
    "$(LC_ALL=C date -r $(( $(date +%s) + $1 )) '+%I:%M %p')" "$(LC_ALL=C date -r $(( $(date +%s) + $1 )) '+%B %d')" > "$CREW_HOME/limit-screen"
}
hand_reset() { limit_clock < "$CREW_HOME/limit-screen"; }
hand_screen 7200
check 'a dated reset within max-wait is parsed' test -n "$(hand_reset)"
check 'a weekly reset due soon waits instead of handing over' limit_run "$(hand_reset)" - cat 21600
check 'a soon reset schedules a wake' test "$(hand_state)" = 0
hand_screen $((3*86400))
check 'a reset beyond max-wait schedules a handover' limit_run "$(hand_reset)" - cat 21600
check 'the long reset is pending handover' test "$(hand_state)" = h
check 'pending handover is logged with the wait' grep -q "handing lead over to 'cat' in 300s unless it clears" "$hand_dir/channel.log"
check 'handover waits for the banner to persist' limit_run "$(hand_reset)" - cat 21600
check 'early scans leave lead in place' test "$(awk -F'\t' '$1=="lead"{print $2}' "$hand_dir/panes")" = "$hand_lead"
hand_backdate() { printf '%s|%s|1|h\n' "$hand_lead" "$(hand_reset)" > "$hand_dir/limit-wake/lead"; }
hand_backdate
printf "%s\n• Working (esc to interrupt)\n› \n" "$(head -1 "$CREW_HOME/limit-screen")" > "$CREW_HOME/limit-screen.busy"
cp "$CREW_HOME/limit-screen" "$CREW_HOME/limit-screen.idle"; cp "$CREW_HOME/limit-screen.busy" "$CREW_HOME/limit-screen"
check 'a busy lead is not handed over' limit_run "$(hand_reset)" - cat 21600
check 'busy lead keeps its pane' test "$(awk -F'\t' '$1=="lead"{print $2}' "$hand_dir/panes")" = "$hand_lead"
cp "$CREW_HOME/limit-screen.idle" "$CREW_HOME/limit-screen"
check 'an outsider cannot borrow the watcher identity' \
  bash -c '! limit_handover_by=watch CREW_SESSION=limit-handover CREW_AGENT=worker "$1" override lead=cat' _ "$CREW"
check 'a persisted long limit hands lead over' limit_run "$(hand_reset)" - cat 21600
hand_new=$(awk -F'\t' '$1=="lead"{print $2}' "$hand_dir/panes")
check 'the successor pane is the new lead' test -n "$hand_new" -a "$hand_new" != "$hand_lead"
check 'the successor runs the given spec' awk -F'\t' '$1=="lead" && $3=="cat" && $4=="spawned"{f=1} END{exit !f}' "$hand_dir/panes"
check 'the handover is claimed' test "$(hand_state)" = H
check 'the successor is recorded' test "$(cat "$hand_dir/limit-wake/successor")" = "$hand_new"
check 'the override names the watcher as caller' grep -q 'watch overrode lead' "$hand_dir/channel.log"
check 'the old lead context is saved' bash -c 'ls "$1"/out/override-lead-*.md' _ "$hand_dir"
check 'the old lead pane is detached but open' test "$(tmux display-message -p -t "$hand_lead" '#{@crew_role}')" = ''
check 'a fresh watcher does not hand over again' limit_run "$(hand_reset)" - cat 21600
check 'only one successor pane exists' test "$(awk -F'\t' '$1=="lead"' "$hand_dir/panes" | wc -l | tr -d ' ')" = 1
LIMIT_PANE=$hand_new
check 'a limited successor waits rather than chaining handovers' limit_run "$(hand_reset)" - cat 21600
check 'the successor schedules its own wake' test "$(hand_state)" = 0
limit_run ''
check 'an unknown reset without a handover spec stays manual' limit_run '' unknown
check 'unknown reset leaves no claim' test ! -f "$hand_dir/limit-wake/lead"
rm -f "$hand_dir/limit-wake/successor"
check 'an unknown reset with a handover spec schedules one' limit_run '' unknown cat 21600
check 'unknown reset is pending handover' test "$(hand_state)" = h
check 'a lost reset keeps the same pending record' limit_run '' unknown cat 21600
check 'the record is not replaced by an unknown one' test "$(cut -d '|' -f2 "$hand_dir/limit-wake/lead")" = unknown
hand_screen $((3*86400)); limit_run "$(hand_reset)" - cat 21600
check 'a reset that stops parsing keeps its known record' limit_run '' unknown cat 21600
check 'the known reset stays recorded' test "$(cut -d '|' -f2 "$hand_dir/limit-wake/lead")" = "$(hand_reset)"
check 'a cleared banner cancels the pending handover' limit_run ''
check 'clear removes the pending handover' test ! -f "$hand_dir/limit-wake/lead"
unset LIMIT_CREW LIMIT_PANE
"$CREW" -s limit-handover down >/dev/null 2>&1
