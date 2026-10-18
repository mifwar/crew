# Sourced by bin/crew. Command slots are separate from board/pane rewrite locks.
semaphore_start() { LC_ALL=C TZ=UTC ps -p "$1" -o lstart=; }

semaphore_process_alive() { # pid start; retain a live process if inspection fails
  local actual
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$2" ] || return 0
  actual=$(semaphore_start "$1" 2>/dev/null) || return 0
  [ "$actual" = "$2" ]
}

semaphore_alive() { # either the waiting wrapper or its published workload owns the lease
  local suffix pid started role command
  suffix=${1##*/slot.}; pid=${suffix%%.*}
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  # A slot can disappear between the test and the read (its owner is
  # exiting), so an unreadable file means the reservation is already gone.
  if [ -s "$1/owner" ]; then
    IFS="$(printf '\t')" read -r pid started role command < "$1/owner" 2>/dev/null || return 1
    semaphore_process_alive "$pid" "$started" && return 0
  elif kill -0 "$pid" 2>/dev/null; then return 0; fi
  if [ -s "$1/workload" ]; then
    IFS="$(printf '\t')" read -r pid started < "$1/workload" 2>/dev/null || return 1
    semaphore_process_alive "$pid" "$started" && return 0
  fi
  return 1
}

semaphore_reap() { # namespace; unique slot names are never republished
  local slot
  for slot in "$1"/slot.*; do
    [ -d "$slot" ] || continue
    semaphore_alive "$slot" || rm -rf "$slot"
  done
}

semaphore_cleanup() {
  [ -z "${semaphore_sleep:-}" ] || kill "$semaphore_sleep" 2>/dev/null || true
  [ -z "${semaphore_slot:-}" ] || rm -rf "$semaphore_slot"
}

semaphore_interrupt() { # exit status; keep the slot until the command exits
  trap '' INT TERM
  if [ -n "${semaphore_child:-}" ]; then
    kill -TERM "$semaphore_child" 2>/dev/null || true
    wait "$semaphore_child" 2>/dev/null || true
  fi
  exit "$1"
}

cmd_lock() {
  resolve_session; resolve_me
  local name=build max=1 root stored retries=0 started count slot warned=0 rc=0 separated=0
  local semaphore_slot="" semaphore_child="" semaphore_sleep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name|--max)
        [ $# -ge 2 ] || die "$1 needs a value"
        if [ "$1" = --name ]; then name="$2"; else max="$2"; fi
        shift 2 ;;
      --) shift; separated=1; break ;;
      *) die "bad lock option: $1 (put the command after --)" ;;
    esac
  done
  [ "$separated" = 1 ] && [ $# -gt 0 ] || die 'usage: crew lock [--name build] [--max N] -- <cmd...>'
  check_name "$name"
  case "$max" in ''|*[!0-9]*) die '--max must be a positive integer' ;; esac
  max="${max#"${max%%[!0]*}"}"
  [ -n "$max" ] && [ ${#max} -le 6 ] || die '--max must be 1..999999'
  [ ! -f "$D/ended" ] || die 'crew has ended'
  root="$D/locks/$name"; mkdir -p "$root"
  # Noclobber publishes capacity once, so callers cannot disagree about N.
  if (set -C; printf '%s\n' "$max" > "$root/max") 2>/dev/null; then :
  else
    while [ ! -s "$root/max" ]; do
      retries=$((retries+1)); [ "$retries" -lt 50 ] || die "empty capacity file: $root/max"
      sleep 0.1
    done
    stored=$(cat "$root/max")
    [ "$stored" = "$max" ] || die "lock '$name' has --max $stored; use that capacity or another name"
  fi
  started=$(semaphore_start $$)
  trap semaphore_cleanup EXIT
  trap 'semaphore_interrupt 130' INT
  trap 'semaphore_interrupt 143' TERM
  while :; do
    [ ! -f "$D/ended" ] || die 'crew has ended while waiting for a lock'
    semaphore_reap "$root"
    semaphore_slot=$(mktemp -d "$root/slot.$$.XXXXXX")
    printf '%s\t%s\t%s\t%s\n' "$$" "$started" "$ME" "$(oneline "$*")" > "$semaphore_slot/owner"
    # Reserve before counting: another contender sees our reservation too.
    # Excess contenders withdraw; this can underfill briefly, never overfill.
    count=0
    for slot in "$root"/slot.*; do [ ! -d "$slot" ] || count=$((count+1)); done
    [ "$count" -gt "$max" ] || break
    rm -rf "$semaphore_slot"; semaphore_slot=""
    if [ "$warned" = 0 ]; then printf 'crew: waiting for lock %s (max %s)\n' "$name" "$max" >&2; warned=1; fi
    # Jitter keeps simultaneous contenders from withdrawing in lockstep.
    sleep "0.$((100 + RANDOM % 400))" & semaphore_sleep=$!
    wait "$semaphore_sleep" || true; semaphore_sleep=""
  done
  touch "$semaphore_slot/held"
  # A fresh shell has its own pid (unlike $$ in a Bash 3.2 subshell). Gate
  # exec until that identity is published, so recovery can retain the slot
  # if this wrapper is SIGKILLed while the workload keeps running.
  "$BASH" -c '
    slot=$1; parent=$2; shift 2; tries=0
    while [ ! -f "$slot/run" ]; do
      [ -d "$slot" ] && kill -0 "$parent" 2>/dev/null || exit 125
      tries=$((tries+1)); [ "$tries" -lt 50 ] || exit 125
      sleep 0.1
    done
    [ -d "$slot" ] || exit 125
    exec "$@"
  ' crew-lock-workload "$semaphore_slot" "$$" "$@" <&0 & semaphore_child=$!
  started=$(semaphore_start "$semaphore_child")
  printf '%s\t%s\n' "$semaphore_child" "$started" > "$semaphore_slot/workload"
  touch "$semaphore_slot/run"
  wait "$semaphore_child" || rc=$?
  semaphore_child=""
  semaphore_cleanup
  trap - EXIT INT TERM
  return "$rc"
}

semaphore_status() {
  local root slot pid started role command workload_pid workload_started found=0
  for root in "$D"/locks/*; do
    [ -d "$root" ] || continue
    for slot in "$root"/slot.*; do
      [ -f "$slot/held" ] && [ -s "$slot/owner" ] || continue
      semaphore_alive "$slot" || continue
      IFS="$(printf '\t')" read -r pid started role command < "$slot/owner" 2>/dev/null || continue
      workload_pid=-
      if [ -s "$slot/workload" ]; then IFS="$(printf '\t')" read -r workload_pid workload_started < "$slot/workload" 2>/dev/null || true; fi
      if [ "$found" = 0 ]; then printf '\nLOCK HOLDERS\nNAME\tWRAPPER PID\tCOMMAND PID\tROLE\tCOMMAND\n'; found=1; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "${root##*/}" "$pid" "$workload_pid" "$role" "$command"
    done
  done | column -t -s "$(printf '\t')"
}
