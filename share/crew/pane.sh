# Sourced by bin/crew; the pane readers, the doorbell `ring` and its hold.
# Host surface used from bin/crew (late-bound at call time, so this module may
# be sourced before they are defined): $D and $S in the pane lookup/owns_pane,
# owns_pane, pane_cli, short_cli, take_lock. pane_hold always exits 0 and
# prints a `class<TAB>reason` record or nothing; neither it nor ring_hold
# writes to the pane.

TAB=$(printf '\t')

# Dialogs answer keystrokes: Enter takes the highlighted choice (claude's
# trust dialog "No, exit", codex's update "Update now" and trust "Trust and
# continue"), a digit picks an option in an approval prompt ("T1 done" types
# a 1) and Enter in a codex picker keeps the highlighted model. Nothing crew
# types may land in one, and crew never answers one.
# Seen: startup footers claude "Enter to confirm · Esc to cancel", codex
# "enter continue · esc skip"; approvals claude "Do you want to proceed?",
# codex "Would you like to run the following command?", both "…don't ask
# again…"; codex menus "enter select · esc back".
# Footer hints sit at the bottom; approval questions can sit above a tall
# option list. Match UI rows, not phrases quoted in an agent's transcript.
dialog_capture() { # capture rows on stdin
  LC_ALL=C awk '
    {
      s = $0
      gsub(/\033\[[0-9;]*m/, "", s)
      s = tolower(s)
      sub(/^[[:space:]]*/, "", s)
      while (sub(/^│|^›|^❯/, "", s)) sub(/^[[:space:]]*/, "", s)
      sub(/[[:space:]]*$/, "", s)
      if (s != "") row[++n] = s
    }
    END {
      for (i = n; i > 0 && i > n - 15; i--) {
        s = row[i]
        if (s ~ /^((do you )?trust (the files in )?this folder|do you want to proceed|would you like to (run|make|grant|send))/ ||
            s ~ /^([0-9]+[.)][[:space:]]*)?(yes,?[[:space:]]+and[[:space:]]+)?don.t ask again([[:space:]]|$)/) exit 0
        if (i > n - 3 && s ~ /^enter (to )?(confirm|continue|select).*esc (to )?(back|cancel|skip)$/) exit 0
      }
      exit 1
    }'
}

in_dialog() { # pane
  tmux capture-pane -p -t "$1" 2>/dev/null | dialog_capture
}

# Claude Code renders its rotating prompt suggestion in dim SGR styling.
# Keep that styling in the capture so it can be distinguished from typed text;
# other editor parsers continue to receive the plain capture format they use.
pane_capture() { # pane cli [capture-pane options...]
  local pane="$1" cli="$2"; shift 2
  case "$(short_cli "$cli")" in
    claude) tmux capture-pane -e -p "$@" -t "$pane" ;;
    *)      tmux capture-pane -p "$@" -t "$pane" ;;
  esac
}

# Why crew must not type into this pane: a `class<TAB>reason` record, nothing
# (and exit 0) when it is free. A dialog or a mode swallows keys before the
# editor sees them, so they are checked first (claude reuses its ❯ marker
# inside dialogs, e.g. "❯ 1. Yes"). Only the CLIs whose editor row we can read
# are checked: an unknown pane is never held for a draft — a false hold makes
# an agent unringable, which is worse than typing into it. Dialogs and modes
# are checked for every pane, and a parser that fails is a hold too: a crashed
# recogniser is not evidence of an empty editor.
pane_hold() { # pane
  local cli cap why="" dims=""
  cli=$(short_cli "$(pane_cli "$1")")
  cap=$(pane_capture "$1" "$cli" 2>/dev/null) || return 0
  if printf '%s\n' "$cap" | dialog_capture; then
    printf 'dialog\tpane %s is showing a dialog or approval prompt' "$1"; return 0
  fi
  case "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null)" in
    0|'') ;;
    *) printf 'mode\tpane %s is in copy/choose mode' "$1"; return 0 ;;
  esac
  case "$cli" in pi) dims=$(tmux display-message -p -t "$1" '#{pane_width} #{pane_height} #{cursor_y}' 2>/dev/null) ;; esac
  if ! why=$(printf '%s\n' "$cap" | pane_editor_text "$cli" "$dims"); then
    printf 'unreadable\tcould not read the %s editor' "$cli"; return 0
  fi
  [ -z "$why" ] || printf 'draft\tunsubmitted draft in the editor'
}

