# Native session lookup for resume and fork. IDs discovered without an exact
# crew mapping are safe only when one same-CLI role uses this project folder.

session_mtime() { # file
  local stamp
  stamp=$(stat -f '%m' "$1" 2>/dev/null || true)
  case "$stamp" in ''|*[!0-9]*) stamp=$(stat -c '%Y' "$1" 2>/dev/null || printf '0') ;; esac
  printf '%s' "$stamp"
}

session_created_at() { # file -> birth time, or modification time where unavailable
  local stamp
  stamp=$(stat -f '%B' "$1" 2>/dev/null || true)
  case "$stamp" in ''|*[!0-9]*|0)
    stamp=$(stat -c '%W' "$1" 2>/dev/null || true) ;;
  esac
  case "$stamp" in ''|*[!0-9]*|0) stamp=$(session_mtime "$1") ;; esac
  printf '%s' "$stamp"
}

session_crew_start() { # current crew -> epoch seconds
  local epoch created
  epoch=$(meta created_epoch)
  case "$epoch" in ''|*[!0-9]*) epoch="" ;; esac
  if [ -z "$epoch" ]; then
    created=$(meta created)
    if [ -n "$created" ]; then
      epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$created" '+%s' 2>/dev/null \
        || date -d "$created" '+%s' 2>/dev/null || true)
      case "$epoch" in ''|*[!0-9]*) epoch="" ;; esac
    fi
  fi
  [ -n "$epoch" ] || epoch=$(session_mtime "$D/meta")
  case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
  printf '%s' "$epoch"
}

session_recent_minutes() { # launch epoch -> find -mmin age, rounded up with one minute slack
  local start="$1" now elapsed minutes
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  elapsed=$((now - start))
  [ "$elapsed" -gt 0 ] || elapsed=0
  minutes=$(((elapsed + 59) / 60 + 1))
  [ "$minutes" -gt 0 ] || minutes=1
  printf '%s' "$minutes"
}

session_find_files() { # directory pattern recent-minutes [skip-subagents]
  local dir="$1" pattern="$2" recent_minutes="$3" skip_subagents="${4:-}"
  if [ -n "$recent_minutes" ]; then
    if [ "$skip_subagents" = subagents ]; then
      find "$dir" -type f -mmin "-$recent_minutes" -name "$pattern" ! -path '*/subagents/*' -print 2>/dev/null
    else
      find "$dir" -type f -mmin "-$recent_minutes" -name "$pattern" -print 2>/dev/null
    fi
  elif [ "$skip_subagents" = subagents ]; then
    find "$dir" -type f -name "$pattern" ! -path '*/subagents/*' -print 2>/dev/null
  else
    find "$dir" -type f -name "$pattern" -print 2>/dev/null
  fi
}

session_candidates() { # cli cwd [mtime|birth] [launch-epoch] [role] -> time<TAB>id rows; with a role, only files holding its intro line
  local cli="$1" cwd="$2" time_mode="${3:-mtime}" launch_epoch="${4:-}" intro="" root dir file id stamp header file_cwd slug recent_minutes
  [ -z "${5:-}" ] || intro="You are agent '$5' in crew '$S'"
  if recent_minutes=$(session_recent_minutes "$launch_epoch"); then
    :
  else
    recent_minutes=""
  fi
  case "$(short_cli "$cli")" in
    claude)
      root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
      slug=$(printf '%s' "$cwd" | sed 's|[^A-Za-z0-9]|-|g')
      dir="$root/$slug"
      [ -d "$dir" ] || return 0
      while IFS= read -r file; do
        id="${file##*/}"; id="${id%.jsonl}"
        case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
        [ -z "$intro" ] || grep -qF -- "$intro" "$file" 2>/dev/null || continue
        if [ "$time_mode" = birth ]; then stamp=$(session_created_at "$file"); else stamp=$(session_mtime "$file"); fi
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(session_find_files "$dir" '*.jsonl' "$recent_minutes" subagents)
      ;;
    codex)
      root="${CODEX_HOME:-$HOME/.codex}/sessions"
      [ -d "$root" ] || return 0
      while IFS= read -r file; do
        header=$(head -n 5 "$file" 2>/dev/null || true)
        file_cwd=$(printf '%s\n' "$header" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"\\]*)".*/\1/p' | head -n 1)
        [ "$file_cwd" = "$cwd" ] || continue
        id=$(printf '%s\n' "$header" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_.-]+)".*/\1/p' | head -n 1)
        [ -n "$id" ] || continue
        [ -z "$intro" ] || grep -qF -- "$intro" "$file" 2>/dev/null || continue
        if [ "$time_mode" = birth ]; then stamp=$(session_created_at "$file"); else stamp=$(session_mtime "$file"); fi
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(session_find_files "$root" 'rollout-*.jsonl' "$recent_minutes")
      ;;
    pi)
      if [ -n "${PI_CODING_AGENT_SESSION_DIR:-}" ]; then
        dir="$PI_CODING_AGENT_SESSION_DIR"
      else
        root="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions"
        slug=$(printf '%s' "$cwd" | sed 's|^/||;s|/|-|g;s| |_|g')
        dir="$root/--${slug}--"
      fi
      [ -d "$dir" ] || return 0
      while IFS= read -r file; do
        id="${file##*/}"; id="${id%.jsonl}"; id="${id##*_}"
        case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
        [ -z "$intro" ] || grep -qF -- "$intro" "$file" 2>/dev/null || continue
        if [ "$time_mode" = birth ]; then stamp=$(session_created_at "$file"); else stamp=$(session_mtime "$file"); fi
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(session_find_files "$dir" '*.jsonl' "$recent_minutes")
      ;;
    *) die "session lookup is not supported for $(short_cli "$cli")" ;;
  esac
}

