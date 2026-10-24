# Sourced by bin/crew. Observations are heuristics, never permission to type.
# Board helpers use TASK_CLOSED_RE from tasks.sh, loaded before dispatch.
# Defaults shared by `crew watch` and the watcher `crew up` starts for a crew
# with a lead (CREW_WATCH_EVERY overrides the interval, see cmd_up).
watch_interval=120
watch_quiet_default=600

# Keep the rendered-text patterns in one table for status and watch alike.
pane_patterns() {
  cat <<'EOF'
error	^retry failed([[:space:]:.!]|$)	Retry failed
error	^connection error([[:space:]:.!]|$)	Connection error
error	^request timed out([[:space:]:.!]|$)	Request timed out
error	^context.*(exhausted|too long|limit([[:space:]]+(reached|exceeded)|$)|length[[:space:]]+exceeded)	context exhausted/limit
error	^rate[ -]+limit([[:space:]]+(exceeded|reached|hit)|$)	rate limit
error	^quota[[:space:]]+(exhausted|exceeded|reached|depleted)|^(you have )?(exhausted|exceeded|reached).*quota|^insufficient[_ ]quota	quota
error	^(you'?ve|you’ve|you have) (hit|reached) your .*limit	provider limit
error	^usage limit (exceeded|reached|hit)	provider limit
error	^[0-9]+[[:space:]]+rate[ -]+limit	rate limit
busy	(esc|ctrl-c|ctrl[+]c)[[:space:]]+to[[:space:]]+(interrupt|stop)([[:space:])]*$|\)[[:space:]]*·.*$)
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
EOF
}

pane_observation() { # cli [details]; capture -> state|resources|reason[|reset-clock|prompt-state]
  local patterns; patterns=$(pane_patterns)
  CREW_PANE_PATTERNS="$patterns" LC_ALL=C awk -v cli="$1" -v details="${2:-}" '
    function error_row(s) {
      sub(/^[[:space:]]*/, "", s)
      while (sub(/^│|^›|^❯|^•|^●|^■|^!|^⚠|^️|^✗/, "", s)) sub(/^[[:space:]]*/, "", s)
      sub(/^[Ee]rror:[[:space:]]*/, "", s)
      return s
    }
    function clock_value(clock, zone, a, hour, meridiem) {
      gsub(/[[:space:]]/, "", clock)
      if (clock !~ /^[0-9][0-9]?(:[0-9][0-9])?[ap]m$/) return ""
      meridiem=substr(clock,length(clock)-1); sub(/[ap]m$/, "", clock)
      split(clock,a, ":"); if (a[2]=="") a[2]=0
      if (a[1]<1 || a[1]>12 || a[2]<0 || a[2]>59) return ""
      hour=a[1]%12; if (meridiem=="pm") hour+=12
      return sprintf("%02d:%02d",hour,a[2]) (zone!="" ? " " zone : "")
    }
    function reset_clock(cli, text, s, clock, zone) {
      s=tolower(text)
      if (cli=="codex" && match(s,/try again at [0-9][0-9]?:[0-9][0-9] [ap]m[.]?[[:space:]]*$/)) {
        clock=substr(s,RSTART+13); sub(/[.[:space:]]*$/, "", clock)
        return clock_value(clock, "")
      }
      if (cli=="claude" && s ~ /resets /) {
        clock=s; sub(/^.*resets /,"",clock); zone=""
        if (match(text,/\((UTC|GMT|[A-Za-z_+-]+\/[A-Za-z0-9_+.\/-]+)\)[[:space:]]*$/)) {
          zone=substr(text,RSTART+1,RLENGTH-1); sub(/\)[[:space:]]*$/,"",zone)
          sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/,"",clock)
        }
        return clock_value(clock,zone)
      }
      return ""
    }
    BEGIN { n = split(ENVIRON["CREW_PANE_PATTERNS"], lines, "\n"); for (i=1; i<=n; i++) {
      split(lines[i], fields, "\t"); kind[i]=fields[1]; re[i]=fields[2]; label[i]=fields[3]
    } }
    {
      s=$0
      gsub(/\033\[[0-9;]*m/, "", s)
      if (s ~ /[^[:space:]]/) row[++count] = s
    }
    END {
      for (j=1; j<=count; j++) {
        provider=0; matched_error=0
        for (i=1; i<=n; i++) {
          s=tolower(row[j])
          # Doorbell echoes describe another role; they are never pane errors.
          if (index(s, "[crew]")) continue
          # Match error UI forms from their start, allowing common UI gutters.
          if (kind[i]=="error") {
            s=error_row(s)
          }
          if (s !~ re[i]) continue
          if (kind[i]=="error" && j>count-30) {
            reason=label[i]; matched_error=1
            if (reason=="provider limit") provider=1
          }
          if (kind[i]=="busy" && j>count-8) busy=1
          if ((kind[i]=="idle" || (kind[i]=="pi_idle" && cli=="pi")) && j>count-8) idle=1
          if ((kind[i]=="context" || kind[i]=="quota") && match(s,re[i])) {
            value=substr(s,RSTART,RLENGTH)
            if (kind[i]=="context") context=value; else quota=value
          }
        }
        if (j>count-30 && !index(tolower(row[j]),"[crew]")) {
          if (provider) { banner=error_row(row[j]); age=0; reset="" }
          else if (matched_error) { banner=""; reset="" }
          else if (banner!="" && ++age<=6 && row[j] !~ /^[[:space:]]*(›|❯)/) banner=banner " " error_row(row[j])
          else banner="" # the composer ends the banner, but keeps its parsed reset
          if (banner!="") { clock=reset_clock(cli,banner); if (clock!="") reset=clock }
        }
      }
      prompt = busy ? "busy" : (idle ? "idle" : "unknown")
      state = reason!="" ? "error" : prompt
      resources=context
      if (quota!="") resources=resources (resources!="" ? "; " : "") quota
      if (details=="details") printf "%s|%s|%s|%s|%s\n",state,resources,reason,reset,prompt
      else printf "%s|%s|%s\n",state,resources,reason
    }'
}

