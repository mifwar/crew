# Sourced by bin/crew. Timers retain messages in files, never shell code.
timer_when() { # local HH:MM (next occurrence), or +duration -> epoch
  local spec="$1" current day hour minute due seconds
  current=$(date +%s)
  case "$spec" in
    +*) seconds=$(duration "${spec#+}") || return 1; [ "$seconds" -gt 0 ] || return 1
        printf '%s' "$((current+seconds))" ;;
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

timer_stop() { # dir; coordinate with this timer only, never hold the crew timer lock
  local pid started dispatch="$1/.dispatch.lock"
  [ -d "$1" ] || return 0
  take_lock "$dispatch" 50 || die "timer dispatch is locked: $1"
  [ -f "$1/done" ] || touch "$1/cancelled"
  if timer_pid_is "$1"; then
    IFS="$(printf '\t')" read -r pid started < "$1/owner"
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rmdir "$dispatch"
}

timer_mark_all() { # caller holds .timers.lock; no pane I/O or process waits
  local dir
  for dir in "$D"/timers/*; do
    [ -d "$dir" ] || continue
    [ -f "$dir/done" ] || touch "$dir/cancelled"
  done
}

# Spawn the private worker for a published record and record its identity.
# Caller holds the timer lock and has written config/next/message.
timer_publish() { # dir
  local dir="$1" pid started
  CREW_HOME="$CREW_HOME" CREW_SHARE="$CREW_SHARE" TMUX_PANE="" \
    nohup "$_self" -s "$S" _timer "${dir##*/}" > "$dir/worker.log" 2>&1 < /dev/null & pid=$!
  started=$(ps -p "$pid" -o lstart=)
  printf '%s\t%s\n' "$pid" "$started" > "$dir/owner"
  [ ! -f "$dir/cancelled" ] && kill -0 "$pid" 2>/dev/null || die 'timer worker failed before publication'
  touch "$dir/ready"
}

