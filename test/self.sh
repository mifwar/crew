# Sourced by smoke.sh; all panes belong to its throwaway tmux session.
check "--self refuses a dead TMUX_PANE before creating crew files" bash -c '
  TMUX_PANE=%999999 "$1" up dead-self --in "$2" --self lead impl=cat > "$3/self-dead-err" 2>&1
  rc=$?
  test "$rc" -ne 0 && test ! -d "$3/dead-self" && grep -q "TMUX_PANE=%999999 is not a live pane" "$3/self-dead-err"
' _ "$CREW" "$TS" "$CREW_HOME"
cat > "$CREW_HOME/self-pipe.sh" <<'SCRIPT'
#!/bin/bash
export CREW_HOME="$2" CREW_NO_SWITCH=1 CREW_BOOT_WAIT=4
"$1" up selfpipe --in "$3" --self lead --here impl=cat 2>&1 | tail -20 > "$2/self-pipe-output"
printf '%s\n' "${PIPESTATUS[0]}" > "$2/self-pipe-rc"
exec cat
SCRIPT
self_pipe=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" "bash '$CREW_HOME/self-pipe.sh' '$CREW' '$CREW_HOME' '$TS'")
for i in $(seq 1 100); do [ -f "$CREW_HOME/self-pipe-rc" ] && break; sleep 0.2; done
check "piped --self binds the calling TMUX_PANE" awk -F '\t' -v p="$self_pipe" '$1=="lead" && $2==p{ok=1} END{exit !ok}' "$CREW_HOME/selfpipe/panes"
check "piped --self succeeds" test "$(cat "$CREW_HOME/self-pipe-rc")" = 0
check "piped --self prints the binding near the final output" grep -qF "self: lead bound to $self_pipe (" "$CREW_HOME/self-pipe-output"
# The pipeline's tail is visible on this fixture tty; never guess another pane.
check "piped --self warns when it detects the filter" grep -q "temporary command pane" "$CREW_HOME/self-pipe-output"
"$CREW" -s selfpipe down >/dev/null
tmux kill-pane -t "$self_pipe"
printf 't\n' > "$CREW_HOME/.current"
