# Sourced by bin/crew. Only the explicitly enabled watcher wakes a limited lead
# or hands it over to the successor spec the user gave.
limit_handover_confirm=300 # a long-limit banner must persist this long before a handover
limit_max_wait_default=21600

# Validates the handover flags shared by `up` and `watch`; prints max-wait seconds.
limit_handover_options() ( # spec max-wait
  local spec="$1" max_wait="$2" seconds
  if [ -z "$spec" ]; then
    [ -z "$max_wait" ] || die '--max-wait needs --handover-on-limit'
    printf '%s\n' "$limit_max_wait_default"; return 0
  fi
  case "$spec" in *$'\t'*|*$'\n'*) die '--handover-on-limit spec must be one line without tabs' ;;
    %*|*=*) die '--handover-on-limit takes the CLI command for a new lead pane (not a pane or role=spec)' ;; esac
  [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || die '--handover-on-limit needs a CLI spec'
  seconds=$limit_max_wait_default
  if [ -n "$max_wait" ]; then seconds=$(duration "$max_wait") || die "bad --max-wait: $max_wait"; fi
  printf '%s\n' "$seconds"
)

limit_epoch() ( # "YYYY-MM-DD HH:MM" in the caller's TZ -> epoch; rejects normalised dates
  local epoch
  epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null) || return 1
  [ "$(date -r "$epoch" '+%Y-%m-%d %H:%M')" = "$1" ] || return 1
  printf '%s\n' "$epoch"
)