role_tasks() { # role [active]; open is anything not done/cancelled (blocked, needs-input, …)
  awk -F'\t' -v r="$1" -v active="${2:-}" -v closed="$TASK_CLOSED_RE" '
    $2==r && $3 !~ closed && (active=="" || $3=="working" || $3=="queued") {n++}
    END {print n+0}' "$D/board.tsv"
}

# Keep the recovery instruction copy-ready when the lead's pane is unavailable.
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

watch_event() { # ring? text
  if [ "$1" = 1 ]; then
    log_line sys watch lead "$2"
    # deliver checks owns_pane and uses the existing draft/dialog hold.
    local ME=watch VIA="" TMUX_PANE=""
    CREW_RING_WAIT=0 deliver lead "$2" lead
  else printf '%s  %s\n' "$(now)" "$2"; fi
}

watch_scan() { # private cache quiet-seconds ring?; one observation per owned pane
  local cache="$1" quiet="$2" ring_events="$3" wake_on_limit="${4:-0}" role pane cli origin cap observation health resources reason draft reset_clock prompt
  local fingerprint changed sent previous current_time event open active tasks board
  current_time=$(date +%s)
  while IFS="$(printf '\t')" read -r role pane cli origin; do
    # Reused panes are never read or rung, even if their screen looks idle.
    if ! owns_pane "$pane" "$role"; then
      rm -f "$cache/$role"
      continue
    fi
    cap=$(pane_scan_capture "$pane" "$cli" 2>/dev/null) || continue
    observation=$(printf '%s\n' "$cap" | pane_observation "$(short_cli "$cli")" details)
    IFS='|' read -r health resources reason reset_clock prompt <<< "$observation"
    draft=$(printf '%s\n' "$cap" | draft_note "$pane" "$cli")
    tasks=$(awk -F'\t' -v r="$role" -v closed="$TASK_CLOSED_RE" '$2==r && $3 !~ closed' "$D/board.tsv")
    fingerprint=$(printf '%s\n%s\n%s\n' "$pane" "$cap" "$tasks" | cksum)
    previous=""; changed=$current_time; sent=-
    if [ -f "$cache/$role" ]; then
      IFS='|' read -r previous changed sent < "$cache/$role"
    fi
    [ "$fingerprint" = "$previous" ] || changed=$current_time
    open=$(role_tasks "$role"); active=$(role_tasks "$role" active)
    event=""
    # An error is never silent: review rounds run over `crew send` after a task
    # is done, so requiring open work would hide exactly the case that matters.
    # The wording still says when the role also has open work to pick up.
    if [ "$health" = error ]; then
      if [ "$open" -gt 0 ]; then event="errored with an open task: $reason"
      else event="errored: $reason"; fi
      if [ -n "$reset_clock" ]; then
        event="$event (reset $(limit_reset_label "$reset_clock"))"
        [ "$role" = lead ] || event="$event; lead decides whether to wait or hand over with a suitable model"
      fi
    elif [ -n "$draft" ]; then event="$draft"
    elif [ "$health" = idle ] && [ "$active" -gt 0 ]; then event="stuck: input prompt with queued/working task"
    # Never ring an idle lead about itself: waiting is its normal state, and
    # each ring would wake it only to idle again, repeating every quiet period.
    elif [ "$health" = idle ] && [ "$open" -eq 0 ] && { [ "$role" != lead ] || [ "$ring_events" = 0 ]; }; then
      event="idle with no open task"; fi
    if [ -z "$event" ]; then sent=-
    elif [ "$event" != "$sent" ] && { [ "$health" = error ] || [ -n "$draft" ] || [ $((current_time-changed)) -ge "$quiet" ]; }; then
      sent=$event
      # A lead event should include the exact recovery command, not require
      # someone to find it while the lead is unavailable. Keep it out of the
      # cache key so roster edits do not re-announce an unchanged event.
      if [ "$role" = lead ]; then
        watch_event "$ring_events" "$role $event — $(lead_recovery_hint)"
      else
        watch_event "$ring_events" "$role $event"
      fi
    fi
    printf '%s|%s|%s\n' "$fingerprint" "$changed" "$sent" > "$cache/$role"
    if [ "$wake_on_limit" = 1 ] && [ "$ring_events" = 1 ] && [ "$role" = lead ]; then
      limit_wake_lead "$pane" "$(short_cli "$cli")" "$reset_clock"
    fi
    # Only a ringing watcher replays held doorbells, and only after this scan's
    # own observation, so the doorbell it types never changes what it reported.
    # stdout watch stays read-only: it neither reads nor writes pending state.
    if [ "$ring_events" = 1 ] && [ -n "$role" ]; then pending_replay "$role" "$pane" || true; fi
  done < "$D/panes"
  board=$(watch_board_state)
  previous=-; [ ! -f "$cache/.board" ] || previous=$(cat "$cache/.board")
  if [ "$board" = empty ] && [ "$previous" != empty ]; then
    watch_event "$ring_events" 'board has no open tasks'
  fi
  printf '%s\n' "$board" > "$cache/.board"
}