# The capture `status` and `watch` parse once for dialogs, errors and the editor.
# Claude keeps SGR (its dim ghost span); claude and codex want soft wraps joined.
# pi's box parser compares full-width borders and reads rows between them, and
# tmux -J pads a wrapped border row into the row below: a `── ⠧ Working ──` top
# border then looked like a draft on every mid-turn scan (field report ask 4).
pane_scan_capture() { # pane cli
  case "$(short_cli "$2")" in
    pi) tmux capture-pane -p -t "$1" ;;
    *)  pane_capture "$1" "$2" -J ;;
  esac
}

# The one CLI→parser dispatch for the editor's pending text. Capture rows on
# stdin; Claude receives ANSI styling, `dims` is pi's "pane_width pane_height
# cursor_y". Prints the text the editor would submit, nothing when it is idle
# or the CLI's editor is one crew cannot read; a nonzero rc means a known
# CLI's parser failed, and a crashed recogniser is never evidence of a free
# editor (see pane_hold).
pane_editor_text() { # cli dims
  case "$1" in
    claude) claude_prompt_text ;;
    codex)  codex_prompt_text ;;
    pi)     pi_box_text "$2" ;;
    command-code) prompt_row_text '❯' 'Ask your question' ;;
    # Drain unknown editors too: exiting before printf finishes can turn its
    # SIGPIPE into an "unreadable editor" hold under the caller's pipefail.
    *)      cat >/dev/null ;;
  esac
}

