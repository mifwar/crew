# Sourced by smoke.sh: held doorbells (pending re-rings) and pi's Working
# border. Shares smoke.sh's scratch CREW_HOME, detached session and `check`.
# Every path here is a throwaway crew in that detached session; nothing types
# into a pane without checking it is still the crew's.
#
# A focused harness for this file alone (much faster than the whole suite):
#   ROOT=<checkout>; . test/rings.sh  -- after the smoke preamble (CREW_HOME,
#   $TS detached session, bin/claude + bin/pi fixtures, check/screen_has).

# --- pi's mid-turn editor box -------------------------------------------------
# A real pi frame (297x32, cursor_y 27) while a turn runs: pi embeds the Working
# spinner in the box's top border. These are that frame's own rows, with the
# transcript above them dropped; the borders are generated at that width.
nd() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "─" }'; }
spinner=$(awk 'BEGIN { printf "%c%c%c", 226, 160, 187 }')
pi_w=297
pi_frame() { # [content rows...] — a mid-turn frame; cursor sits under the top border
  printf '── %s Working %s\n' "$spinner" "$(nd $((pi_w - 3 - 9 - 1)))"
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; else printf '\n'; fi
  printf '%s\n' "$(nd "$pi_w")"
  printf '%s\n' '/tmp/crew-sigil-rings (work/sigil-rings)' \
    '↑51k ↓3.9k R656k CH99.3% $0.012 5.0%/1.0M (auto)' \
    '(commandcode) deepseek/deepseek-v4.1-flash • high' \
    '⚡ 5h 100% → 4h47m · wk 77% → Wed 19:48 · mo 39% → 14 Nov 14:22'
}
pi_cells_is() { # want(idle|draft) rows...
  local want="$1" got; shift
  got=$(pi_frame "$@" | pi_box_text "$pi_w 32 27")
  if [ "$want" = idle ]; then [ -z "$got" ]; else [ -n "$got" ]; fi
}
. "$ROOT/share/crew/pane.sh"
check 'pi working frame: no draft (real 297x32 mid-turn frame)' pi_cells_is idle
check 'pi working frame: a real draft row is still a draft' pi_cells_is draft 'type this'
# tmux -J pads the row under a wrapped full-width border with spaces; reading
# that padding as text is the field report's "draft pending" for a working pi.
check 'pi working frame: -J padding between borders is not a draft' pi_cells_is idle '   '
check 'pi working frame: a dashes draft row under a Working border holds' pi_cells_is draft "$(nd 200)"
check 'pi working frame: wrapped draft rows still join' \
  test "$(pi_frame 'one' 'two' | pi_box_text "$pi_w 32 27")" = 'one two'
# status and watch read pi from the raw screen: -J would also merge transcript
# rows with the box's borders.
check 'pi scans capture the raw screen, not -J' bash -c '
  tmux() { printf "%s\n" "$*"; }
  short_cli() { printf pi; }
  . "$1/share/crew/pane.sh"
  out=$(pane_scan_capture %1 pi)
  case "$out" in *capture-pane*-J*) exit 1 ;; *capture-pane*) exit 0 ;; esac
  exit 1' _ "$ROOT"
check 'claude scans still join soft wraps' bash -c '
  tmux() { printf "%s\n" "$*"; }
  short_cli() { printf claude; }
  pane_capture() { printf "captured %s\n" "$*"; }
  . "$1/share/crew/pane.sh"
  pane_scan_capture %1 claude | grep -q -- "-J"' _ "$ROOT"

# --- pending counters: state and locking -------------------------------------
sed -n '/^take_lock()/,/^}/p' "$CREW" > "$CREW_HOME/rings-lock.sh"
mkdir -p "$CREW_HOME/rings-unit"
check 'a held doorbell is one pending count for the role' bash -c '
  D="$3"; . "$1"; . "$2"
  rm -rf "$D/pending"
  pending_add lead && pending_add lead
  test "$(pending_count lead)" = 2 && test "$(cat "$D/pending/lead")" = 2' \
  _ "$CREW_HOME/rings-lock.sh" "$ROOT/share/crew/pane.sh" "$CREW_HOME/rings-unit"
