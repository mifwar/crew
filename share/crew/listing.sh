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

relative_age() { # local ISO timestamp, current epoch seconds
  local stamp="$1" epoch age
  [ -n "$stamp" ] || { printf '%s' '-'; return; }
  epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$stamp" '+%s' 2>/dev/null) || { printf '%s' '-'; return; }
  age=$(($2 - epoch)); [ "$age" -ge 0 ] || age=0
  if [ "$age" -lt 60 ]; then printf '%ss' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%sm' "$((age / 60))"
  elif [ "$age" -lt 86400 ]; then printf '%sh' "$((age / 3600))"
  else printf '%sd' "$((age / 86400))"; fi
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
    tasks=$(awk -F'\t' '$3=="done"{done++} END{printf "%d/%d (%d open)", done, NR, NR-done}' "$D/board.tsv" 2>/dev/null) || tasks='-'
    stamp=$(tail -n 1 "$D/channel.log" 2>/dev/null | cut -f1) || stamp=""
    last=$(relative_age "$stamp" "$epoch")
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

cmd_sweep() {
  local apply=0 S D STATE MEMBERS
  case "${1:-}" in --apply) apply=1; shift ;; esac
  [ $# -eq 0 ] || die 'usage: crew sweep [--apply]'
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

