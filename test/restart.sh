# A private tmux server reproduces id reuse across a real server restart.
# Never stop or restart the user's default server.
restart_identity_test() (
  local real_tmux old fresh before scratch="$CREW_HOME/restart"
  real_tmux=$(command -v tmux)
  mkdir -p "$scratch/bin" "$scratch/home"
  export CREW_RESTART_TMUX="$real_tmux" CREW_RESTART_SOCKET="crew-restart-$$"
  cat > "$scratch/bin/tmux" <<'WRAPPER'
#!/bin/sh
exec "$CREW_RESTART_TMUX" -L "$CREW_RESTART_SOCKET" -f /dev/null "$@"
WRAPPER
  chmod +x "$scratch/bin/tmux"
  export PATH="$scratch/bin:$PATH" CREW_HOME="$scratch/home" TMUX=""
  unset TMUX_PANE CREW_AGENT CREW_SESSION
  trap 'tmux kill-session -t restart >/dev/null 2>&1 || true' EXIT
  old=$(tmux new-session -d -s restart -P -F '#{pane_id}' cat)
  "$CREW" adopt restart lead="$old" > "$scratch/adopt-out" 2>&1 || return 1
  # Ending the only session exits this private server and resets its id counter.
  tmux kill-session -t restart
  for i in $(seq 1 50); do tmux list-sessions >/dev/null 2>&1 || break; sleep 0.1; done
  fresh=$(tmux new-session -d -s restart -P -F '#{pane_id}' cat)
  [ "$old" = "$fresh" ] || { echo 'private server did not reuse its pane id'; return 1; }
  before=$(tmux capture-pane -p -t "$fresh" | cksum)
  "$CREW" -s restart status > "$scratch/status"
  "$CREW" ls > "$scratch/list"
  grep -q 'STALE (pane reused)' "$scratch/status" || return 1
  grep -q 'lead=cat(reused)' "$scratch/list" || return 1
  "$CREW" -s restart send lead restart-must-not-ring > "$scratch/send-out" 2> "$scratch/send-err"
  grep -q 'gone or now belongs to something else' "$scratch/send-err" || return 1
  grep -q restart-must-not-ring "$CREW_HOME/restart/inbox/lead.md" || return 1
  [ "$(tmux capture-pane -p -t "$fresh" | cksum)" = "$before" ] || return 1
  "$CREW" -s restart down > "$scratch/down-out" 2> "$scratch/down-err"
  [ "$(tmux display-message -p -t "$fresh" '#{pane_id}')" = "$fresh" ] || return 1
  [ "$(tmux capture-pane -p -t "$fresh" | cksum)" = "$before" ]
)
check "server restart: reused same-CLI pane stays stale, never rung or closed" restart_identity_test