check 'a held counter is written in one piece' bash -c '
  D="$3"; . "$1"; . "$2"
  rm -rf "$D/pending"
  pending_add lead
  test "$(wc -l < "$D/pending/lead" | tr -d " ")" = 1 && ! ls "$D"/pending/*.tmp.* >/dev/null 2>&1' \
  _ "$CREW_HOME/rings-lock.sh" "$ROOT/share/crew/pane.sh" "$CREW_HOME/rings-unit"
check 'concurrent held sends lose no count' bash -c '
  D="$3"; . "$1"; . "$2"
  rm -rf "$D/pending"
  for i in 1 2 3 4 5 6 7 8; do pending_add lead & done
  wait
  test "$(pending_count lead)" = 8' \
  _ "$CREW_HOME/rings-lock.sh" "$ROOT/share/crew/pane.sh" "$CREW_HOME/rings-unit"
# A live section can pause; a focused lock is deferred, never force-broken.
check 'a busy pending lock defers instead of being stolen' bash -c '
  D="$3"; . "$1"; . "$2"
  mkdir "$D/pending/.lead.lock"
  ! pending_add lead
  test "$(pending_count lead)" = 8 && test -d "$D/pending/.lead.lock"' \
  _ "$CREW_HOME/rings-lock.sh" "$ROOT/share/crew/pane.sh" "$CREW_HOME/rings-unit"
check '  and works as soon as the holder releases it' bash -c '
  D="$3"; . "$1"; . "$2"
  rmdir "$D/pending/.lead.lock"
  pending_add lead && test "$(pending_count lead)" = 9' \
  _ "$CREW_HOME/rings-lock.sh" "$ROOT/share/crew/pane.sh" "$CREW_HOME/rings-unit"
rm -rf "$CREW_HOME/rings-unit"

# --- held doorbells end to end ------------------------------------------------
mkdir -p "$CREW_HOME/rings-bin"
ln -sf /bin/sh "$CREW_HOME/rings-bin/claude"
ln -sf /bin/sh "$CREW_HOME/rings-bin/pi"
cat > "$CREW_HOME/rings-bin/dialog.sh" <<'DIALOG'
#!/bin/sh
# A claude-shaped pane showing an approval prompt until a key arrives.
printf 'Do you want to proceed?\n'
printf '❯ 1. Yes\n  2. No\n'
while IFS= read -r line; do
  printf '\033[2J\033[H❯ '
done
DIALOG
cat > "$CREW_HOME/rings-bin/pi.sh" <<'PIMOCK'
#!/bin/sh
# A pi-shaped pane: draws its mid-turn editor box at the pane's real width
# (Working spinner embedded in the top border), then reads doorbells.
draw() {
  w=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null) || w=80
  case "$w" in ''|*[!0-9]*) w=80 ;; esac
  dashes() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "─" }'; }
  printf '── %s Working %s\n' "$(printf '\342\240\273')" "$(dashes $((w - 13)))"
  printf '\n'
  printf '%s\n' "$(dashes "$w")"
  printf '%s\n' '/tmp/crew-sigil-rings (work/sigil-rings)'
  printf '%s\n' '↑51k ↓3.9k R656k CH99.3% $0.012 5.0%/1.0M (auto)'
  printf '%s\n' '(commandcode) deepseek/deepseek-v4.1-flash • high'
}
draw
while IFS= read -r line; do
  printf 'received:%s\n' "$line"
  draw
done
PIMOCK
chmod +x "$CREW_HOME/rings-bin/dialog.sh" "$CREW_HOME/rings-bin/pi.sh"
cat > "$CREW_HOME/rings-bin/edit.sh" <<'EDITOR'
#!/bin/sh
# A claude-shaped editor: prints its idle prompt and consumes submitted lines.
while :; do printf '❯ '; read -r line; done
EDITOR
chmod +x "$CREW_HOME/rings-bin/edit.sh"

"$CREW" up rings --in "$TS" --no-watch "lead=$CREW_HOME/rings-bin/claude $CREW_HOME/rings-bin/edit.sh" \
  "dlg=$CREW_HOME/rings-bin/claude $CREW_HOME/rings-bin/dialog.sh" \
  "pim=$CREW_HOME/rings-bin/pi $CREW_HOME/rings-bin/pi.sh" \
  > "$CREW_HOME/rings-up" 2>&1
RD="$CREW_HOME/rings"
rings_lead=$(awk -F'\t' '$1=="lead"{print $2}' "$RD/panes")
rings_dlg=$(awk -F'\t' '$1=="dlg"{print $2}' "$RD/panes")
rings_pim=$(awk -F'\t' '$1=="pim"{print $2}' "$RD/panes")
# Fixture sends never wait for a draft: zero keeps every hold/ownership check.
rings_send() { # from-role, then crew send args (never send to yourself)
  local from="$1"; shift
  CREW_RING_WAIT=0 CREW_SESSION=rings CREW_AGENT="$from" "$CREW" send "$@"
}
rings_pending() { cut -f2 "$RD/pending/$1" 2>/dev/null || printf 0; }
rings_screen() { tmux capture-pane -p -J -t "$1"; }
rings_count() { local n; n=$(rings_screen "$1" | grep -cF -- "$2" || true); printf '%s' "$n"; }
rings_count_re() { local n; n=$(rings_screen "$1" | grep -cE -- "$2" || true); printf '%s' "$n"; }
# A replay types its line, then clears the counter and logs: poll the record, so
# a check never races the watcher's own bookkeeping.
rings_pending_is() { # role count
  local tries=0
  until [ "$(rings_pending "$1")" = "$2" ]; do
    tries=$((tries+1)); [ "$tries" -lt 40 ] || return 1; sleep 0.2
  done
}
rings_log_count() { local n; n=$(grep -cE -- "$1" "$RD/channel.log" 2>/dev/null || true); printf '%s' "${n:-0}"; }
rings_log_is() { # pattern count
  local tries=0 n
  while :; do
    n=$(grep -cE -- "$1" "$RD/channel.log" 2>/dev/null || true)
    [ "$n" = "$2" ] && return 0
    tries=$((tries+1)); [ "$tries" -lt 40 ] || return 1; sleep 0.2
  done
}
rings_until() { # pane text — poll the pane, not a file
  local tries=0
  until rings_screen "$1" | grep -qF -- "$2"; do
    tries=$((tries+1)); [ "$tries" -lt 60 ] || return 1; sleep 0.2
  done
}
[ -n "$rings_lead" ] && [ -n "$rings_dlg" ] && [ -n "$rings_pim" ] || {
  echo "FAIL  rings fixture panes missing: not typing anywhere"; exit 1; }

# A working pi is not a draft: status says nothing and its doorbell gets typed.
"$CREW" -s rings status > "$CREW_HOME/rings-status-pi"
check 'status does not flag a working pi as a draft' \
  bash -c '! awk "\$1==\"pim\"" "$1" | grep -q "draft pending"' _ "$CREW_HOME/rings-status-pi"
check '  the working pi pane is observed as busy' bash -c '
  . "$2/share/crew/watch.sh"
  tmux capture-pane -p -t "$1" | pane_observation pi | grep -q "^busy|"' \
  _ "$rings_pim" "$ROOT"
check 'a working pi pane accepts a doorbell' \
  bash -c 'CREW_RING_WAIT=0 CREW_SESSION=rings CREW_AGENT=dlg "$1" send pim pi-working-doorbell >/dev/null 2>&1' \
  _ "$CREW"
check '  the doorbell reached it' rings_until "$rings_pim" 'pi-working-doorbell'
check '  and is not recorded as pending' test "$(rings_pending pim)" = 0

# A held doorbell is remembered, then replayed once by a ringing watcher.
rings_send dlg lead 'typed-normally' >/dev/null 2>&1
check 'a free lead gets its doorbell' rings_until "$rings_lead" 'typed-normally'
tmux send-keys -t "$rings_lead" -l 'a draft of my own'; sleep 0.5
rings_send dlg lead 'first-held' >/dev/null 2>&1
rings_send dlg lead 'second-held' >/dev/null 2>&1
check 'a held doorbell types nothing' bash -c '! tmux capture-pane -p -J -t "$1" | grep -qF first-held' _ "$rings_lead"
check '  the messages are in the inbox exactly once' \
  bash -c 'test "$(grep -c "first-held" "$1/inbox/lead.md")" = 1 && grep -q second-held "$1/inbox/lead.md"' _ "$RD"
check '  both held deliveries coalesce into one count' test "$(rings_pending lead)" = 2
check '  the timeline names the hold and the pending re-ring' \
  grep -q 'lead not rung: .*unsubmitted draft.*one re-ring pending' "$RD/channel.log"

# stdout watch is read-only: it never replays and never touches pending state.
rings_ls_before=$(ls -A "$RD/pending")
cp "$RD/pending/lead" "$CREW_HOME/rings-pending-before"
rings_typed_before=$(rings_count "$rings_lead" 'new message')
"$CREW" -s rings watch --every 1 --quiet-after 0 > "$CREW_HOME/rings-stdout-watch" 2>&1 & rings_pid=$!
sleep 2.5
check 'stdout watch replays nothing' test "$(rings_count "$rings_lead" 'new message')" = "$rings_typed_before"
check '  and leaves the pending counter alone' cmp "$RD/pending/lead" "$CREW_HOME/rings-pending-before"
check '  and creates no pending state' test "$(ls -A "$RD/pending")" = "$rings_ls_before"
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# A ringing watcher replays once the editor clears, coalesced and once only.
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-ring-watch" 2>&1 & rings_pid=$!
sleep 2
check 'a ringing watcher leaves a draft alone' test "$(rings_count "$rings_lead" 'new message')" = "$rings_typed_before"
# The watcher's own notices for the held pane also become held deliveries, so
# the count only grows here; what matters is that it is not consumed.
check '  and keeps the backlog pending' test "$(rings_pending lead)" -ge 2
tmux send-keys -t "$rings_lead" Enter; sleep 0.3
check 'a held doorbell is replayed after the draft clears' \
  rings_until "$rings_lead" 'new messages — crew inbox lead'
check '  the replay consumed the counter' rings_pending_is lead 0
check '  and logged one replay' rings_log_is 'lead rung for [0-9]+ held message\(s\)' 1
sleep 1.5
check 'the replay is not repeated on later scans' \
  test "$(rings_count_re "$rings_lead" 'new messages — crew inbox lead')" = 1
check '  the inbox kept one entry per message' \
  bash -c 'test "$(grep -c "first-held" "$1/inbox/lead.md")" = 1 && test "$(grep -c "second-held" "$1/inbox/lead.md")" = 1' _ "$RD"
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# The field report's case: held during a dialog, replayed after it closes.
rings_send lead dlg 'held-behind-dialog' >/dev/null 2>&1
check 'a dialog holds the doorbell' test "$(rings_pending dlg)" = 1
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-dialog-watch" 2>&1 & rings_pid=$!
sleep 2
check 'a ringing watcher never types into a dialog' \
  test "$(rings_count "$rings_dlg" 'new message')" = 0
check '  and the dialog delivery stays pending' test "$(rings_pending dlg)" = 1
tmux send-keys -t "$rings_dlg" Enter; sleep 0.2   # the human answers; the pane clears
check 'a dialog-held doorbell is replayed after the dialog closes' \
  rings_until "$rings_dlg" '[crew] watch → dlg: 1 new message — crew inbox dlg'
check '  and the pending counter is spent' rings_pending_is dlg 0
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# A pane that was reused (restart, relabel) is never rung, pending or not.
tmux send-keys -t "$rings_lead" -l 'draft before the relabel'; sleep 0.4
rings_send dlg lead 'held-across-a-relabel' >/dev/null 2>&1
check 'a hold on a live pane is pending' test "$(rings_pending lead)" = 1
tmux send-keys -t "$rings_lead" Enter; sleep 0.3
rings_screen_before=$(tmux capture-pane -p -t "$rings_lead" | cksum)
tmux set-option -p -t "$rings_lead" @crew_session unrelated
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-stale-watch" 2>&1 & rings_pid=$!
sleep 2.5
check 'a reused pane gets no held re-ring' \
  test "$(tmux capture-pane -p -t "$rings_lead" | cksum)" = "$rings_screen_before"
check '  and its pending stays' test "$(rings_pending lead)" = 1
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true
rings_typed_before=$(rings_count "$rings_lead" 'new message')
rings_replays_before=$(rings_log_count 'lead rung for [0-9]+ held message')
tmux set-option -p -t "$rings_lead" @crew_session rings
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-back-watch" 2>&1 & rings_pid=$!
check 'the held ring replays once the pane is the crew'"'"'s again' \
  rings_until "$rings_lead" '[crew] watch → lead: 1 new message — crew inbox lead'
check '  exactly once' \
  rings_log_is 'lead rung for [0-9]+ held message' "$((rings_replays_before + 1))"
check '  and exactly one reminder line' \
  test "$(rings_count "$rings_lead" 'new message')" = "$((rings_typed_before + 1))"
check '  and the counter is spent' rings_pending_is lead 0
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# A pending role whose pane is gone keeps the message and types nowhere.
tmux send-keys -t "$rings_lead" -l 'draft for a gone pane'; sleep 0.4
rings_send dlg lead 'held-for-a-gone-pane' >/dev/null 2>&1
check 'a gone-pane hold is pending' rings_pending_is lead 1
tmux send-keys -t "$rings_lead" Enter; sleep 0.3
cp "$RD/panes" "$CREW_HOME/rings-panes-ok"
awk -F'\t' -v OFS='\t' -v p=%999999 '$1=="lead"{$2=p} {print}' "$RD/panes" > "$RD/panes.next"
mv "$RD/panes.next" "$RD/panes"
rings_screen_before=$(tmux capture-pane -p -t "$rings_lead" | cksum)
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-gone-watch" 2>&1 & rings_pid=$!
sleep 2
check 'a gone pane keeps its held doorbell pending' test "$(rings_pending lead)" = 1
check '  and nothing was typed into its old pane' \
  test "$(tmux capture-pane -p -t "$rings_lead" | cksum)" = "$rings_screen_before"
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true
cp "$CREW_HOME/rings-panes-ok" "$RD/panes"

# An ordinary doorbell that succeeds says nothing about the older backlog, so
# it leaves the counter for the watcher's explicit reminder.
rings_send dlg lead 'fresh-doorbell' >/dev/null 2>&1
check 'an inline doorbell reaches the lead' rings_until "$rings_lead" 'fresh-doorbell'
check '  and leaves the older backlog pending' rings_pending_is lead 1
rings_typed_before=$(rings_count "$rings_lead" 'new message')
rings_replays_before=$(rings_log_count 'lead rung for [0-9]+ held message')
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-backlog-watch" 2>&1 & rings_pid=$!
check 'the watcher still gives the backlog reminder' \
  rings_until "$rings_lead" '[crew] watch → lead: 1 new message — crew inbox lead'
check '  once' rings_log_is 'lead rung for [0-9]+ held message' "$((rings_replays_before + 1))"
check '  one reminder line' \
  test "$(rings_count "$rings_lead" 'new message')" = "$((rings_typed_before + 1))"
check '  then the counter is spent' rings_pending_is lead 0
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# A new hold after that is pending again (the counter is neither lost nor sticky).
tmux send-keys -t "$rings_lead" -l 'draft again'; sleep 0.4
rings_send dlg lead 'held-after-clear' >/dev/null 2>&1
check 'a later hold is pending again' test "$(rings_pending lead)" = 1
tmux send-keys -t "$rings_lead" Enter; sleep 0.2
rings_typed_before=$(rings_count "$rings_lead" 'new message')
rings_replays_before=$(rings_log_count 'lead rung for [0-9]+ held message')
"$CREW" -s rings watch --every 1 --quiet-after 0 --ring > "$CREW_HOME/rings-again-watch" 2>&1 & rings_pid=$!
check '  and is replayed once it clears' \
  rings_until "$rings_lead" '[crew] watch → lead: 1 new message — crew inbox lead'
check '  spending the counter again' rings_pending_is lead 0
check '  once' rings_log_is 'lead rung for [0-9]+ held message' "$((rings_replays_before + 1))"
check '  one reminder line' \
  test "$(rings_count "$rings_lead" 'new message')" = "$((rings_typed_before + 1))"
kill "$rings_pid" 2>/dev/null; wait "$rings_pid" 2>/dev/null || true

# An override can swap roles while a ring waits for the per-pane lock. The
# doorbell names a role, so it must be refused instead of reaching the
# successor's prompt (focused swap-during-lock test).
cp "$RD/panes" "$CREW_HOME/rings-panes-ok"
rings_lock="$RD/.ring${rings_lead#%}.lock"
rings_screen_before=$(tmux capture-pane -p -t "$rings_lead" | cksum)
mkdir "$rings_lock"
rings_send dlg lead 'swapped-while-waiting' > "$CREW_HOME/rings-swap-err" 2>&1 & rings_pid=$!
sleep 1
awk -F'\t' -v OFS='\t' -v old="$rings_lead" -v alt="$rings_dlg" \
  '$1=="lead"{$2=alt} $1=="dlg"{$2=old} {print}' "$RD/panes" > "$RD/panes.next"
mv "$RD/panes.next" "$RD/panes"
tmux set-option -p -t "$rings_lead" @crew_role dlg
tmux set-option -p -t "$rings_dlg" @crew_role lead
rmdir "$rings_lock"
wait "$rings_pid" 2>/dev/null || true
check 'a role swapped during the ring lock is not typed into' \
  test "$(tmux capture-pane -p -t "$rings_lead" | cksum)" = "$rings_screen_before"
check '  the sender is told the pane no longer belongs to the role' \
  grep -q 'no longer belongs to lead' "$CREW_HOME/rings-swap-err"
check '  and the timeline records the refused ring' \
  grep -q 'lead not rung: .*no longer belongs to lead' "$RD/channel.log"
check '  the message is still in the inbox' grep -q 'swapped-while-waiting' "$RD/inbox/lead.md"
check '  and the held delivery is pending for the new binding' test "$(rings_pending lead)" -ge 1
tmux set-option -p -t "$rings_lead" @crew_role lead
tmux set-option -p -t "$rings_dlg" @crew_role dlg
cp "$CREW_HOME/rings-panes-ok" "$RD/panes"
rm -rf "$RD/pending/lead"

# A real draft can appear after the first hold check, while the ring waits.
mkdir "$rings_lock"
rings_send dlg lead 'draft-during-lock' > "$CREW_HOME/rings-draft-lock-err" 2>&1 & rings_pid=$!
sleep 0.5
tmux send-keys -t "$rings_lead" -l 'draft typed while lock was held'
sleep 0.2
rings_screen_before=$(tmux capture-pane -p -t "$rings_lead" | cksum)
rmdir "$rings_lock"
wait "$rings_pid" 2>/dev/null || true
check 'a draft entered during the ring lock stays untouched' \
  test "$(tmux capture-pane -p -t "$rings_lead" | cksum)" = "$rings_screen_before"
check '  the post-lock hold names the draft' grep -q 'unsubmitted draft' "$CREW_HOME/rings-draft-lock-err"
check '  and the refused message stays in the inbox' grep -q 'draft-during-lock' "$RD/inbox/lead.md"

"$CREW" -s rings down >/dev/null 2>&1
