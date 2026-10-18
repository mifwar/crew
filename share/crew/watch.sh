# Sourced by bin/crew. Observations are heuristics, never permission to type.
# Keep the rendered-text patterns in one table for status and watch alike.
pane_patterns() {
  cat <<'EOF'
error	retry failed	Retry failed
error	connection error	Connection error
error	request timed out	Request timed out
error	context.*(exhausted|limit|too long)	context exhausted/limit
error	rate[ -]+limit	rate limit
error	quota	quota
busy	(esc|ctrl-c|ctrl[+]c).*interrupt|esc.*stop
busy	^[[:space:]]*(working|thinking)([[:space:].]|…|$)
busy	─.*(working|thinking).*─
idle	^[[:space:]]*(›|❯|>)([[:space:]]|$)
idle	^[[:space:]]*(do you want to proceed|would you like to (run|make|grant))
pi_idle	^(─){8,}[[:space:]]*$
context	context[[:space:]]+[0-9]+%[[:space:]]+(used|left)
context	[0-9]+%/[0-9.]+[km]
context	context left until auto-compact:[[:space:]]*[0-9]+%
context	[0-9]+%[[:space:]]+(of )?context (used|left)
quota	5h[[:space:]]+[0-9]+%[[:space:]]+(used|left)
quota	5[ -]hour[^%]*[0-9]+%[[:space:]]+(used|left)
EOF
}

pane_observation() { # cli; capture on stdin -> state|resources|reason
  local patterns; patterns=$(pane_patterns)
  CREW_PANE_PATTERNS="$patterns" LC_ALL=C awk -v cli="$1" '
    BEGIN { n = split(ENVIRON["CREW_PANE_PATTERNS"], lines, "\n"); for (i=1; i<=n; i++) {
      split(lines[i], fields, "\t"); kind[i]=fields[1]; re[i]=fields[2]; label[i]=fields[3]
    } }
    NF { row[++count] = tolower($0) }
    END {
      for (j=1; j<=count; j++) for (i=1; i<=n; i++) {
        s=row[j]
        if (s !~ re[i]) continue
        if (kind[i]=="error" && j>count-30) reason=label[i]
        if (kind[i]=="busy" && j>count-8) busy=1
        if ((kind[i]=="idle" || (kind[i]=="pi_idle" && cli=="pi")) && j>count-8) idle=1
        if ((kind[i]=="context" || kind[i]=="quota") && match(s,re[i])) {
          value=substr(s,RSTART,RLENGTH)
          if (kind[i]=="context") context=value; else quota=value
        }
      }
      state = reason!="" ? "error" : (busy ? "busy" : (idle ? "idle" : "unknown"))
      resources=context
      if (quota!="") resources=resources (resources!="" ? "; " : "") quota
      printf "%s|%s|%s\n",state,resources,reason
    }'
}

role_tasks() { # role [active]; open includes blocked/needs-input
  awk -F'\t' -v r="$1" -v active="${2:-}" '
    $2==r && $3!="done" && (active=="" || $3=="working" || $3=="queued") {n++}
    END {print n+0}' "$D/board.tsv"
}

