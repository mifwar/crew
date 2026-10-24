# Sourced by bin/crew. Only the explicitly enabled watcher wakes a limited lead.
limit_reset_due() ( # HH:MM [timezone], current epoch -> reset minute + 60s grace
  local clock="${1%% *}" current="$2" day due zone=""
  case "$1" in *' '*) zone=${1#* }; case "$zone" in *..*|/*) return 1 ;; esac
    [ -f "/usr/share/zoneinfo/$zone" ] || return 1; export TZ="$zone" ;; esac
  day=$(date -r "$current" '+%Y-%m-%d') || return 1
  due=$(date -j -f '%Y-%m-%d %H:%M:%S' "$day $clock:00" +%s 2>/dev/null) || return 1
  due=$((due+60))
  if [ "$due" -le "$current" ]; then
    due=$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$day $clock:00" +%s 2>/dev/null) || return 1
    due=$((due+60))
  fi
  printf '%s\n' "$due"
)

limit_reset_label() { # show local only when the CLI did not print a timezone
  case "$1" in *' '*) printf '%s' "$1" ;; *) printf '%s local' "$1" ;; esac
}

# Persistent per-lead claim: restarting a watcher or running two of them must
# not repeat a retry for the same visible banner. A clear screen rearms it.
limit_wake_lead() ( # pane cli clock (empty when no recognised banner)
  local pane="$1" cli="$2" clock="$3" saved_pane="" saved_clock="" due=0 sent=0 current cap live_clock state resources reason prompt
  local dir="$D/limit-wake" guard="$D/.limit-wake.lock"
  mkdir "$guard" 2>/dev/null || return 0
  trap 'rmdir "$guard" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ ! -f "$D/ended" ] && owns_pane "$pane" lead || return 0
  if [ -z "$clock" ]; then rm -f "$dir/lead"; return 0; fi
  mkdir -p "$dir"
  if [ -f "$dir/lead" ]; then IFS='|' read -r saved_pane saved_clock due sent < "$dir/lead"; fi
  current=$(date +%s)
  if [ "$saved_pane" != "$pane" ] || [ "$saved_clock" != "$clock" ]; then
    due=$(limit_reset_due "$clock" "$current") || return 0
    printf '%s|%s|%s|0\n' "$pane" "$clock" "$due" > "$dir/lead.tmp"
    mv "$dir/lead.tmp" "$dir/lead"
    log_line sys watch lead "usage-limit wake scheduled after $(limit_reset_label "$clock") (60s grace)"
    return 0
  fi
  [ "$sent" = 0 ] && [ "$current" -ge "$due" ] || return 0
  # Re-read before claiming: the lead may have recovered while we waited.
  cap=$(pane_scan_capture "$pane" "$cli" 2>/dev/null) || return 0
  IFS='|' read -r state resources reason live_clock prompt <<< "$(printf '%s\n' "$cap" | pane_observation "$cli" details)"
  [ "$state" = error ] && [ "$reason" = 'provider limit' ] && [ "$live_clock" = "$clock" ] && [ "$prompt" = idle ] || return 0
  # Claim before delivery. A held doorbell stays in the inbox and uses the
  # existing coalesced reminder; a crash must not produce duplicate retries.
  printf '%s|%s|%s|1\n' "$pane" "$clock" "$due" > "$dir/lead.tmp"
  mv "$dir/lead.tmp" "$dir/lead"
  local ME=watch VIA="" TMUX_PANE="" RING_TRY_LOCK=1
  local message="Your printed usage-limit reset time has passed. Retry your last request and continue the existing task; if still limited, report it and wait."
  log_line dm watch lead "$message"
  CREW_RING_WAIT=0 deliver lead "$message" lead "$pane"
)