# Claude's ghost text is a standalone SGR dim span. Remove only that exact
# style, then use the shared prompt parser; unrecognized styles remain drafts.
claude_prompt_text() { # ANSI capture rows on stdin
  LC_ALL=C awk '
    {
      if (index($0, "❯")) gsub(/\033\[2m[^\033]*/, "")
      gsub(/\033\[[0-9;]*m/, "")
      gsub(/\302\240/, " ")
      print
    }' | prompt_row_text '❯' ''
}

# The bottom-most prompt row, minus a known placeholder: blank (or the
# placeholder) means an idle editor, other text a draft. No marker at all
# means we cannot read this editor, so the pane is left alone.
prompt_row_text() { # marker placeholder — capture rows on stdin
  local marker="$1" placeholder="$2" row text
  row=$(grep -F -- "$marker" | tail -n 1) || true
  [ -n "$row" ] || return 0
  text=$(printf '%s' "${row#*$marker}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$text" ] || return 0
  if [ -n "$placeholder" ]; then
    case "$text" in "$placeholder"*) return 0 ;; esac   # a renamed placeholder becomes a loud hold
  fi
  printf '%s' "$text"
}

# Codex lays out wrapped composer text as separate indented rows. tmux -J
# only joins terminal soft wraps, so reconstruct these rows before comparing
# a startup draft. Stop at the editor border/footer; retain extra draft text.
codex_prompt_text() { # capture rows on stdin
  LC_ALL=C awk '
    /^[[:space:]]*›/ {
      text = $0; sub(/^[[:space:]]*›[[:space:]]?/, "", text)
      active = 1; seen = 1; next
    }
    active {
      if ($0 ~ /^  / && $0 !~ /^  ─/ && $0 !~ /^  ━/) {
        text = text "\n" substr($0, 3)
      } else if ($0 ~ /^[[:space:]]*$/) text = text "\n"
      else active = 0
    }
    END {
      sub(/[[:space:]]+$/, "", text)
      if (seen && text !~ /^Ask Codex to do anything/) printf "%s", text
    }'
}

# pi draws its editor as a box: its top and bottom are the last two rows that
# look like borders, and any non-empty row between them is a draft. Read
# bottom-up, so transcript rows and queued `Steering:` notes above the box
# cannot confuse it. A border is a dashes-only row spanning the pane or a
# mostly-dashes row carrying a label (`── ⠧ Working ──`); a 100-of-120-dash
# draft row is neither. The cursor row is editor content, never a border.
pi_box_text() { # "pane_width pane_height cursor_y" — capture rows on stdin
  LC_ALL=C awk -v dims="${1:-}" '
    BEGIN { split(dims, d, " "); w = d[1] + 0; h = d[2] + 0; cy = -1
            if (h > 0 && d[3] ~ /^[0-9]+$/) cy = d[3] + 0
            if (!w) w = 80; if (!h) h = 24 }
    # LC_ALL=C keeps length() in bytes (─ is 3 of them in UTF-8); keep
    # multibyte literals out of bracket classes, which abort BWK awk
    # ("towc: multibyte conversion failure") on the braille Working spinner.
    function dashes(s, t) { t = s; gsub(/─/, "", t); return (length(s) - length(t)) / 3 }
    function label(s, t) { t = s; gsub(/─/, "", t); gsub(/[[:space:]]/, "", t); return length(t) > 0 }
    function border(s) { return dashes(s) >= w - 3 ? !label(s) : (dashes(s) >= w * 0.55 && label(s)) }
    # A whitespace-only row is an empty editor row, never draft text: tmux -J
    # can pad the row under a wrapped full-width border with spaces.
    function blank(s, t) { t = s; gsub(/[[:space:]]/, "", t); return t == "" }
    { row[NR] = $0 }
    END {
      cur = (cy >= 0 && cy < h && h <= NR) ? NR - h + cy + 1 : 0   # 0: no cursor row known
      bot = 0; top = 0
      for (i = NR; i >= 1; i--) if (border(row[i]) && i != cur) { bot = i; break }
      if (!bot) exit
      for (j = bot - 1; j >= 1; j--) if (border(row[j]) && j != cur) { top = j; break }
      if (!top) exit
      out = ""
      for (k = top + 1; k < bot; k++) if (!blank(row[k])) out = out (out != "" ? " " : "") row[k]
      if (out != "") print out
    }'
}

pi_box_draft() { # "pane_width pane_height cursor_y" — capture rows on stdin
  local text
  text=$(pi_box_text "$@") || return $?
  [ -z "$text" ] || printf 'unsubmitted draft in the editor\n'
}

# The text the editor would submit right now, nothing when it is idle or
# unreadable. The capture mode follows the parser: claude/codex need wrapped
# lines joined, pi's box parser compares full-width borders and reads the raw
# screen. Used by the startup retry in bin/crew to check a draft is exactly
# the line crew typed.
draft_text() { # pane
  local cli cap dims=""
  cli=$(short_cli "$(pane_cli "$1")")
  case "$cli" in
    claude|codex) cap=$(pane_capture "$1" "$cli" -J 2>/dev/null) || return 0 ;;
    pi)
      cap=$(tmux capture-pane -p -t "$1" 2>/dev/null) || return 0
      dims=$(tmux display-message -p -t "$1" '#{pane_width} #{pane_height} #{cursor_y}' 2>/dev/null) ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$cap" | pane_editor_text "$cli" "$dims"
}