watch_duration() { # digits + optional s/m/h; bounded to avoid shell overflow
  local value="$1" factor=1
  case "$value" in *s) value=${value%s} ;; *m) value=${value%m}; factor=60 ;; *h) value=${value%h}; factor=3600 ;; esac
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  value="${value#"${value%%[!0]*}"}"; [ -n "$value" ] || value=0
  [ ${#value} -le 6 ] || return 1
  printf '%s' "$((10#$value * factor))"
}

watch_event() { # ring? text
  if [ "$1" = 1 ]; then
    log_line sys watch lead "$2"
    # deliver checks owns_pane and uses the existing draft/dialog hold.
    local ME=watch VIA="" TMUX_PANE=""
    CREW_RING_WAIT=0 deliver lead "$2" lead
  else printf '%s  %s\n' "$(now)" "$2"; fi
}

watch_scan() { # private cache quiet-seconds ring?; one observation per owned pane
  local cache="$1" quiet="$2" ring_events="$3" role pane cli origin cap observation health resources reason
  local fingerprint changed sent previous current_time event open active tasks board
  current_time=$(date +%s)
  while IFS="$(printf '\t')" read -r role pane cli origin; do
    # Reused panes are never read or rung, even if their screen looks idle.
    if ! owns_pane "$pane" "$role"; then
      rm -f "$cache/$role"
      continue
    fi
    cap=$(tmux capture-pane -p -J -t "$pane" 2>/dev/null) || continue
    observation=$(printf '%s\n' "$cap" | pane_observation "$(short_cli "$cli")")
    IFS='|' read -r health resources reason <<< "$observation"
    tasks=$(awk -F'\t' -v r="$role" '$2==r && $3!="done"' "$D/board.tsv")
    fingerprint=$(printf '%s\n%s\n%s\n' "$pane" "$cap" "$tasks" | cksum)
    previous=""; changed=$current_time; sent=-
    if [ -f "$cache/$role" ]; then
      IFS='|' read -r previous changed sent < "$cache/$role"
    fi
    [ "$fingerprint" = "$previous" ] || changed=$current_time
    open=$(role_tasks "$role"); active=$(role_tasks "$role" active)
    event=""
    if [ "$health" = error ] && [ "$open" -gt 0 ]; then event="errored with an open task: $reason"
    elif [ "$health" = idle ] && [ "$active" -gt 0 ]; then event="stuck: input prompt with queued/working task"
    elif [ "$health" = idle ] && [ "$open" -eq 0 ]; then event="idle with no open task"; fi
    if [ -z "$event" ]; then sent=-
    elif [ "$event" != "$sent" ] && { [ "$health" = error ] || [ $((current_time-changed)) -ge "$quiet" ]; }; then
      watch_event "$ring_events" "$role $event"
      sent=$event
    fi
    printf '%s|%s|%s\n' "$fingerprint" "$changed" "$sent" > "$cache/$role"
  done < "$D/panes"
  board=$(awk -F'\t' '$3!="done"{n++} END{print n+0}' "$D/board.tsv")
  previous=-; [ ! -f "$cache/.board" ] || previous=$(cat "$cache/.board")
  if [ "$board" -eq 0 ] && [ "$previous" != empty ]; then
    watch_event "$ring_events" 'board has no open tasks'
  fi
  if [ "$board" -eq 0 ]; then printf 'empty\n'; else printf 'open\n'; fi > "$cache/.board"
}

watch_cleanup() {
  [ -z "${watch_sleep_pid:-}" ] || kill "$watch_sleep_pid" 2>/dev/null || true
  rm -rf "$watch_cache"
}

cmd_watch() {
  resolve_session
  local every=120 quiet=600 ring_events=0 watch_cache watch_sleep_pid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --every|--quiet-after)
        [ $# -ge 2 ] || die "$1 needs a duration"
        local seconds; seconds=$(watch_duration "$2") || die "bad duration: $2"
        if [ "$1" = --every ]; then
          [ "$seconds" -gt 0 ] || die '--every must be positive'
          every=$seconds
        else quiet=$seconds; fi
        shift 2 ;;
      --ring) ring_events=1; shift ;;
      *) die "bad option: $1" ;;
    esac
  done
  [ "$ring_events" = 0 ] || [ -n "$(pane_of lead)" ] || die '--ring needs a lead role'
  watch_cache=$(mktemp -d "${TMPDIR:-/tmp}/crew-watch.XXXXXX")
  trap watch_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while [ ! -f "$D/ended" ]; do
    watch_scan "$watch_cache" "$quiet" "$ring_events"
    sleep "$every" & watch_sleep_pid=$!
    wait "$watch_sleep_pid" || true
    watch_sleep_pid=""
  done
  watch_cleanup
  trap - EXIT INT TERM
}
