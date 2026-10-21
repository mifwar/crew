# Native session lookup for resume and fork. IDs discovered without an exact
# crew mapping are safe only when one same-CLI role uses this project folder.

session_mtime() { # file
  local stamp
  stamp=$(stat -f '%m' "$1" 2>/dev/null || true)
  case "$stamp" in ''|*[!0-9]*) stamp=$(stat -c '%Y' "$1" 2>/dev/null || printf '0') ;; esac
  printf '%s' "$stamp"
}

session_candidates() { # cli cwd -> mtime<TAB>id rows
  local cli="$1" cwd="$2" root dir file id stamp header file_cwd slug
  case "$(short_cli "$cli")" in
    claude)
      root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
      slug=$(printf '%s' "$cwd" | sed 's|/|-|g')
      dir="$root/$slug"
      [ -d "$dir" ] || return 0
      while IFS= read -r file; do
        id="${file##*/}"; id="${id%.jsonl}"
        case "$id" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
        stamp=$(session_mtime "$file")
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(find "$dir" -type f -name '*.jsonl' ! -path '*/subagents/*' -print 2>/dev/null)
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
        stamp=$(session_mtime "$file")
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(find "$root" -type f -name 'rollout-*.jsonl' -print 2>/dev/null)
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
        stamp=$(session_mtime "$file")
        printf '%s\t%s\n' "$stamp" "$id"
      done < <(find "$dir" -type f -name '*.jsonl' -print 2>/dev/null)
      ;;
    *) die "session lookup is not supported for $(short_cli "$cli")" ;;
  esac
}

session_role_cli() { # role -> recorded CLI spec
  awk -F '\t' -v r="$1" '$1==r {print $3; exit}' "$D/panes"
}

record_session_id() { # role id; caller holds the panes lock
  local role="$1" id="$2" cli cwd tmp="$D/sessions.tsv.tmp"
  case "$id" in ''|*[!A-Za-z0-9_.-]*) die "bad session id: $id" ;; esac
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || die "no agent '$role' in crew $S"
  cwd=$(meta cwd)
  if [ -f "$D/sessions.tsv" ]; then
    awk -F '\t' -v r="$role" '$1!=r {print}' "$D/sessions.tsv" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\n' "$role" "$(short_cli "$cli")" "$cwd" "$id" >> "$tmp"
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
  [ "$saved_cli" = "$(short_cli "$cli")" ] && [ "$saved_cwd" = "$cwd" ] || return 1
  printf '%s' "$id"
}

session_id_for_role() { # role -> exact saved id, or record an unambiguous newest session
  local role="$1" cli agent cwd other candidates id other_role other_pane other_cli other_origin
  cli=$(session_role_cli "$role"); [ -n "$cli" ] || die "no agent '$role' in crew $S"
  agent=$(short_cli "$cli"); cwd=$(meta cwd)
  case "$agent" in claude|codex|pi) ;; *) die "session lookup is not supported for $agent" ;; esac
  if id=$(session_saved_id "$role"); then
    printf '%s' "$id"
    return 0
  fi
  other=0
  while IFS="$(printf '\t')" read -r other_role other_pane other_cli other_origin; do
    [ -n "${other_role:-}" ] && [ "$other_role" != "$role" ] || continue
    [ "$(short_cli "$other_cli")" = "$agent" ] && other=$((other + 1))
  done < "$D/panes"
  [ "$other" = 0 ] || die "can't identify $role's $agent session: another $agent role shares $cwd; pin the exact ID with 'crew -s $S session $role <id>'"
  candidates=$(session_candidates "$agent" "$cwd" | sort -rn)
  [ -n "$candidates" ] || die "no $agent session found for $cwd; record its ID with 'crew -s $S session $role <id>'"
  id=$(printf '%s\n' "$candidates" | head -n 1 | cut -f 2)
  record_session_id "$role" "$id"
  printf 'crew: using newest %s session %s for %s (only this %s role uses %s); recorded it for the role\n' "$agent" "$id" "$role" "$agent" "$cwd" >&2
  printf '%s' "$id"
}
