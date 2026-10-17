# Sourced by bin/crew; the pane readers, the doorbell `ring` and its hold.
# Uses bin/crew's state-file, identity and locking helpers.

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
DIALOG_RE='enter (to )?(confirm|continue|select)|trust this folder|do you want to proceed|would you like to (run|make|grant|send)|don.t ask again'

# The last 15 non-blank rows of a capture: where a dialog's footer lives.
dialog_region() { sed '/^[[:space:]]*$/d' | tail -n 15; }

in_dialog() { # pane
  tmux capture-pane -p -t "$1" 2>/dev/null | dialog_region | grep -qiE "$DIALOG_RE"
}

# Why crew must not type into this pane: a `class<TAB>reason` record, nothing
# (and exit 0) when it is free. A dialog or a mode swallows keys before the
# editor sees them, so they are checked first (claude reuses its ❯ marker
# inside dialogs, e.g. "❯ 1. Yes"). Only the CLIs whose editor row we can read
# are checked: an unknown pane is never held for a draft — a false hold makes
# an agent unringable, which is worse than typing into it. Dialogs and modes
# are checked for every pane.
pane_hold() { # pane
  local cli cap why=""
  cap=$(tmux capture-pane -p -t "$1" 2>/dev/null) || return 0
  if printf '%s\n' "$cap" | dialog_region | grep -qiE "$DIALOG_RE"; then
    printf 'dialog\tpane %s is showing a dialog or approval prompt' "$1"; return 0
  fi
  case "$(tmux display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null)" in
    0|'') ;;
    *) printf 'mode\tpane %s is in copy/choose mode' "$1"; return 0 ;;
  esac
  cli=$(short_cli "$(pane_cli "$1")")
  case "$cli" in
    claude) why=$(printf '%s\n' "$cap" | prompt_row_draft '❯' '') ;;
    codex)  why=$(printf '%s\n' "$cap" | prompt_row_draft '›' 'Ask Codex to do anything') ;;
    pi)     why=$(printf '%s\n' "$cap" | pi_box_draft "$(tmux display-message -p -t "$1" '#{pane_width} #{pane_height} #{cursor_y}' 2>/dev/null)") ;;
    *) return 0 ;;
  esac
  [ -z "$why" ] || printf 'draft\t%s' "$why"
}

# The bottom-most prompt row, minus a known placeholder: blank (or the
# placeholder) means an idle editor, other text a draft. No marker at all
# means we cannot read this editor, so the pane is left alone.
prompt_row_draft() { # marker placeholder — capture rows on stdin
  local marker="$1" placeholder="$2" row text
  row=$(grep -F -- "$marker" | tail -n 1) || true
  [ -n "$row" ] || return 0
  text=$(printf '%s' "${row#*$marker}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$text" ] || return 0
  if [ -n "$placeholder" ]; then
    case "$text" in "$placeholder"*) return 0 ;; esac   # a renamed placeholder becomes a loud hold
  fi
  printf 'unsubmitted draft in the editor'
}

# pi draws its editor as a box: its top and bottom are the last two rows that
# look like borders, and any non-empty row between them is a draft. Read
# bottom-up, so transcript rows and queued `Steering:` notes above the box
# cannot confuse it. A border is a dashes-only row spanning the pane or a
# mostly-dashes row carrying a label (`── ⠧ Working ──`); a 100-of-120-dash
# draft row is neither. The cursor row is editor content, never a border.
pi_box_draft() { # "pane_width pane_height cursor_y" — capture rows on stdin
  awk -v dims="${1:-}" '
    BEGIN { split(dims, d, " "); w = d[1] + 0; h = d[2] + 0; cy = -1
            if (h > 0 && d[3] ~ /^[0-9]+$/) cy = d[3] + 0
            if (!w) w = 80; if (!h) h = 24 }
    # BSD awk counts bytes; ─ is 3 of them in UTF-8 (a UTF-8 locale is assumed).
    function dashes(s, t) { t = s; gsub(/─/, "", t); return (length(s) - length(t)) / 3 }
    function label(s, t) { t = s; gsub(/[─[:space:]]/, "", t); return length(t) > 0 }
    function border(s) { return dashes(s) >= w - 3 ? !label(s) : (dashes(s) >= w * 0.55 && label(s)) }
    { row[NR] = $0 }
    END {
      cur = (cy >= 0 && cy < h && h <= NR) ? NR - h + cy + 1 : 0   # 0: no cursor row known
      bot = 0; top = 0
      for (i = NR; i >= 1; i--) if (border(row[i]) && i != cur) { bot = i; break }
      if (!bot) exit
      for (j = bot - 1; j >= 1; j--) if (border(row[j]) && j != cur) { top = j; break }
      if (!top) exit
      for (k = top + 1; k < bot; k++) if (row[k] != "") { print "unsubmitted draft in the editor"; exit }
    }'
}

