# Sourced by bin/crew. Timers retain messages in files, never shell code.
timer_duration() {
  local value="$1" factor=1
  case "$value" in *s) value=${value%s} ;; *m) value=${value%m}; factor=60 ;; *h) value=${value%h}; factor=3600 ;; esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  value="${value#"${value%%[!0]*}"}"; [ -n "$value" ] || value=0
  [ ${#value} -le 6 ] || return 1
  value=$((10#$value * factor)); [ "$value" -gt 0 ] || return 1
  printf '%s' "$value"
}

timer_when() { # local HH:MM (next occurrence), or +duration -> epoch
  local spec="$1" current day hour minute due seconds
  current=$(date +%s)
  case "$spec" in
    +*) seconds=$(timer_duration "${spec#+}") || return 1; printf '%s' "$((current+seconds))" ;;
    *)
      printf '%s' "$spec" | grep -Eq '^[0-2][0-9]:[0-5][0-9]$' || return 1
      hour=${spec%:*}; minute=${spec#*:}; [ "$((10#$hour))" -le 23 ] || return 1
      day=$(date '+%Y-%m-%d')
      due=$(date -j -f '%Y-%m-%d %H:%M:%S' "$day $hour:$minute:00" +%s 2>/dev/null) || return 1
      if [ "$due" -le "$current" ]; then
        due=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$day $hour:$minute:00" +%s 2>/dev/null) || return 1
      fi
      printf '%s' "$due" ;;
  esac
}

timer_pid_is() { # dir; reject stale/reused pids before sending a signal
  local pid started actual args
  [ -f "$1/owner" ] || return 1
  IFS="$(printf '\t')" read -r pid started < "$1/owner"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
  actual=$(ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$actual" = "$started" ] || return 1
  args=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$args" in *"$_self -s $S _timer ${1##*/}") return 0 ;; *) return 1 ;; esac
}

timer_stop() { # dir; caller holds .timers.lock (also serializes delivery)
  local pid started
  [ -d "$1" ] || return 0
  [ ! -f "$1/done" ] || return 0
  touch "$1/cancelled"
  if timer_pid_is "$1"; then
    IFS="$(printf '\t')" read -r pid started < "$1/owner"
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

timer_cancel_all() { # caller holds .timers.lock
  local dir
  for dir in "$D"/timers/*; do [ ! -d "$dir" ] || timer_stop "$dir"; done
}

timer_worker_unlock() {
  if [ "${timer_locked:-0}" = 1 ]; then rmdir "$D/.timers.lock" 2>/dev/null || true; timer_locked=0; fi
}

timer_worker_cleanup() {
  timer_worker_unlock
  [ -z "${timer_sleep:-}" ] || kill "$timer_sleep" 2>/dev/null || true
}

cmd_timer_run() { # private subprocess entry; only the recorded pid may run it
  resolve_session
  [ $# -eq 1 ] || die 'invalid timer worker'
  local id="$1" dir pid started kind interval role due message timer_locked=0 timer_sleep=""
  printf '%s' "$id" | grep -Eq '^timer-[0-9]+-[0-9]+$' || die 'invalid timer id'
  dir="$D/timers/$id"
  [ -d "$dir" ] || return 0
  trap timer_worker_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Parent publishes owner and ready while holding the timer lock.
  while [ ! -f "$dir/ready" ]; do
    if [ -f "$D/ended" ] || [ -f "$dir/cancelled" ]; then
      timer_worker_cleanup; trap - EXIT INT TERM; return 0
    fi
    sleep 0.1 & timer_sleep=$!; wait "$timer_sleep" || true; timer_sleep=""
  done
  IFS="$(printf '\t')" read -r pid started < "$dir/owner"
  [ "$pid" = "$$" ] || die 'timer worker is not the recorded process'
  IFS="$(printf '\t')" read -r kind interval role < "$dir/config"
  message=""
  IFS= read -r -d '' message < "$dir/message" || true
  while [ ! -f "$D/ended" ] && [ ! -f "$dir/cancelled" ]; do
    due=$(cat "$dir/next")
    if [ "$(date +%s)" -ge "$due" ]; then
      take_lock "$D/.timers.lock" 50 || die 'timers are locked'
      timer_locked=1
      if [ -f "$D/ended" ] || [ -f "$dir/cancelled" ]; then timer_worker_unlock; break; fi
      # Use the same inbox + ownership + draft/dialog hold as crew send.
      # Clear the launching pane: a lead scheduling itself still needs a ring.
      local ME=timer VIA="" TMUX_PANE=""
      log_line dm timer "$role" "$message"
      CREW_RING_WAIT=0 deliver "$role" "$message" "$role"
      if [ "$kind" = at ]; then
        touch "$dir/done"
        timer_worker_unlock
        break
      fi
      printf '%s\n' "$(( $(date +%s) + interval ))" > "$dir/next"
      timer_worker_unlock
    fi
    sleep 1 & timer_sleep=$!; wait "$timer_sleep" || true; timer_sleep=""
  done
  timer_worker_cleanup
  trap - EXIT INT TERM
}

cmd_timer_add() { # at|every schedule role message...
  resolve_session; resolve_me
  [ $# -ge 4 ] || die 'usage: crew at <HH:MM|+30m> <role> <message> / crew every <30m> <role> <message>'
  local kind="$1" spec="$2" role="$3" interval=0 due id dir pid started
  shift 3
  [ -n "$(pane_of "$role")" ] || die "no agent '$role'"
  if [ "$kind" = every ]; then
    interval=$(timer_duration "$spec") || die "bad interval: $spec"
    due=$(( $(date +%s) + interval ))
  else due=$(timer_when "$spec") || die "bad time: $spec"; fi
  lock timers
  [ ! -f "$D/ended" ] || die 'crew has ended'
  id="timer-$(date +%s)-$$"; dir="$D/timers/$id"
  mkdir -p "$D/timers"; mkdir "$dir"
  printf '%s\t%s\t%s\n' "$kind" "$interval" "$role" > "$dir/config"
  printf '%s\n' "$due" > "$dir/next"
  printf '%s' "$*" > "$dir/message"
  CREW_HOME="$CREW_HOME" CREW_SHARE="$CREW_SHARE" TMUX_PANE="" \
    nohup "$_self" -s "$S" _timer "$id" > "$dir/worker.log" 2>&1 < /dev/null & pid=$!
  started=$(ps -p "$pid" -o lstart=)
  printf '%s\t%s\n' "$pid" "$started" > "$dir/owner"
  touch "$dir/ready"
  unlock
  log_line sys "$ME" "$role" "scheduled $id: $kind $spec"
  printf '%s\n' "$id"
}

cmd_timers() {
  resolve_session
  local dir id kind interval role due pid started state next_time
  case "${1:-}" in
    cancel)
      [ $# -eq 2 ] || die 'usage: crew timers cancel <id>'
      id="$2"; printf '%s' "$id" | grep -Eq '^timer-[0-9]+-[0-9]+$' || die 'invalid timer id'
      dir="$D/timers/$id"; [ -d "$dir" ] || die "no timer '$id'"
      lock timers; timer_stop "$dir"; unlock
      log_line sys timer - "cancelled $id"
      printf 'cancelled %s\n' "$id" ;;
    '')
      { printf 'ID\tKIND\tROLE\tNEXT (local time)\tSTATE\tMESSAGE\n'
      for dir in "$D"/timers/*; do
        [ -d "$dir" ] && [ -f "$dir/ready" ] || continue
        IFS="$(printf '\t')" read -r kind interval role < "$dir/config"
        due=$(cat "$dir/next"); state=stopped
        next_time=$(date -r "$due" '+%Y-%m-%d %H:%M:%S')
        if [ -f "$dir/cancelled" ]; then state=cancelled
        elif [ -f "$dir/done" ]; then state=done
        elif timer_pid_is "$dir"; then state=waiting; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${dir##*/}" "$kind" "$role" "$next_time" "$state" "$(oneline "$(cat "$dir/message")")"
      done; } | column -t -s "$(printf '\t')" ;;
    *) die "bad timers option: $1" ;;
  esac
}