watch_board_state() { # -> empty|open, the same open-task rule as status
  if [ "$(awk -F'\t' -v closed="$TASK_CLOSED_RE" '$3 !~ closed{n++} END{print n+0}' "$D/board.tsv")" -eq 0 ]; then
    printf 'empty\n'
  else printf 'open\n'; fi
}

# The scan/sleep loop shared by `crew watch` and the watcher `crew up` starts.
# The caller owns the traps; `cancel` is the worker's cancellation marker (""
# for a foreground watch, which only stops on the crew's ended marker). A
# deleted crew directory also ends the loop, so a watcher whose crew is gone
# can never poll a reused path forever. The board cache is seeded from the
# current state before the first scan in every mode: the empty-board notice is
# a transition (open → empty), never a first-scan observation.
watch_loop() { # cache every quiet ring? [cancel-file] [wake-on-limit=0]
  local cache="$1" every="$2" quiet="$3" ring_events="$4" cancel="${5:-}" wake_on_limit="${6:-0}"
  watch_cache="$cache"
  printf '%s\n' "$(watch_board_state)" > "$cache/.board"
  while [ -d "$D" ] && [ ! -f "$D/ended" ] && { [ -z "$cancel" ] || [ ! -f "$cancel" ]; }; do
    watch_scan "$cache" "$quiet" "$ring_events" "$wake_on_limit"
    sleep "$every" & watch_sleep_pid=$!
    wait "$watch_sleep_pid" || true
    watch_sleep_pid=""
  done
}

watch_cleanup() {
  [ -z "${watch_sleep_pid:-}" ] || kill "$watch_sleep_pid" 2>/dev/null || true
  watch_sleep_pid=""
  # A pending lock is held only while replaying one reminder; releasing it here
  # keeps a stopped watcher from blocking a role's re-rings until a human
  # removes the lock.
  if [ -n "${pending_held:-}" ]; then pending_unlock; fi
  [ -z "${watch_cache:-}" ] || rm -rf "$watch_cache"
  watch_cache=""
}

cmd_watch() {
  resolve_session
  local every=$watch_interval quiet=$watch_quiet_default ring_events=0 wake_on_limit=0 watch_cache="" watch_sleep_pid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --every|--quiet-after)
        [ $# -ge 2 ] || die "$1 needs a duration"
        local seconds; seconds=$(duration "$2") || die "bad duration: $2"
        if [ "$1" = --every ]; then
          [ "$seconds" -gt 0 ] || die '--every must be positive'
          every=$seconds
        else quiet=$seconds; fi
        shift 2 ;;
      --ring) ring_events=1; shift ;;
      --wake-on-limit) wake_on_limit=1; shift ;;
      *) die "bad option: $1" ;;
    esac
  done
  [ "$ring_events" = 0 ] || [ -n "$(pane_of lead)" ] || die '--ring needs a lead role'
  [ "$wake_on_limit" = 0 ] || [ "$ring_events" = 1 ] || die '--wake-on-limit needs --ring'
  watch_cache=$(mktemp -d "${TMPDIR:-/tmp}/crew-watch.XXXXXX")
  trap watch_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  watch_loop "$watch_cache" "$every" "$quiet" "$ring_events" "" "$wake_on_limit"
  watch_cleanup
  trap - EXIT INT TERM
}
