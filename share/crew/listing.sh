# Sourced by bin/crew; uses its identity, state-file and locking helpers.

crew_health() { # current S/D → STATE, MEMBERS; inspect panes without changing them
  local role pane cli origin mark alive=0 total=0
  MEMBERS=""
  while IFS="$(printf '\t')" read -r role pane cli origin; do
    total=$((total + 1))
    if ! pane_id "$pane" >/dev/null; then mark=gone
    elif owns_pane "$pane" "$role"; then mark=alive; alive=$((alive + 1))
    else mark=reused; fi
    MEMBERS="${MEMBERS:+$MEMBERS }$role=$(short_cli "$cli")($mark)"
  done < "$D/panes"
  if [ -f "$D/ended" ]; then STATE=ended
  elif [ "$alive" = 0 ]; then STATE=stale
  elif [ "$alive" = "$total" ]; then STATE=up
  else STATE=partial; fi
}

age_text() { # seconds -> 5s | 5m | 3h | 2d; future timestamps clamp to 0s
  local age="$1"
  [ "$age" -ge 0 ] || age=0
  if [ "$age" -lt 60 ]; then printf '%ss' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%sm' "$((age / 60))"
  elif [ "$age" -lt 86400 ]; then printf '%sh' "$((age / 3600))"
  else printf '%sd' "$((age / 86400))"; fi
}

# Last channel.log timestamp as local epoch seconds. Empty when the log is
# missing, empty or not parseable; callers keep such a crew rather than guess.
last_epoch() { # crew dir
  local stamp
  stamp=$(tail -n 1 "$1/channel.log" 2>/dev/null | cut -f1) || return 0
  [ -n "$stamp" ] || return 0
  date -j -f '%Y-%m-%dT%H:%M:%S' "$stamp" '+%s' 2>/dev/null || true
}

human_size() { # size in KB -> 512K | 4.2M | 681M | 1.5G
  awk -v kb="$1" 'BEGIN {
    if (kb < 1024) { printf "%dK", kb; exit }
    if (kb < 1048576) { s = kb / 1024; u = "M" } else { s = kb / 1048576; u = "G" }
    printf (s < 10 ? "%.1f%s" : "%.0f%s"), s, u
  }'
}

cmd_ls() {
  local live=0 S D STATE MEMBERS project short tasks stamp last epoch row active=() ended=() stale=0
  case "${1:-}" in --live) live=1; shift ;; esac
  [ $# -eq 0 ] || die 'usage: crew ls [--live]'
  epoch=$(date '+%s')
  for D in "$CREW_HOME"/*/; do
    [ -f "$D/panes" ] || continue
    S=$(basename "$D")
    crew_health
    [ "$STATE" != stale ] || stale=$((stale + 1))
    if [ "$live" = 1 ]; then
      case "$STATE" in ended|stale) continue ;; esac
    fi
    project=$(meta cwd)
    case "$project" in "$HOME"|"$HOME"/*) project="~${project#"$HOME"}" ;; esac
    project=$(oneline "$project")
    short=$(truncate_text "$project" 48)
    [ "$short" = "$project" ] || short="${short}…"
    tasks=$(awk -F'\t' -v closed="$TASK_CLOSED_RE" '
      $3 ~ closed{c++} $3=="cancelled"{x++}
      END {
        if (NR == 0) { printf "0/0 (0 open)"; exit }
        printf "%d/%d (%d open", c, NR, NR-c
        if (x) printf ", %d cancelled", x
        printf ")"
      }' "$D/board.tsv" 2>/dev/null) || tasks='-'
    stamp=$(last_epoch "$D")
    if [ -n "$stamp" ]; then last=$(age_text "$((epoch - stamp))"); else last=-; fi
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$S" "${short:--}" "$STATE" "${MEMBERS:--}" "$tasks" "$last")
    if [ "$STATE" = ended ]; then ended+=("$row"); else active+=("$row"); fi
  done
  { printf 'CREW\tPROJECT\tSTATE\tAGENTS\tTASKS\tLAST\n'
    [ ${#active[@]} -eq 0 ] || printf '%s\n' "${active[@]}"
    [ ${#ended[@]} -eq 0 ] || printf '%s\n' "${ended[@]}"
  } | column -t -s "$(printf '\t')"
  if [ "$stale" -gt 0 ]; then
    local noun=crews; [ "$stale" != 1 ] || noun=crew
    printf '\n%s stale %s: crew sweep --apply\n' "$stale" "$noun"
  fi
}

# Qualification for --delete-older: print the reason the folder must be kept,
# or nothing when it qualifies for pruning. The listing pass and the recheck
# under the panes lock both call this, so the rules exist once. Only a direct,
# non-symlink child holding meta, panes and ended counts as an ended crew, so
# bin/, tmp/ and other CREW_HOME contents are never listed or touched.
# Archived `<name>.<YYYYMMDD-HHMMSS>` folders from a reused name keep those
# files and follow the same rules.
prune_keep_reason() { # crew dir cutoff-seconds
  local dir="$1" cutoff="$2" epoch age
  [ -d "$dir" ] && [ ! -L "$dir" ] || { printf '%s' 'gone'; return; }
  [ -f "$dir/meta" ] && [ -f "$dir/panes" ] && [ -f "$dir/ended" ] \
    || { printf '%s' 'not an ended crew'; return; }
  epoch=$(last_epoch "$dir")
  [ -n "$epoch" ] || { printf '%s' 'no last activity'; return; }
  [ "$(cat "$CREW_HOME/.current" 2>/dev/null)" != "${dir##*/}" ] \
    || { printf '%s' 'current crew'; return; }
  age=$(( $(date '+%s') - epoch )); [ "$age" -ge 0 ] || age=0
  if [ "$age" -le "$cutoff" ]; then printf 'newer than %s' "$(age_text "$cutoff")"; fi
  return 0
}