limit_reset_due() ( # [[YYYY-]MM-DD ]HH:MM [timezone], current epoch -> reset minute + 60s grace
  local day="" clock zone="" extra="" current="$2" year due
  read -r day clock zone extra <<< "$1"
  case "$day" in *-*) ;; *) extra=$zone; zone=$clock; clock=$day; day="" ;; esac
  [ -z "$extra" ] || return 1
  case "$clock" in [0-2][0-9]:[0-5][0-9]) ;; *) return 1 ;; esac
  if [ -n "$zone" ]; then case "$zone" in *..*|/*) return 1 ;; esac
    [ -f "/usr/share/zoneinfo/$zone" ] || return 1; export TZ="$zone"; fi
  if [ -z "$day" ]; then # a clock alone is its next occurrence
    day=$(date -r "$current" '+%Y-%m-%d') || return 1
    due=$(limit_epoch "$day $clock") || return 1
    due=$((due+60))
    if [ "$due" -le "$current" ]; then
      day=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$day 12:00:00" '+%Y-%m-%d') || return 1
      due=$(limit_epoch "$day $clock") || return 1
      due=$((due+60))
    fi
  else # a dated reset is that day; a passed one is due now, not next year,
    # unless the missing year makes it months old (seen in late December)
    case "$day" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) due=$(limit_epoch "$day $clock") || return 1 ;;
      [0-9][0-9]-[0-9][0-9])
        year=$(date -r "$current" +%Y) || return 1
        due=$(limit_epoch "$year-$day $clock") || return 1
        if [ "$due" -lt $((current-180*86400)) ]; then due=$(limit_epoch "$((year+1))-$day $clock") || return 1; fi ;;
      *) return 1 ;;
    esac
    due=$((due+60))
  fi
  printf '%s\n' "$due"
)

limit_reset_label() { # show local only when the CLI did not print a timezone
  case "$1" in *[A-Za-z]*) printf '%s' "$1" ;; '') printf 'unknown' ;; *) printf '%s local' "$1" ;; esac
}

limit_wait_label() { # seconds -> 4h05m / 2d03h
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd%02dh' $((s/86400)) $((s%86400/3600))
  else printf '%dh%02dm' $((s/3600)) $((s%3600/60)); fi
}

# Persistent per-lead claim: restarting a watcher or running two of them must
# not repeat a retry or handover for the same visible banner. A clear screen
# rearms it. States: 0 wake scheduled, 1 woken, h handover pending, H handed over.
limit_wake_lead() ( # pane cli reset reason [handover-spec] [max-wait-seconds]
  local pane="$1" cli="$2" clock="$3" reason="$4" spec="${5:-}" max_wait="${6:-$limit_max_wait_default}"
  local saved_pane="" saved_clock="" due=0 sent=0 current cap live_clock state resources live_reason prompt key successor=""
  local dir="$D/limit-wake" guard="$D/.limit-wake.lock"
  mkdir "$guard" 2>/dev/null || return 0
  trap 'rmdir "$guard" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ ! -f "$D/ended" ] && owns_pane "$pane" lead || return 0
  if [ "$reason" != 'provider limit' ]; then rm -f "$dir/lead"; return 0; fi
  key=${clock:-unknown}
  mkdir -p "$dir"
  if [ -f "$dir/lead" ]; then IFS='|' read -r saved_pane saved_clock due sent < "$dir/lead"; fi
  [ ! -f "$dir/successor" ] || successor=$(cat "$dir/successor")
  # A reset that briefly stops parsing (redraw, wrap) is the same banner, not
  # a new unknown one: never let it rearm a claim or start a handover.
  if [ -z "$clock" ] && [ "$saved_pane" = "$pane" ] && [ -n "$saved_clock" ]; then key=$saved_clock; fi
  current=$(date +%s)
  if [ "$saved_pane" != "$pane" ] || [ "$saved_clock" != "$key" ]; then
    due=""
    [ -z "$clock" ] || due=$(limit_reset_due "$clock" "$current") || due=""
    # A lead that is itself the automatic successor never hands over again:
    # the spec has no further fallback, so it waits for its own reset.
    if [ -n "$spec" ] && [ "$successor" != "$pane" ] && { [ -z "$due" ] || [ $((due-current)) -gt "$max_wait" ]; }; then
      printf '%s|%s|%s|h\n' "$pane" "$key" "$((current+limit_handover_confirm))" > "$dir/lead.tmp"
      mv "$dir/lead.tmp" "$dir/lead"
      if [ -n "$due" ]; then
        log_line sys watch lead "usage limit resets $(limit_reset_label "$clock") (in $(limit_wait_label $((due-current))), over the $(limit_wait_label "$max_wait") wait limit): handing lead over to '$spec' in ${limit_handover_confirm}s unless it clears"
      else
        log_line sys watch lead "usage limit with no readable reset time: handing lead over to '$spec' in ${limit_handover_confirm}s unless it clears"
      fi
      return 0
    fi
    [ -n "$due" ] || { rm -f "$dir/lead"; return 0; } # unknown reset stays manual
    printf '%s|%s|%s|0\n' "$pane" "$key" "$due" > "$dir/lead.tmp"
    mv "$dir/lead.tmp" "$dir/lead"
    log_line sys watch lead "usage-limit wake scheduled after $(limit_reset_label "$clock") (60s grace)"
    return 0
  fi
  case "$sent" in 0|h) ;; *) return 0 ;; esac
  [ "$current" -ge "$due" ] || return 0
  # Re-read before claiming: the lead may have recovered while we waited.
  cap=$(pane_scan_capture "$pane" "$cli" 2>/dev/null) || return 0
  IFS='|' read -r state resources live_reason live_clock prompt <<< "$(printf '%s\n' "$cap" | pane_observation "$cli" details)"
  [ "$state" = error ] && [ "$live_reason" = 'provider limit' ] && [ "${live_clock:-unknown}" = "$key" ] && [ "$prompt" = idle ] || return 0
  if [ "$sent" = h ]; then
    limit_handover_lead "$pane" "$key" "$due" "$spec"
    return 0
  fi
  # Claim before delivery. A held doorbell stays in the inbox and uses the
  # existing coalesced reminder; a crash must not produce duplicate retries.
  printf '%s|%s|%s|1\n' "$pane" "$key" "$due" > "$dir/lead.tmp"
  mv "$dir/lead.tmp" "$dir/lead"
  local ME=watch VIA="" TMUX_PANE="" RING_TRY_LOCK=1
  local message="Your printed usage-limit reset time has passed. Retry your last request and continue the existing task; if still limited, report it and wait."
  log_line dm watch lead "$message"
  CREW_RING_WAIT=0 deliver lead "$message" lead "$pane"
)

# The user's opt-in names the successor; this runs the ordinary
# `crew override lead=<spec>` (spawn, verify, move tasks, save the old pane's
# context, notify everyone) with `watch` as the caller. Claimed first: a
# failed or interrupted handover is logged, never retried for this banner.
limit_handover_lead() { # pane key due spec — inside limit_wake_lead's lock
  local pane="$1" key="$2" due="$3" spec="$4" dir="$D/limit-wake" out rc=0
  printf '%s|%s|%s|H\n' "$pane" "$key" "$due" > "$dir/lead.tmp"
  mv "$dir/lead.tmp" "$dir/lead"
  if [ -z "$spec" ] || [ -n "$(pane_of "$spec")" ]; then
    log_line sys watch lead "usage-limit handover skipped: '$spec' is not a CLI spec for a new pane"
    return 0
  fi
  log_line sys watch lead "lead still limited (reset $(limit_reset_label "${key#unknown}")): handing over to '$spec'"
  out=$( SESSION_FLAG=$S limit_handover_by=watch; cmd_override "lead=$spec" 2>&1 ) || rc=$?
  if [ "$rc" = 0 ] && [ "$(pane_of lead)" != "$pane" ]; then
    pane_of lead > "$dir/successor"
  else
    log_line sys watch lead "usage-limit handover to '$spec' failed; lead stays on $pane: $(oneline "$out" | tail -c 300)"
  fi
}