session_role_cli() { # role -> recorded CLI spec
  awk -F '\t' -v r="$1" '$1==r {print $3; exit}' "$D/panes"
}

record_session_id() { # role id; caller holds the panes lock
  local role="$1" id="$2" cli cwd launch_epoch tmp="$D/sessions.tsv.tmp"
  case "$id" in ''|*[!A-Za-z0-9_.-]*) die "bad session id: $id" ;; esac
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || die "no agent '$role' in crew $S"
  if [ -f "$D/sessions.tsv" ] && awk -F '\t' -v r="$role" -v i="$id" '$1!=r && $4==i {f=1} END {exit !f}' "$D/sessions.tsv"; then
    die "session $id is already recorded for another role; fork it with 'crew add <role>=fork:<source>' instead"
  fi
  cwd=$(meta cwd)
  launch_epoch=$(awk -F '\t' -v r="$role" '$1==r {print $5; exit}' "$D/sessions.tsv" 2>/dev/null || true)
  case "$launch_epoch" in ''|*[!0-9]*) launch_epoch="" ;; esac
  if [ -f "$D/sessions.tsv" ]; then
    awk -F '\t' -v r="$role" '$1!=r {print}' "$D/sessions.tsv" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$role" "$(short_cli "$cli")" "$cwd" "$id" "$launch_epoch" >> "$tmp"
  mv "$tmp" "$D/sessions.tsv"
}

session_record_launch() { # role launch-epoch; caller holds the panes lock
  local role="$1" start="$2" cli agent cwd tmp="$D/sessions.tsv.tmp"
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || return 1
  agent=$(short_cli "$cli")
  case "$agent" in claude|codex|pi) ;; *) return 1 ;; esac
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  cwd=$(meta cwd)
  if [ -f "$D/sessions.tsv" ]; then
    awk -F '\t' -v r="$role" '$1!=r {print}' "$D/sessions.tsv" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t\t%s\n' "$role" "$agent" "$cwd" "$start" >> "$tmp"
  mv "$tmp" "$D/sessions.tsv"
}

session_saved_id() { # role -> exact id if CLI and cwd still match
  local role="$1" cli cwd row saved_cli saved_cwd id
  [ -f "$D/sessions.tsv" ] || return 1
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || return 1
  cwd=$(meta cwd)
  row=$(awk -F '\t' -v r="$role" '$1==r {print $2 "\t" $3 "\t" $4; exit}' "$D/sessions.tsv")
  [ -n "$row" ] || return 1
  IFS="$(printf '\t')" read -r saved_cli saved_cwd id <<EOF
$row
EOF
  [ -n "$id" ] && [ "$saved_cli" = "$(short_cli "$cli")" ] && [ "$saved_cwd" = "$cwd" ] || return 1
  printf '%s' "$id"
}

session_forget() { # role -> drop its row: the binding no longer follows the recorded conversation
  [ -f "$D/sessions.tsv" ] || return 0
  awk -F '\t' -v r="$1" '$1!=r {print}' "$D/sessions.tsv" > "$D/sessions.tsv.tmp"
  mv "$D/sessions.tsv.tmp" "$D/sessions.tsv"
}

session_launch_epoch() { # role -> launch epoch when CLI and cwd still match
  local role="$1" cli cwd row saved_cli saved_cwd start
  [ -f "$D/sessions.tsv" ] || return 1
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || return 1
  cwd=$(meta cwd)
  row=$(awk -F '\t' -v r="$role" '$1==r {print $2 "\t" $3 "\t" $5; exit}' "$D/sessions.tsv")
  [ -n "$row" ] || return 1
  IFS="$(printf '\t')" read -r saved_cli saved_cwd start <<EOF
$row
EOF
  [ "$saved_cli" = "$(short_cli "$cli")" ] && [ "$saved_cwd" = "$cwd" ] || return 1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$start"
}

