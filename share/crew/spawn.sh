# Spawn lifecycle shared by `crew up`, `add` and `override`.

warn_codex_sandbox() { # role spec
  case "$2" in
    codex|codex\ *) case "$2" in *dangerously*|*network_access*) ;; *)
      echo "crew: $1 (codex) is sandboxed, so its 'crew send' can't reach tmux and its messages won't ring. Start it with flags that allow that." >&2 ;;
    esac ;;
  esac
}

start_agent() { # role pane spec — never amend the user's command
  owns_pane "$2" "$1" || die "$1's pane is gone or reused; no command typed"
  ring --now "$2" "$3"
  warn_codex_sandbox "$1" "$3"
}

pane_unbound() { # pane — exists, is absent from this roster, and has no crew label
  local pane="$1" got
  [ -n "$(pane_id "$pane")" ] || return 1
  [ -z "$(awk -F'\t' -v p="$pane" '$2==p{print $1; exit}' "$D/panes")" ] || return 1
  got=$(tmux display-message -p -t "$pane" '#{@crew_session}/#{@crew_role}' 2>/dev/null || true)
  [ "$got" = / ]
}

# Spawned additions and successors are verified before they enter the roster.
spawn_agent_pane() { # role window cwd spec -> pane, or fail and close it
  local role="$1" win="$2" cwd="$3" spec="$4" pane
  # Split/layout is quick and shared-window state; CLI startup remains lock-free.
  lock spawn-window
  pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$win" -c "$cwd" \
    -e "CREW_SESSION=$S" -e "CREW_AGENT=$role" -e "CREW_HOME=$CREW_HOME") || { unlock; return 1; }
  if ! tmux select-layout -t "$win" tiled >/dev/null; then
    tmux kill-pane -t "$pane" 2>/dev/null || true
    unlock
    return 1
  fi
  unlock
  warn_codex_sandbox "$role" "$spec"
  if ! ring --now "$pane" "$spec"; then
    tmux kill-pane -t "$pane" 2>/dev/null || true
    echo "crew: could not start '$spec' in $pane; pane closed" >&2
    return 1
  fi
  wait_ready "$pane" || true
  if [ -z "$(detect_cli "$pane")" ]; then
    tmux kill-pane -t "$pane" 2>/dev/null || true
    echo "crew: '$spec' did not start in $pane; pane closed" >&2
    return 1
  fi
  printf '%s' "$pane"
}

kill_spawned_specs() { # transient role|pane|origin|cli rows
  local spec role pane origin cli
  for spec in "$@"; do
    IFS='|' read -r role pane origin cli <<< "$spec"
    [ "$origin" = spawned ] && [ -n "$pane" ] && tmux kill-pane -t "$pane" 2>/dev/null || true
  done
}