# Prune ended crew folders older than the cutoff. Nothing is deleted without
# --apply, and a qualifying folder is rechecked under the panes lock first.
sweep_prune() { # cutoff-seconds apply [label]; the label is the user's age text
  local cutoff="$1" apply="$2" label="${3:-}" D S epoch age reason kb total_kb=0 count=0 entry noun now_epoch
  now_epoch=$(date '+%s')
  [ -n "$label" ] || label=$(age_text "$cutoff")
  for D in "$CREW_HOME"/*/; do
    D=${D%/}
    S=$(basename "$D")
    # Only ever build the delete path from a plain child name.
    case "$S" in ''|.|..|*/*) continue ;; esac
    reason=$(prune_keep_reason "$D" "$cutoff")
    case "$reason" in
      gone|'not an ended crew') continue ;;
      'no last activity')
        printf '%s: ended, no last activity; kept\n' "$S"
        continue ;;
    esac
    epoch=$(last_epoch "$D"); age=$((now_epoch - epoch)); [ "$age" -ge 0 ] || age=0
    kb=$(du -sk "$D" 2>/dev/null | cut -f1); [ -n "$kb" ] || kb=0
    entry=$(printf '%s: ended, last activity %s ago, %s' "$S" "$(age_text "$age")" "$(human_size "$kb")")
    if [ -n "$reason" ]; then printf '%s; kept (%s)\n' "$entry" "$reason"; continue; fi
    if [ "$apply" = 0 ]; then
      printf '%s; would delete\n' "$entry"
      count=$((count + 1)); total_kb=$((total_kb + kb)); continue
    fi
    # A new log line, a .current change or an `up` that moved the folder aside
    # must win over a stale listing; re-check under this crew's own panes lock.
    lock panes
    reason=$(prune_keep_reason "$D" "$cutoff")
    if [ -n "$reason" ]; then
      if [ "$reason" = gone ]; then printf '%s: gone; skipped\n' "$S"
      else printf '%s: changed while waiting; kept\n' "$S"; fi
      unlock; continue
    fi
    epoch=$(last_epoch "$D"); age=$(( $(date '+%s') - epoch )); [ "$age" -ge 0 ] || age=0
    kb=$(du -sk "$D" 2>/dev/null | cut -f1); [ -n "$kb" ] || kb=0
    rm -rf "$CREW_HOME/$S"
    unlock   # the lock directory lived inside the deleted folder
    printf '%s: ended, last activity %s ago, %s; deleted\n' "$S" "$(age_text "$age")" "$(human_size "$kb")"
    count=$((count + 1)); total_kb=$((total_kb + kb))
  done
  noun=folders; [ "$count" != 1 ] || noun=folder
  if [ "$count" -eq 0 ]; then
    printf 'nothing to prune: no ended crew older than %s\n' "$label"
  elif [ "$apply" = 1 ]; then
    printf 'freed %s from %d %s\n' "$(human_size "$total_kb")" "$count" "$noun"
  else
    printf 'would free %s from %d %s (dry run: add --apply)\n' "$(human_size "$total_kb")" "$count" "$noun"
  fi
}

cmd_sweep() {
  local apply=0 S D STATE MEMBERS cutoff="" older=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --delete-older)
        [ $# -ge 2 ] || die 'usage: crew sweep [--apply] [--delete-older <age>]'
        cutoff=$(duration "$2") || die "bad age: $2 (use an integer and s/m/h/d, e.g. 14d)"
        [ "$cutoff" -gt 0 ] || die '--delete-older needs a positive age'
        older="$2"; shift 2 ;;
      *) die 'usage: crew sweep [--apply] [--delete-older <age>]' ;;
    esac
  done
  # Pruning is its own mode: it only removes old ended folders and never marks
  # stale crews, so a run can be reasoned about one way at a time.
  [ -z "$cutoff" ] || { sweep_prune "$cutoff" "$apply" "$older"; return; }
  for D in "$CREW_HOME"/*/; do
    [ -f "$D/panes" ] && [ ! -f "$D/ended" ] || continue
    S=$(basename "$D")
    crew_health
    case "$STATE" in
      partial) printf '%s: partial; kept (some panes alive)\n' "$S" ;;
      stale)
        if [ "$apply" = 0 ]; then
          printf '%s: stale; would mark ended (dry run)\n' "$S"
          continue
        fi
        # add/rebind/override may repair a crew while sweep waits for its lock.
        lock panes
        crew_health
        if [ "$STATE" = stale ]; then
          touch "$D/ended"
          log_line sys - - 'crew sweep: marked ended (no owned agent panes); files kept'
          [ "$(cat "$CREW_HOME/.current" 2>/dev/null)" != "$S" ] || rm -f "$CREW_HOME/.current"
          printf '%s: marked ended; files kept\n' "$S"
        else printf '%s: %s; kept\n' "$S" "$STATE"; fi
        unlock ;;
    esac
  done
}