session_capture_role_locked() { # role; caller holds the panes lock
  local role="$1" cli agent cwd start candidates recorded_ids="" stamp id selected="" count=0
  session_saved_id "$role" >/dev/null && return 1
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || return 1
  agent=$(short_cli "$cli"); cwd=$(meta cwd)
  case "$agent" in claude|codex|pi) ;; *) return 1 ;; esac
  start=$(session_launch_epoch "$role") || return 1
  candidates=$(session_candidates "$agent" "$cwd" birth "$start" "$role" | awk -F '\t' -v start="$start" '$1 >= start' | sort -rn)
  [ -n "$candidates" ] || return 1
  if [ -f "$D/sessions.tsv" ]; then
    recorded_ids=$(awk -F '\t' -v r="$role" '$1!=r && $4!="" {print $4}' "$D/sessions.tsv" | tr '\n' ' ')
  fi
  while IFS="$(printf '\t')" read -r stamp id; do
    case " $recorded_ids " in *" $id "*) continue ;; esac
    count=$((count + 1)); selected="$id"
    [ "$count" -le 1 ] || return 1
  done <<EOF
$candidates
EOF
  [ "$count" = 1 ] || return 1
  record_session_id "$role" "$selected"
}

session_capture_role() { # role -> best-effort lazy capture; does not wait for a CLI
  local role="$1" result=1 prior_locks="${HELD_LOCKS:-}"
  session_saved_id "$role" >/dev/null && return 1
  session_launch_epoch "$role" >/dev/null || return 1
  case " ${HELD_LOCKS:-} " in
    *" panes "*) session_capture_role_locked "$role"; return $? ;;
  esac
  # One attempt only: capture must never make an ordinary crew command wait
  # behind a roster update.
  take_lock "$D/.panes.lock" 1 || return 1
  HELD_LOCKS="${prior_locks:+$prior_locks }panes"
  trap unlock EXIT
  if session_capture_role_locked "$role"; then result=0; fi
  rmdir "$D/.panes.lock" 2>/dev/null || true
  HELD_LOCKS="$prior_locks"
  if [ -n "$prior_locks" ]; then trap unlock EXIT; else trap - EXIT; fi
  return "$result"
}

session_capture_current() { # best-effort capture for the role running this command
  resolve_me
  case "$ME" in ""|you|outside) return 0 ;; esac
  session_capture_role "$ME" || true
}

session_id_for_role() { # role -> recorded ID, lazy launch ID, or safe legacy fallback
  local role="$1" cli agent cwd other candidates id other_role other_pane other_cli other_origin start
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || die "no agent '$role' in crew $S"
  agent=$(short_cli "$cli"); cwd=$(meta cwd)
  case "$agent" in claude|codex|pi) ;; *) die "session lookup is not supported for $agent" ;; esac
  if id=$(session_saved_id "$role"); then
    printf '%s' "$id"
    return 0
  fi
  if start=$(session_launch_epoch "$role"); then
    session_capture_role "$role" || true
    if id=$(session_saved_id "$role"); then
      printf '%s' "$id"
      return 0
    fi
    die "no unique $agent session found for $role since launch; record its ID with 'crew -s $S session $role <id>'"
  fi
  other=0
  while IFS="$(printf '\t')" read -r other_role other_pane other_cli other_origin; do
    [ -n "${other_role:-}" ] && [ "$other_role" != "$role" ] || continue
    [ "$(short_cli "$other_cli")" = "$agent" ] && other=$((other + 1))
  done < "$D/panes"
  [ "$other" = 0 ] || die "can't identify $role's $agent session: another $agent role shares $cwd; pin the exact ID with 'crew -s $S session $role <id>'"
  start=$(session_crew_start)
  candidates=$(session_candidates "$agent" "$cwd" mtime "" "$role" | awk -F '\t' -v start="$start" '$1 >= start' | sort -rn)
  [ -n "$candidates" ] || die "no $agent session found for $cwd since crew start; record its ID with 'crew -s $S session $role <id>'"
  [ "$(printf '%s\n' "$candidates" | wc -l)" -le 1 ] \
    || die "more than one $agent session in $cwd carries $role's intro; pin the exact ID with 'crew -s $S session $role <id>'"
  id=$(printf '%s\n' "$candidates" | cut -f 2)
  record_session_id "$role" "$id"
  printf 'crew: using newest %s session %s for %s (only this %s role uses %s); recorded it for the role\n' "$agent" "$id" "$role" "$agent" "$cwd" >&2
  printf '%s' "$id"
}

session_fork_command() { # recorded CLI spec session-id -> launch command
  local cli="$1" id="$2" agent
  case "$id" in ''|*[!A-Za-z0-9_.-]*) die "bad session id: $id" ;; esac
  agent=$(short_cli "$cli")
  case "$agent" in
    claude) printf '%s --resume %s --fork-session' "$cli" "$id" ;;
    codex) printf '%s fork %s' "$cli" "$id" ;;
    pi) printf '%s --fork %s' "$cli" "$id" ;;
    *) die "session fork is not supported for $agent" ;;
  esac
}