timer_cancel_all() { # called after the crew timer lock is released
  local dir
  for dir in "$D"/timers/*; do [ ! -d "$dir" ] || timer_stop "$dir"; done
}

timer_worker_unlock() {
  if [ "${timer_locked:-0}" = 1 ]; then timer_locked=0; rmdir "$D/.timers.lock" 2>/dev/null || true; fi
}

timer_worker_dispatch_unlock() {
  if [ "${timer_dispatching:-0}" = 1 ]; then timer_dispatching=0; rmdir "$dir/.dispatch.lock" 2>/dev/null || true; fi
}

timer_worker_cleanup() {
  timer_worker_dispatch_unlock
  timer_worker_unlock
  [ -z "${timer_sleep:-}" ] || kill "$timer_sleep" 2>/dev/null || true
}

cmd_timer_run() { # private subprocess entry; only the recorded pid may run it
  resolve_session
  [ $# -eq 1 ] || die 'invalid timer worker'
  local id="$1" dir pid started kind interval role due message wake_on_limit handover max_wait timer_locked=0 timer_sleep="" timer_dispatching=0 ready_tries=0 launcher
  printf '%s' "$id" | grep -Eq '^timer-[0-9]+-[0-9]+$' || die 'invalid timer id'
  dir="$D/timers/$id"
  [ -d "$dir" ] || return 0
  trap timer_worker_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Parent publishes owner and ready while holding the timer lock.
  launcher=${id##*-}
  while [ ! -f "$dir/ready" ]; do
    ready_tries=$((ready_tries+1))
    if [ -f "$D/ended" ] || [ -f "$dir/cancelled" ] || ! kill -0 "$launcher" 2>/dev/null || [ "$ready_tries" -ge 50 ]; then
      touch "$dir/cancelled"
      timer_worker_cleanup; trap - EXIT INT TERM; return 0
    fi
    sleep 0.1 & timer_sleep=$!; wait "$timer_sleep" || true; timer_sleep=""
  done
  IFS="$(printf '\t')" read -r pid started < "$dir/owner"
  [ "$pid" = "$$" ] || die 'timer worker is not the recorded process'
  IFS="$(printf '\t')" read -r kind interval role wake_on_limit handover max_wait < "$dir/config"
  message=""
  IFS= read -r -d '' message < "$dir/message" || true
  if [ "$kind" = watch ]; then
    # A standing watcher is a timer record too: same owner/ready handshake,
    # listing, cancellation and down path. Its worker scans panes and rings
    # the lead instead of dispatching one recorded message.
    trap 'watch_cleanup; timer_worker_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    watch_cache=$(mktemp -d "${TMPDIR:-/tmp}/crew-watch.XXXXXX")
    watch_loop "$watch_cache" "$interval" "$watch_quiet_default" 1 "$dir/cancelled" "${wake_on_limit:-0}" "${handover:-}" "${max_wait:-}"
    watch_cleanup
    timer_worker_cleanup
    trap - EXIT INT TERM
    return 0
  fi
  while [ ! -f "$D/ended" ] && [ ! -f "$dir/cancelled" ]; do
    due=$(cat "$dir/next")
    if [ "$(date +%s)" -ge "$due" ]; then
      take_lock "$D/.timers.lock" 50 || die 'timers are locked'
      timer_locked=1
      if [ -f "$D/ended" ] || [ -f "$dir/cancelled" ]; then timer_worker_unlock; break; fi
      # Claim/update schedule under the crew lock, then do pane I/O outside it.
      printf '%s\n' "$due" > "$dir/claimed"
      if [ "$kind" = every ]; then
        printf '%s\n' "$(( $(date +%s) + interval ))" > "$dir/next.tmp"
        mv "$dir/next.tmp" "$dir/next"
      fi
      timer_worker_unlock
      take_lock "$dir/.dispatch.lock" 50 || die 'timer dispatch is locked'
      timer_dispatching=1
      if [ -f "$D/ended" ] || [ -f "$dir/cancelled" ]; then timer_worker_dispatch_unlock; break; fi
      # Per-timer serialization keeps cancel from crossing a dispatch. Ring
      # contention is refused immediately, retaining the inbox message.
      local ME=timer VIA="" TMUX_PANE="" RING_TRY_LOCK=1
      log_line dm timer "$role" "$message"
      CREW_RING_WAIT=0 deliver "$role" "$message" "$role"
      if [ "$kind" = at ]; then touch "$dir/done"; fi
      timer_worker_dispatch_unlock
      [ "$kind" != at ] || break
    fi
    sleep 1 & timer_sleep=$!; wait "$timer_sleep" || true; timer_sleep=""
  done
  timer_worker_cleanup
  trap - EXIT INT TERM
}

timer_add_cleanup() {
  # A failed launcher publishes cancellation even before owner/ready exist.
  if [ "${timer_published:-0}" = 0 ] && [ -n "${timer_add_dir:-}" ] && [ -d "$timer_add_dir" ]; then
    touch "$timer_add_dir/cancelled"
    if timer_pid_is "$timer_add_dir"; then
      local pid started
      IFS="$(printf '\t')" read -r pid started < "$timer_add_dir/owner"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  fi
  unlock
}

# Every timer record — at, every and watch — is born through this one
# sequence: timer lock, failed-launch cleanup, ended check, id and directory,
# config/next/message, worker publication, unlock. Caller resolves S/D and
# logs the outcome; it keeps timer_add_dir/timer_published local so the EXIT
# cleanup can still cancel an unpublished record. Prints the id and leaves it
# in timer_create_id for callers in the same shell. `crew up` runs it in
# $(...) so a failure there cannot end `up`; the lock and traps work either way.
timer_create() { # kind interval role due message — prints the record id
  local kind="$1" interval="$2" role="$3" due="$4" message="$5" id dir
  lock timers
  trap timer_add_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ ! -f "$D/ended" ] || die 'crew has ended'
  id="timer-$(date +%s)-$$"; dir="$D/timers/$id"
  mkdir -p "$D/timers"; mkdir "$dir"; timer_add_dir="$dir"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$interval" "$role" "${6:-0}" "${7:-}" "${8:-}" > "$dir/config"
  printf '%s\n' "$due" > "$dir/next"
  printf '%s' "$message" > "$dir/message"
  timer_publish "$dir"; timer_published=1
  unlock
  trap - INT TERM
  timer_create_id="$id"
  printf '%s\n' "$id"
}

cmd_timer_add() { # at|every schedule role message...
  resolve_session; resolve_me
  [ $# -ge 4 ] || die 'usage: crew at <HH:MM|+30m> <role> <message> / crew every <30m> <role> <message>'
  local kind="$1" spec="$2" role="$3" interval=0 due id timer_add_dir="" timer_published=0
  shift 3
  [ -n "$(pane_of "$role")" ] || die "no agent '$role'"
  if [ "$kind" = every ]; then
    interval=$(duration "$spec") || die "bad interval: $spec"
    [ "$interval" -gt 0 ] || die "bad interval: $spec"
    due=$(( $(date +%s) + interval ))
  else due=$(timer_when "$spec") || die "bad time: $spec"; fi
  timer_create "$kind" "$interval" "$role" "$due" "$*"
  id=$timer_create_id
  log_line sys "$ME" "$role" "scheduled $id: $kind $spec"
}

# `crew up` starts one of these per crew with a lead: a detached watcher that
# rings the lead on errors and caught-up work. Caller has set S and D (init_dir)
# and must not call resolve_session, which could pick an unrelated crew.
timer_add_watch() { # interval role [wake-on-limit=0] [handover-spec] [max-wait] — prints the record id
  local interval="$1" role="$2" wake_on_limit="${3:-0}" handover="${4:-}" max_wait="${5:-}" id timer_add_dir="" timer_published=0 policy
  policy="wake-on-limit=$wake_on_limit"
  [ -z "$handover" ] || policy="$policy; handover over $(limit_wait_label "$max_wait") to '$handover'"
  timer_create watch "$interval" "$role" \
    "$(( $(date +%s) + interval ))" "watch $role: errors, drafts, stuck and caught-up work; $policy" "$wake_on_limit" "$handover" "$max_wait"
  id=$timer_create_id
  log_line sys - "$role" "started $id: watch every ${interval}s (crew timers, crew down stops it)"
}

cmd_timers() {
  resolve_session
  local dir id kind interval role due pid started state next_time wake_on_limit rest
  case "${1:-}" in
    cancel)
      [ $# -eq 2 ] || die 'usage: crew timers cancel <id>'
      id="$2"; printf '%s' "$id" | grep -Eq '^timer-[0-9]+-[0-9]+$' || die 'invalid timer id'
      dir="$D/timers/$id"; [ -d "$dir" ] || die "no timer '$id'"
      timer_stop "$dir"
      log_line sys timer - "cancelled $id"
      printf 'cancelled %s\n' "$id" ;;
    '')
      { printf 'ID\tKIND\tROLE\tNEXT (local time)\tSTATE\tMESSAGE\n'
      for dir in "$D"/timers/*; do
        [ -d "$dir" ] && [ -f "$dir/ready" ] || continue
        IFS="$(printf '\t')" read -r kind interval role wake_on_limit rest < "$dir/config"
        due=$(cat "$dir/next"); state=stopped
        next_time=-
        [ "$kind" = watch ] || next_time=$(date -r "$due" '+%Y-%m-%d %H:%M:%S')
        if [ -f "$dir/cancelled" ]; then state=cancelled
        elif [ -f "$dir/done" ]; then state=done
        elif timer_pid_is "$dir"; then
          if [ "$kind" = watch ]; then state=watching; else state=waiting; fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${dir##*/}" "$kind" "$role" "$next_time" "$state" "$(oneline "$(cat "$dir/message")")"
      done; } | column -t -s "$(printf '\t')" ;;
    *) die "bad timers option: $1" ;;
  esac
}