# Seconds ring() may hold a doorbell for (CREW_RING_WAIT): digits, else the
# documented 30. A leading zero must not reach $(( )) as octal (08 is a fatal
# error under set -e); strip zeros first so 00000 is the zero wait, not a
# 5-digit value. An absurd value must not overflow into a negative slot count
# ("wait forever" would become "never ring").
ring_secs() {
  local s="${CREW_RING_WAIT:-30}"
  case "$s" in ''|*[!0-9]*) s=30 ;; esac
  s="${s#"${s%%[!0]*}"}"
  [ -n "$s" ] || s=0
  if [ ${#s} -gt 4 ]; then s=3600; else s=$((10#$s)); fi
  [ "$s" -le 3600 ] || s=3600
  printf '%s' "$s"
}

# A doorbell must never land in an unsubmitted draft: send-keys would append
# it to the draft and submit both. Wait, bounded, for the editor to clear;
# anything else pane_hold reports (dialog, mode, unreadable, gone pane) is
# refused at once. CREW_RING_WAIT=0 means no waiting, not no protection: the
# pane is checked once and any non-free class is reported immediately. Prints
# why the doorbell is not typed, nothing when the pane is safe. The wait
# happens before ring() takes its lock, so a hold blocks neither another ring
# nor the 10 s stale-lock rule. An expected role keeps a doorbell addressed to
# one role from landing on the pane after an override swapped the roles; a
# caller that names no role keeps the roster lookup below (startup panes may
# not be bound yet).
ring_hold() { # pane [expected-role]
  local pane="$1" want="${2:-}" secs slots role why
  secs=$(ring_secs); slots=$((secs * 2))          # poll twice a second
  while :; do
    if [ -n "$want" ]; then
      if ! owns_pane "$pane" "$want"; then
        printf 'pane %s is gone or no longer belongs to %s' "$pane" "$want"; return 0
      fi
    else
      role=$(awk -F'\t' -v p="$pane" '$2==p{print $1; exit}' "$D/panes")
      if [ -z "$role" ] || ! owns_pane "$pane" "$role"; then
        printf 'pane %s is gone or now belongs to something else' "$pane"; return 0
      fi
    fi
    why=$(pane_hold "$pane")
    case "$why" in
      '') return 0 ;;                               # free: ring now
      draft"$TAB"*) ;;                              # a draft: wait it out…
      *) printf '%s' "${why#*"$TAB"}"; return 0 ;;  # dialog/mode/unreadable: refuse at once
    esac
    if [ "$slots" -le 0 ]; then printf '%s' "${why#*"$TAB"}"; return 0; fi   # …or report at the deadline
    slots=$((slots - 1)); sleep 0.5
  done
}

# Two crew calls ringing one pane at once would interleave their keystrokes
# into one garbled prompt, so a ring holds a per-pane mkdir lock. A ring takes
# ~0.3 s, so a lock still held after 10 s is left by a killed call: ring anyway.
# Safe by default: the hold runs first. `--now` types at once (a pane crew just
# created); it is the exception, not the normal path. `--role <role>` pins whom
# the doorbell is for: ownership is checked again after the lock, because an
# override can swap two roles between the hold and the keystrokes, and the
# recipient's wording must never land on the successor's prompt.
ring() { # [--now] [--role <role>] pane text — hold for a draft, then type one line and submit it
  local now=0 want=""
  while :; do
    case "${1:-}" in
      --now) now=1; shift ;;
      --role) want="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done
  local pane="$1" text="$2" why="" l rc=0
  if [ "$now" = 0 ]; then
    why=$(ring_hold "$pane" "$want") || true
    if [ -n "$why" ]; then printf '%s' "$why"; return 1; fi
  fi
  l="$D/.ring${pane#%}.lock"
  # Timers skip contention instead of waiting beyond lifecycle lock budgets.
  # This mode refuses a busy doorbell; it never bypasses a lock or a hold.
  if [ "${RING_TRY_LOCK:-0}" = 1 ]; then
    if ! mkdir "$l" 2>/dev/null; then printf 'pane %s doorbell is already ringing' "$pane"; return 1; fi
  else take_lock "$l" 100 || true; fi
  if [ -n "$want" ] && ! owns_pane "$pane" "$want"; then
    why="pane $pane is gone or no longer belongs to $want"
  elif [ "$now" = 0 ]; then
    # The editor can change while an ordinary ring waits for its lock.
    why=$(pane_hold "$pane") || why='could not read the editor after taking the doorbell lock'
  fi
  if [ -n "$why" ]; then
    rc=1; printf '%s' "${why#*"$TAB"}"
  elif tmux send-keys -t "$pane" -l -- "$text" && sleep 0.3 && tmux send-keys -t "$pane" Enter; then rc=0
  else rc=1; printf 'could not reach pane %s' "$pane"; fi
  rmdir "$l" 2>/dev/null || true
  return "$rc"
}