# Seconds ring() may hold a doorbell for (CREW_RING_WAIT): digits, else the
# documented 30. A leading zero must not reach $(( )) as octal (08 is a fatal
# error under set -e), and an absurd value must not overflow into a negative
# slot count ("wait forever" would become "never ring").
ring_secs() {
  local s="${CREW_RING_WAIT:-30}"
  case "$s" in ''|*[!0-9]*) s=30 ;; esac
  if [ ${#s} -gt 4 ]; then s=3600; else s=$((10#$s)); fi
  [ "$s" -le 3600 ] || s=3600
  printf '%s' "$s"
}

# A doorbell must never land in an unsubmitted draft: send-keys would append
# it to the draft and submit both. Wait, bounded, for the editor to clear.
# Dialogs and modes return at once (the keys would land in the wrong place).
# Prints why the doorbell is not typed, nothing when the pane is safe. The
# wait happens before ring() takes its lock, so a hold blocks neither another
# ring nor the 10 s stale-lock rule.
ring_hold() { # pane
  local pane="$1" secs slots role why
  secs=$(ring_secs); slots=$((secs * 2))          # poll twice a second
  [ "$slots" -gt 0 ] || return 0                  # CREW_RING_WAIT=0 turns the hold off
  while :; do
    role=$(awk -F'\t' -v p="$pane" '$2==p{print $1; exit}' "$D/panes")
    if [ -z "$role" ] || ! owns_pane "$pane" "$role"; then
      printf 'pane %s is gone or now belongs to something else' "$pane"; return 0
    fi
    why=$(pane_hold "$pane")
    case "$why" in
      '') return 0 ;;                               # free: ring now
      draft"$TAB"*) ;;                              # still a draft: keep waiting
      *) printf '%s' "${why#*"$TAB"}"; return 0 ;;  # dialog/mode: report at once
    esac
    if [ "$slots" -le 0 ]; then printf '%s' "${why#*"$TAB"}"; return 0; fi
    slots=$((slots - 1)); sleep 0.5
  done
}

# Two crew calls ringing one pane at once would interleave their keystrokes
# into one garbled prompt, so a ring holds a per-pane mkdir lock. A ring takes
# ~0.3 s, so a lock still held after 10 s is left by a killed call: ring anyway.
# Safe by default: the hold runs first. `--now` types at once (a pane crew just
# created, or CREW_RING_WAIT=0); it is the exception, not the normal path.
ring() { # [--now] pane text — hold for a draft, then type one line into the pane and submit it
  local now=0
  case "${1:-}" in --now) now=1; shift ;; esac
  local pane="$1" text="$2" why="" l rc=0
  if [ "$now" = 0 ]; then
    why=$(ring_hold "$pane") || true
    if [ -n "$why" ]; then printf '%s' "$why"; return 1; fi
  fi
  l="$D/.ring${pane#%}.lock"
  take_lock "$l" 100 || true
  if tmux send-keys -t "$pane" -l -- "$text" && sleep 0.3 && tmux send-keys -t "$pane" Enter; then rc=0
  else rc=1; printf 'could not reach pane %s' "$pane"; fi
  rmdir "$l" 2>/dev/null || true
  return "$rc"
}
