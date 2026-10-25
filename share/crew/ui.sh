# Sourced by bin/crew. The dashboard uses the canonical shell observers and
# ownership checks; the Bun process only renders and handles terminal input.

cmd_ui() {
  [ $# -eq 0 ] || die 'usage: crew [-s <name>] ui'
  [ -t 0 ] && [ -t 1 ] || die 'crew ui needs an interactive terminal'
  [ "${TERM:-dumb}" != dumb ] || die 'crew ui needs a terminal with cursor support'
  command -v bun >/dev/null || die 'crew ui needs bun (brew install oven-sh/bun/bun)'
  # With no explicit selection the UI can discover crews, even when .current
  # is absent. An explicit -s is validated just like other crew commands.
  local selected="${SESSION_FLAG:-${CREW_SESSION:-}}"
  if [ -n "$selected" ]; then
    resolve_session --read-only
  elif [ -n "${TMUX_PANE:-}" ]; then
    selected=$(pane_session "$TMUX_PANE") || selected=""
  fi
  CREW_HOME="$CREW_HOME" CREW_BIN="$_self" exec bun "$CREW_SHARE/ui.ts" "$selected"
}

cmd_ui_state() {
  [ $# -eq 0 ] || die 'usage: crew -s <name> _ui-state'
  resolve_session --read-only
  local role pane cli origin state cap observation resources reason hold hold_class hold_reason model note
  while IFS="$TAB" read -r role pane cli origin; do
    model=""; resources=""; note=""
    if ! pane_id "$pane" >/dev/null; then state=gone
    elif ! owns_pane "$pane" "$role"; then state=stale
    else
      cap=$(pane_scan_capture "$pane" "$cli" 2>/dev/null) || cap=""
      observation=$(printf '%s\n' "$cap" | pane_observation "$(short_cli "$cli")")
      IFS='|' read -r state resources reason <<< "$observation"
      model=$(detect_model "$pane") || model=""
      hold=$(pane_hold "$pane")
      IFS="$TAB" read -r hold_class hold_reason <<< "$hold"
      if [ "$state" = error ]; then note="$reason"
      else
        case "$hold_class" in
          dialog) state=approval; note="$hold_reason" ;;
          mode) state=mode; note="$hold_reason" ;;
          unreadable) state=unknown; note="$hold_reason" ;;
          draft) state=draft; note="$hold_reason" ;;
          *) if [ "$state" = idle ] && [ "$(role_tasks "$role" active)" -gt 0 ]; then note='idle with queued/working task'; fi ;;
        esac
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$role" "$pane" "$(short_cli "$cli")" "$state" "$(oneline "$model")" "$(oneline "$resources")" "$(oneline "$note")"
  done < "$D/panes"
}

cmd_ui_jump() {
  [ $# -eq 1 ] || die 'usage: crew -s <name> _ui-jump <role>'
  resolve_session --read-only
  local pane source_session target_session
  pane=$(pane_of "$1"); [ -n "$pane" ] || die "no agent '$1'"
  owns_pane "$pane" "$1" || die "$1's pane is gone or reused; use crew rebind"
  [ -n "${TMUX_PANE:-}" ] || die 'pane navigation needs tmux; run crew ui inside tmux'
  source_session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}')
  target_session=$(tmux display-message -p -t "$pane" '#{session_id}')
  [ -n "$source_session" ] && [ "$source_session" = "$target_session" ] \
    || die 'pane is in another tmux session; switch to that session to open it'
  tmux select-window -t "$pane" \; select-pane -t "$pane"
}