# ---------- held doorbells: one pending re-ring per role ----------
# A ring that is held (draft, dialog, copy mode, unreadable editor, failed
# send-keys) leaves its message in the inbox and types nothing. `deliver`
# records one held delivery per role, so a `--ring` watcher can replay a single
# coalesced reminder once that role's editor is free again. The record is one
# line holding a count, `pending/<role>`: it follows the role, not the pane, so
# a rebind or override sends the reminder to the role's current pane (its inbox
# is the role's) and never to a stale one. Only a short read-modify-write of
# that one file is locked, and the lock is never stolen: a held lock means
# "defer" and is named in the diagnostic the sender gets, with the repair
# (remove `$D/pending/.<role>.lock` if its holder is gone). A watcher releases
# a pending lock it still holds when it exits, so stopping one is safe. Best
# effort across a crash: a call killed between reading and writing the counter
# loses at most that one increment; the message stays in the inbox and its
# `not rung` timeline line still records it. Nothing here is a queue or a
# daemon.
pending_lock() { # role — focused mkdir lock, kept in $pending_held for cleanup
  local l="$D/pending/.$1.lock"
  mkdir "$D/pending" 2>/dev/null || true
  take_lock "$l" 20 || return 1
  pending_held="$l"
}

pending_unlock() {
  [ -z "${pending_held:-}" ] || rmdir "$pending_held" 2>/dev/null || true
  pending_held=""
}

pending_count() { # role -> held doorbells (0 when none)
  local n
  n=$(cat "$D/pending/$1" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

pending_add() { # role — remember one held delivery (coalesced count)
  local n rc=0
  pending_lock "$1" || return 1
  n=$(pending_count "$1")
  printf '%s\n' "$((n + 1))" > "$D/pending/$1.tmp.$$" &&
    mv "$D/pending/$1.tmp.$$" "$D/pending/$1" || rc=1
  pending_unlock
  return "$rc"
}

# Ring one coalesced reminder for a role's held deliveries. Only `crew watch
# --ring` calls this: stdout watch is read-only and never replays. The pending
# lock serialises replayers, so exactly one reminder goes out and it can clear
# the count it announced; the ring itself stays the ordinary guarded path
# (ownership, expected role after the lock, draft/dialog hold) and is bounded
# because the watcher checks once and refuses a contended pane instead of
# waiting. A busy pane is left pending, silently, until a later scan finds it
# free; only a locked counter is reported, because that needs a human.
pending_replay() { # role [pane]
  local role="$1" pane="${2:-}" n why plural
  [ -f "$D/pending/$role" ] || return 0
  [ -n "$pane" ] || pane=$(pane_of "$role")
  [ -n "$pane" ] || return 0
  owns_pane "$pane" "$role" || return 0   # never a stale, reused or rebound-away pane
  [ -z "$(pane_hold "$pane")" ] || return 0
  if ! pending_lock "$role"; then
    log_line sys watch "$role" "$role re-ring deferred: pending/.$role.lock is held; if its holder is gone, remove it"
    return 0
  fi
  n=$(pending_count "$role")
  if [ "$n" -gt 0 ]; then
    plural=""; [ "$n" -eq 1 ] || plural=s
    why=$(CREW_RING_WAIT=0 RING_TRY_LOCK=1 ring --role "$role" "$pane" \
      "[crew] watch → $role: $n new message$plural — crew inbox $role") || true
    if [ -z "$why" ]; then
      rm -f "$D/pending/$role"
      log_line sys watch "$role" "$role rung for $n held message(s); see inbox/$role.md"
    fi
  fi
  pending_unlock
}
