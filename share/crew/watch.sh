# Sourced by bin/crew. Observations are heuristics, never permission to type.
# Keep the rendered-text patterns in one table for status and watch alike.
pane_patterns() {
  cat <<'EOF'
error	^retry failed([[:space:]:.!]|$)	Retry failed
error	^connection error([[:space:]:.!]|$)	Connection error
error	^request timed out([[:space:]:.!]|$)	Request timed out
error	^context.*(exhausted|too long|limit([[:space:]]+(reached|exceeded)|$)|length[[:space:]]+exceeded)	context exhausted/limit
error	^rate[ -]+limit([[:space:]]+(exceeded|reached|hit)|$)	rate limit
error	^quota[[:space:]]+(exhausted|exceeded|reached|depleted)|^(you have )?(exhausted|exceeded|reached).*quota|^insufficient[_ ]quota	quota
busy	(esc|ctrl-c|ctrl[+]c)[[:space:]]+to[[:space:]]+(interrupt|stop)[[:space:])]*$
busy	^[[:space:]]*─.*(working|thinking).*─[[:space:]]*$
idle	^[[:space:]]*(›|❯|>)([[:space:]]|$)
idle	^[[:space:]]*(do you want to proceed|would you like to (run|make|grant))
pi_idle	^(─){8,}[[:space:]]*$
context	context[[:space:]]+[0-9]+%[[:space:]]+(used|left)
context	[0-9]+%/[0-9.]+[km]
context	context left until auto-compact:[[:space:]]*[0-9]+%
context	[0-9]+%[[:space:]]+(of )?context (used|left)
quota	5h[[:space:]]+[0-9]+%[[:space:]]+(used|left)
quota	5[ -]hour[^%]*[0-9]+%[[:space:]]+(used|left)
error	^(you'?ve|you’ve|you have) (hit|reached) your .*limit	provider limit
error	^usage limit (exceeded|reached|hit)	provider limit
error	^[0-9]+[[:space:]]+rate[ -]+limit	rate limit
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
        # Doorbell echoes describe another role; they are never pane errors.
        if (index(s, "[crew]")) continue
        # Match error UI forms from their start, allowing common UI gutters.
        if (kind[i]=="error") {
          sub(/^[[:space:]]*/, "", s)
          while (sub(/^│|^›|^❯|^•|^●|^■|^!|^⚠|^️|^✗/, "", s)) sub(/^[[:space:]]*/, "", s)
          sub(/^error:[[:space:]]*/, "", s)
        }
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

# One observation for `crew status` and `crew watch`: the caller's capture
# (stdin) and cli are parsed once, with pane_hold's precedence — a dialog or
# copy/choose mode is never read as a draft. Nothing when the editor is free,
# unreadable, or a CLI whose editor crew cannot read.
draft_note() { # pane cli — the caller's capture on stdin
  local cli cap text dims=""
  cli=$(short_cli "$2")
  cap=$(cat) || return 0
  if printf '%s\n' "$cap" | dialog_capture; then return 0; fi
  case "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null)" in
    0|'') ;;
    *) return 0 ;;
  esac
  case "$cli" in pi) dims=$(tmux display-message -p -t "$1" '#{pane_width} #{pane_height} #{cursor_y}' 2>/dev/null) ;; esac
  text=$(printf '%s\n' "$cap" | pane_editor_text "$cli" "$dims") || return 0
  [ -z "$text" ] || printf 'draft pending: doorbells are held'
}

# One paste-ready recovery line for a lead that looks dead, printed by status
# and watch. Prefer a role with no open tasks, so the suggestion is cheap.
lead_recovery_hint() {
  local r next=""
  for r in $(roles); do
    [ "$r" = lead ] && continue
    [ -n "$next" ] || next="$r"
    [ "$(role_tasks "$r")" -eq 0 ] && { next="$r"; break; }
  done
  if [ -n "$next" ]; then
    printf 'if lead is dead: crew -s %s override lead %s (or lead=<cli> to spawn one)' "$S" "$next"
  else
    printf 'if lead is dead: crew -s %s override lead=<cli>' "$S"
  fi
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
  local cache="$1" quiet="$2" ring_events="$3" role pane cli origin cap observation health resources reason draft
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
    draft=$(printf '%s\n' "$cap" | draft_note "$pane" "$cli")
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
    elif [ -n "$draft" ]; then event="$draft"
    elif [ "$health" = idle ] && [ "$active" -gt 0 ]; then event="stuck: input prompt with queued/working task"
    elif [ "$health" = idle ] && [ "$open" -eq 0 ]; then event="idle with no open task"; fi
    if [ -z "$event" ]; then sent=-
    elif [ "$event" != "$sent" ] && { [ "$health" = error ] || [ -n "$draft" ] || [ $((current_time-changed)) -ge "$quiet" ]; }; then
      sent=$event
      # The command is the whole point of the notice: nobody has to look it up
      # while the lead is dead. Cached without the hint, so roster edits do not
      # re-announce one unchanged event.
      if [ "$role" = lead ]; then
        watch_event "$ring_events" "$role $event — $(lead_recovery_hint)"
      else
        watch_event "$ring_events" "$role $event"
      fi
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
