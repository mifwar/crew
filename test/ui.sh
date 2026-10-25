# Sourced by smoke.sh. Terminal dashboard (crew ui): the headerless _ui-state /
# _ui-jump backend, and the real Bun TUI driven in detached panes.
#
# Read-only is the contract under test: these commands may not change crew
# files. Fixture panes (UIs and helper panes) carry @crew_session=ui-fixture, so
# every send-keys / kill-pane re-checks the same owns_pane rule bin/crew uses;
# crew panes are checked against their own session/role labels. Pane env comes
# from the generated wrappers, never from the tmux server's inherited env.
: "${ROOT:?run via test/smoke.sh}" "${CREW:?run via test/smoke.sh}" "${TS:?run via test/smoke.sh}" "${CREW_HOME:?run via test/smoke.sh}"
case "$TS" in crew-smoke-*|crew-ui-targeted-*) ;; *) echo 'FAIL  ui tests require their own detached session'; fail=1; return 1 ;; esac
case "$CREW_HOME" in "$HOME/.crew"|"$HOME/.crew/"*) echo 'FAIL  ui tests refuse live crew storage'; fail=1; return 1 ;; esac
ui_fix="$CREW_HOME/ui-fixture"
mkdir -p "$ui_fix"
sed -n '/^owns_pane()/,/^}/p' "$CREW" > "$ui_fix/owns.sh"
ui_owns() { ( . "$ui_fix/owns.sh"; S="$1"; owns_pane "$2" "$3" ); }
ui_guard() { # session role pane
  ui_owns "$1" "$2" "$3" && return 0
  printf 'FAIL  guard: %s no longer carries %s/%s\n' "$3" "$1" "$2"; fail=1; return 1
}
ui_send() { local p=$1 s=$2 r=$3; shift 3; ui_guard "$s" "$p" "$r" && tmux send-keys -t "$p" "$@"; }
ui_kill() { local p=$1 s=$2 r=$3; ui_guard "$s" "$p" "$r" && tmux kill-pane -t "$p" 2>/dev/null; }
ui_text() { tmux capture-pane -p -J -t "$1" 2>/dev/null; }
ui_wait() { local i; for i in $(seq 1 150); do ui_text "$1" | grep -qF -- "$2" && return 0; sleep 0.1; done; return 1; }
ui_wait_rc() { local i; for i in $(seq 1 100); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }
ui_panes=""
ui_n=0

# One pane per UI run: a pty wrapper records stty before/after and the exit
# code, then keeps a shell alive so the restored screen can be inspected.
ui_start() { # crew [cols rows]
  ui_n=$((ui_n + 1)); ui_tag="$ui_fix/run$ui_n"
  {
    printf '#!/bin/bash\nexport CREW_HOME=%s CREW_NO_SWITCH=1\n' "$(printf '%q' "$CREW_HOME")"
    printf 'printf "%%s" "$(stty -g)" > %s.before\n' "$(printf '%q' "$ui_tag")"
    printf '%q -s %q ui\n' "$CREW" "$1"
    printf 'rc=$?\nprintf "%%s" "$(stty -g)" > %s.after\nprintf "%%s" "$rc" > %s.rc\nexec bash\n' \
      "$(printf '%q' "$ui_tag")" "$(printf '%q' "$ui_tag")"
  } > "$ui_tag.sh"
  ui_pane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" "bash '$ui_tag.sh'")
  tmux set-option -p -t "$ui_pane" @crew_session ui-fixture
  tmux set-option -p -t "$ui_pane" @crew_role viewer
  ui_panes="$ui_panes $ui_pane:viewer"
  if [ $# -ge 3 ]; then
    tmux resize-window -t "$(tmux display -p -t "$ui_pane" '#{window_id}')" -x "$2" -y "$3"
  fi
}
# Helper pane: run one crew command in a real pane of a chosen session, keeping
# stdout, stderr and the exit code for assertions.
ui_helper() { # tag session cmd...
  local tag="$ui_fix/$1" sess=$2; shift 2
  {
    printf '#!/bin/bash\nexport CREW_HOME=%s CREW_NO_SWITCH=1\n' "$(printf '%q' "$CREW_HOME")"
    printf '"$@" > %s.out 2> %s.err\nprintf "%%s" "$?" > %s.rc\nexec bash\n' \
      "$(printf '%q' "$tag")" "$(printf '%q' "$tag")" "$(printf '%q' "$tag")"
  } > "$tag.sh"
  ui_hpane=$(tmux new-window -d -P -F '#{pane_id}' -t "$sess:" "bash '$tag.sh' $(printf '%q ' "$@")")
  tmux set-option -p -t "$ui_hpane" @crew_session ui-fixture
  tmux set-option -p -t "$ui_hpane" @crew_role helper
  ui_panes="$ui_panes $ui_hpane:helper"
}
ui_crews() { # the UI's Tab order: names with panes, no ended marker, sorted
  ( cd "$CREW_HOME" && for f in */panes; do [ -f "$f" ] || continue
      d=${f%/panes}; [ -f "$d/ended" ] && continue
      case "$d" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) continue ;; esac
      printf '%s\n' "$d"; done ) | LC_ALL=C sort
}
ui_snapshot() { # dir out — content hashes plus the file list
  ( cd "$1" && for f in panes board.tsv channel.log cwd.tsv; do
      [ -f "$f" ] && printf '%s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done
    printf 'current %s\n' "$(shasum -a 256 "$CREW_HOME/.current" 2>/dev/null | cut -d' ' -f1)"
    find . -type f | LC_ALL=C sort ) > "$2"
}

# --- fixtures -----------------------------------------------------------------
cat > "$ui_fix/mock-error.sh" <<'EOS'
#!/bin/sh
printf 'Connection error\n'
cat >/dev/null
EOS
"$CREW" up uia --in "$TS" --no-watch "alpha=cat" "beta=cat" "gamma=sh $ui_fix/mock-error.sh" >/dev/null 2>&1
"$CREW" up uib --in "$TS" --no-watch solo=cat >/dev/null 2>&1
uid="$CREW_HOME/uia"
alpha=$(awk -F'\t' '$1=="alpha"{print $2}' "$uid/panes")
beta=$(awk -F'\t' '$1=="beta"{print $2}' "$uid/panes")
ui_send "$alpha" uia alpha 'alpha-preview-marker' Enter
ui_send "$beta" uia beta 'beta--preview--marker' Enter

# A crew whose roles point at a live-but-unlabelled pane (a reused id) and at a
# dead pane, for the stale/gone guards.
"$CREW" up uistale --in "$TS" --no-watch live=cat stale=cat gone=cat >/dev/null 2>&1
sdir="$CREW_HOME/uistale"
stale_orig=$(awk -F'\t' '$1=="stale"{print $2}' "$sdir/panes")
gone_orig=$(awk -F'\t' '$1=="gone"{print $2}' "$sdir/panes")
ui_fresh=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" cat)
tmux set-option -p -t "$ui_fresh" @crew_session ui-fixture
tmux set-option -p -t "$ui_fresh" @crew_role reused
cp "$sdir/panes" "$ui_fix/uistale-panes"
awk -F'\t' -v OFS='\t' -v p="$ui_fresh" '$1=="stale"{$2=p} $1=="gone"{$2="%999999"} {print}' \
  "$ui_fix/uistale-panes" > "$sdir/panes"
stale_pane=$(awk -F'\t' '$1=="stale"{print $2}' "$sdir/panes")

# --- backend: headerless state, ownership and navigation ----------------------
check "_ui-state emits one headerless 7-field TSV row per role" bash -c '
  out=$("$1" -s uia _ui-state) && test "$(printf "%s\n" "$out" | wc -l | tr -d " ")" = 3 &&
  printf "%s\n" "$out" | awk -F"\t" "NF!=7{exit 1}"
' _ "$CREW"
check "_ui-state carries the shared observer state and error note" bash -c '
  "$1" -s uia _ui-state | awk -F"\t" "
    \$1==\"alpha\" && \$4==\"unknown\"{a=1}
    \$1==\"gamma\" && \$4==\"error\" && \$7 ~ /Connection error/{g=1}
    END{exit !(a && g)}"
' _ "$CREW"
check "_ui-state reports stale and gone pane bindings instead of crashing" bash -c '
  "$1" -s uistale _ui-state | awk -F"\t" "
    \$1==\"stale\" && \$4==\"stale\"{s=1} \$1==\"gone\" && \$4==\"gone\"{g=1} END{exit !(s && g)}"
' _ "$CREW"

ui_snapshot "$uid" "$ui_fix/ro.before"
ro_rc=0
"$CREW" -s uia _ui-state >/dev/null 2>&1 || ro_rc=$?
"$CREW" -s uia peek alpha 5 >/dev/null 2>&1 || ro_rc=$?
ui_helper jumpok "$TS" "$CREW" -s uia _ui-jump alpha
ui_wait_rc "$ui_fix/jumpok.rc"
ui_snapshot "$uid" "$ui_fix/ro.after"
check "_ui-state, peek and _ui-jump all succeed" test "$ro_rc" = 0
check "state, preview and jump leave crew files byte-identical" cmp -s "$ui_fix/ro.before" "$ui_fix/ro.after"
check "  and create no ring or pending state" bash -c '
  ! ls "$1"/.ring*.lock "$1"/pending/* 2>/dev/null | grep -q .
' _ "$uid"

check "_ui-jump selects the target inside this tmux session" bash -c '
  test "$(cat "$1/jumpok.rc")" = 0 && test ! -s "$1/jumpok.out" &&
  test "$(tmux display -p -t "$2" "#{window_active}#{pane_active}")" = 11
' _ "$ui_fix" "$alpha"
ui_helper jumpstale "$TS" "$CREW" -s uistale _ui-jump stale
ui_wait_rc "$ui_fix/jumpstale.rc"
check "_ui-jump refuses a reused pane without switching" bash -c '
  test "$(cat "$1/jumpstale.rc")" = 1 && test ! -s "$1/jumpstale.out" &&
  grep -q "gone or reused" "$1/jumpstale.err" &&
  test "$(tmux display -p -t "$2" "#{pane_id}")" != "$3"
' _ "$ui_fix" "$TS" "$stale_pane"
ui_helper jumpunknown "$TS" "$CREW" -s uia _ui-jump nosuch
ui_wait_rc "$ui_fix/jumpunknown.rc"
check "_ui-jump refuses an unknown role" bash -c '
  test "$(cat "$1/jumpunknown.rc")" = 1 && grep -q "no agent .nosuch." "$1/jumpunknown.err"
' _ "$ui_fix"
ui_ts2="ui-other-$$"
tmux new-session -d -s "$ui_ts2" -x 80 -y 20
ui_ts2_pane=$(tmux display -p -t "$ui_ts2:" '#{pane_id}')
ui_helper jumpcross "$ui_ts2" "$CREW" -s uia _ui-jump alpha
ui_wait_rc "$ui_fix/jumpcross.rc"
check "_ui-jump refuses a pane in another tmux session" bash -c '
  test "$(cat "$1/jumpcross.rc")" = 1 && grep -q "another tmux session" "$1/jumpcross.err" &&
  test "$(tmux display -p -t "$2" "#{window_id}")" != "$(tmux display -p -t "$3" "#{window_id}")"
' _ "$ui_fix" "$alpha" "$ui_ts2_pane"

"$CREW" -s uia ui </dev/null >"$ui_fix/nonint.out" 2>"$ui_fix/nonint.err"
nonint_rc=$?
check "crew ui rejects a non-tty before drawing anything" bash -c '
  test "$2" = 1 && grep -q "needs an interactive terminal" "$1/nonint.err" &&
  ! grep -q "$(printf "\033")" "$1/nonint.out"
' _ "$ui_fix" "$nonint_rc"
ui_dumb_term() { # stderr to a file, stdout stays the pty so the tty guard passes
  local tag="$ui_fix/termdumb"
  printf '#!/bin/bash\nexport CREW_HOME=%s CREW_NO_SWITCH=1\nTERM=dumb %q -s uia ui 2> %s.err\nprintf "%%s" "$?" > %s.rc\nexec bash\n' \
    "$(printf '%q' "$CREW_HOME")" "$CREW" "$(printf '%q' "$tag")" "$(printf '%q' "$tag")" > "$tag.sh"
  ui_hpane=$(tmux new-window -d -P -F '#{pane_id}' -t "$TS:" "bash '$tag.sh'")
  tmux set-option -p -t "$ui_hpane" @crew_session ui-fixture
  tmux set-option -p -t "$ui_hpane" @crew_role helper
  ui_panes="$ui_panes $ui_hpane:helper"
}
ui_dumb_term
ui_wait_rc "$ui_fix/termdumb.rc"
check "crew ui rejects TERM=dumb in a pty, before any alt screen" bash -c '
  test "$(cat "$1/termdumb.rc")" = 1 && grep -q "cursor support" "$1/termdumb.err" &&
  ! tmux capture-pane -p -J -t "$2" | grep -qF "crew / uia"
' _ "$ui_fix" "$ui_hpane"

# Shared observer guard: the UI's state rows go through pane_editor_text, so an
# unknown CLI capture must be drained even when the caller sets pipefail (a
# SIGPIPE there used to read as an unreadable editor and hold doorbells).
check "pane_editor_text drains an unknown CLI capture under pipefail" bash -c '
  set -o pipefail
  . "$1/share/crew/pane.sh"
  out=$(awk "BEGIN{for(i=0;i<200000;i++) print \"row \" i}" | pane_editor_text mystery-cli "")
  test "$?" = 0 && test -z "$out"
' _ "$ROOT"

# --- Bun TUI in detached panes ------------------------------------------------
if command -v bun >/dev/null 2>&1; then
  ui_start uia; ui_frame=$ui_pane; ui_frame_tag=$ui_tag
  check "ui renders header, roster, error row, keys and live preview" bash -c '
    i=0; while [ $i -lt 150 ]; do
      screen=$(tmux capture-pane -p -J -t "$1")
      printf "%s" "$screen" | grep -qF "crew / uia" &&
      printf "%s" "$screen" | grep -qF "alpha · cat · unknown" &&
      printf "%s" "$screen" | grep -qF "gamma · sh · error" &&
      printf "%s" "$screen" | grep -qF "alpha-preview-marker" &&
      printf "%s" "$screen" | grep -qF "q/Esc quit" && exit 0
      i=$((i+1)); sleep 0.1; done; exit 1
  ' _ "$ui_frame"
  if [ -n "${UI_ARTIFACT_DIR:-}" ]; then
    tmux capture-pane -ep -J -t "$ui_frame" > "$UI_ARTIFACT_DIR/T1-ui-wide.capture.ansi.txt"
  fi

  ui_send "$ui_frame" ui-fixture viewer j
  check "j moves selection and the preview follows it" ui_wait "$ui_frame" "beta--preview--marker"
  ui_send "$ui_frame" ui-fixture viewer Down
  check "Down reaches the next agent" ui_wait "$ui_frame" "› gamma"
  ui_send "$ui_frame" ui-fixture viewer Down
  check "selection clamps at the last agent" bash -c '
    sleep 0.3; tmux capture-pane -p -J -t "$1" | grep -qF "› gamma"
  ' _ "$ui_frame"
  ui_send "$ui_frame" ui-fixture viewer k
  ui_send "$ui_frame" ui-fixture viewer k
  ui_send "$ui_frame" ui-fixture viewer Up
  check "selection clamps at the first agent" bash -c '
    sleep 0.4; tmux capture-pane -p -J -t "$1" | grep -qF "› alpha"
  ' _ "$ui_frame"

  ui_second=$(ui_crews | awk '$0 > "uib"{print; exit}')
  ui_first=$(ui_crews | head -n 1)
  ui_send "$ui_frame" ui-fixture viewer Tab
  check "Tab moves to the next crew in sorted order" ui_wait "$ui_frame" "crew / uib"
  ui_send "$ui_frame" ui-fixture viewer Tab
  check "  then to the crew after it" ui_wait "$ui_frame" "crew / $ui_second"
  ui_i=0
  while [ "$ui_i" -le "$(ui_crews | wc -l | tr -d ' ')" ] &&
        ! ui_text "$ui_frame" | grep -qF "crew / $ui_first"; do
    ui_send "$ui_frame" ui-fixture viewer Tab; sleep 0.3; ui_i=$((ui_i + 1))
  done
  check "  and wraps to the first live crew" ui_wait "$ui_frame" "crew / $ui_first"
  ui_i=0
  while [ "$ui_i" -le "$(ui_crews | wc -l | tr -d ' ')" ] &&
        ! ui_text "$ui_frame" | grep -qF "crew / uia"; do
    ui_send "$ui_frame" ui-fixture viewer Tab; sleep 0.3; ui_i=$((ui_i + 1))
  done
  check "Tab cycles back to uia with its roster, selection and preview" bash -c '
    i=0; while [ $i -lt 150 ]; do
      screen=$(tmux capture-pane -p -J -t "$1")
      printf "%s" "$screen" | grep -qF "› alpha" &&
      printf "%s" "$screen" | grep -qF "alpha-preview-marker" && exit 0
      i=$((i+1)); sleep 0.1; done; exit 1
  ' _ "$ui_frame"

  ui_send "$ui_frame" ui-fixture viewer Enter
  ui_wait_rc "$ui_frame_tag.rc"
  check "Enter jumps on exit: the target pane becomes active" bash -c '
    test "$(cat "$1.rc")" = 0 &&
    test "$(tmux display -p -t "$2" "#{window_active}#{pane_active}")" = 11
  ' _ "$ui_frame_tag" "$alpha"
  check "jump restores the terminal and leaves the alt screen" bash -c '
    test "$(cat "$1.before")" = "$(cat "$1.after")" &&
    ! tmux capture-pane -p -J -t "$2" | grep -qF "crew / uia"
  ' _ "$ui_frame_tag" "$ui_frame"
  ui_send "$ui_frame" ui-fixture viewer 'echo tty-ok' Enter
  check "  and the pane takes input afterwards" ui_wait "$ui_frame" "tty-ok"

  ui_start uia; ui_q=$ui_pane; ui_q_tag=$ui_tag
  ui_wait "$ui_q" "crew / uia"
  ui_send "$ui_q" ui-fixture viewer q
  ui_wait_rc "$ui_q_tag.rc"
  check "q exits 0 with the original stty state and no alt screen" bash -c '
    test "$(cat "$1.rc")" = 0 && test "$(cat "$1.before")" = "$(cat "$1.after")" &&
    ! tmux capture-pane -p -J -t "$2" | grep -qF "crew / uia"
  ' _ "$ui_q_tag" "$ui_q"

  ui_start uia; ui_ctrl=$ui_pane; ui_ctrl_tag=$ui_tag
  ui_wait "$ui_ctrl" "crew / uia"
  ui_send "$ui_ctrl" ui-fixture viewer C-c
  ui_wait_rc "$ui_ctrl_tag.rc"
  check "Ctrl-C exits 0 with the original stty state and no alt screen" bash -c '
    test "$(cat "$1.rc")" = 0 && test "$(cat "$1.before")" = "$(cat "$1.after")" &&
    ! tmux capture-pane -p -J -t "$2" | grep -qF "crew / uia"
  ' _ "$ui_ctrl_tag" "$ui_ctrl"

  ui_start uia; ui_esc=$ui_pane; ui_esc_tag=$ui_tag
  ui_wait "$ui_esc" "crew / uia"
  ui_send "$ui_esc" ui-fixture viewer Escape
  ui_wait_rc "$ui_esc_tag.rc"
  check "a lone Esc exits 0 and restores the terminal" bash -c '
    test "$(cat "$1.rc")" = 0 && test "$(cat "$1.before")" = "$(cat "$1.after")" &&
    ! tmux capture-pane -p -J -t "$2" | grep -qF "crew / uia"
  ' _ "$ui_esc_tag" "$ui_esc"

  ui_start uistale; ui_stale=$ui_pane; ui_stale_tag=$ui_tag
  ui_wait "$ui_stale" "live · cat · unknown"
  ui_send "$ui_stale" ui-fixture viewer j
  check "selecting a reused pane previews peek's refusal, not a stale capture" bash -c '
    i=0; while [ $i -lt 150 ]; do
      screen=$(tmux capture-pane -p -J -t "$1")
      printf "%s" "$screen" | grep -qF "› stale" &&
      printf "%s" "$screen" | grep -qF "now belongs to something else" && exit 0
      i=$((i+1)); sleep 0.1; done; exit 1
  ' _ "$ui_stale"
  ui_active_before=$(tmux display -p -t "$TS" '#{window_id}:#{pane_id}')
  ui_send "$ui_stale" ui-fixture viewer Enter
  check "Enter on a reused pane refuses, says why and stays open" bash -c '
    sleep 0.8
    test ! -s "$1.rc" &&
    tmux capture-pane -p -J -t "$2" | grep -qF "gone or reused" &&
    test "$(tmux display -p -t "$3" "#{window_id}:#{pane_id}")" = "$4"
  ' _ "$ui_stale_tag" "$ui_stale" "$TS" "$ui_active_before"
  ui_send "$ui_stale" ui-fixture viewer q
  ui_wait_rc "$ui_stale_tag.rc"
  check "  and q still exits 0 afterwards" test "$(cat "$ui_stale_tag.rc")" = 0

  # Live read-only: a full session (selection plus one refresh tick) must not
  # touch crew files, pane options, doorbells or draft state.
  ui_snapshot "$uid" "$ui_fix/live.before"
  ui_opts_before=$(for r in alpha beta gamma; do
    p=$(awk -F'\t' -v r="$r" '$1==r{print $2}' "$uid/panes")
    tmux display -p -t "$p" '#{@crew_status}'; done)
  ui_start uia; ui_live=$ui_pane; ui_live_tag=$ui_tag
  ui_wait "$ui_live" "alpha · cat · unknown"
  ui_send "$ui_live" ui-fixture viewer j
  sleep 2.5
  ui_send "$ui_live" ui-fixture viewer q
  ui_wait_rc "$ui_live_tag.rc"
  ui_snapshot "$uid" "$ui_fix/live.after"
  ui_opts_after=$(for r in alpha beta gamma; do
    p=$(awk -F'\t' -v r="$r" '$1==r{print $2}' "$uid/panes")
    tmux display -p -t "$p" '#{@crew_status}'; done)
  check "a live ui session leaves crew files and pane options untouched" bash -c '
    cmp -s "$1/live.before" "$1/live.after" && test "$2" = "$3"
  ' _ "$ui_fix" "$ui_opts_before" "$ui_opts_after"

  bun -e '
    import { clean, fit } from "'"$ROOT"'/share/crew/ui.ts";
    let bad = 0;
    const ok = (name: string, cond: boolean) => { console.log(`${cond ? "ok  " : "FAIL"} ${name}`); if (!cond) bad++; };
    const W = (s: string) => Bun.stringWidth(s);
    ok("clean strips SGR", clean("\u001b[31mred\u001b[0m") === "red");
    ok("clean strips OSC and control bytes", !/[\u0000-\u001f\u007f-\u009f]/.test(clean("a\u0000b\u0007c\u009bd\u001b]52;c;x\u0007e")));
    ok("clean keeps printable unicode", clean("café 日本 😀") === "café 日本 😀");
    ok("fit pads to the exact width", W(fit("ab", 5)) === 5);
    ok("fit never splits a wide character", fit("日本語", 5) === "日本 ");
    ok("fit keeps a combining sequence whole", fit("e\u0301x", 1) === "e\u0301");
    ok("fit never exceeds the width", W(fit("😀😀😀", 5)) === 5);
    ok("fit strips ANSI before measuring", fit("\u001b[31mabcdef\u001b[0m", 3) === "abc");
    process.exit(bad ? 1 : 0);
  ' > "$ui_fix/clean.out" 2>&1
  ui_clean_rc=$?
  check "ui.ts clean/fit sanitise terminal text and grapheme widths" bash -c '
    test "$1" = 0 && grep -q "^ok  .*fit strips ANSI" "$2"
  ' _ "$ui_clean_rc" "$ui_fix/clean.out"

  ui_start uia 24 10; ui_narrow=$ui_pane; ui_narrow_tag=$ui_tag
  check "a 24x10 terminal still renders the roster" ui_wait "$ui_narrow" "› alpha"
  if [ -n "${UI_ARTIFACT_DIR:-}" ]; then
    tmux capture-pane -ep -J -t "$ui_narrow" > "$UI_ARTIFACT_DIR/T1-ui-narrow.capture.ansi.txt"
  fi
  ui_send "$ui_narrow" ui-fixture viewer q
  ui_wait_rc "$ui_narrow_tag.rc"
  check "  and q still exits 0 there" bash -c '
    test "$(cat "$1.rc")" = 0 && test "$(cat "$1.before")" = "$(cat "$1.after")"
  ' _ "$ui_narrow_tag"
fi

# --- bounded cleanup ----------------------------------------------------------
for ui_pair in $ui_panes; do
  ui_p=${ui_pair%:*}; ui_role=${ui_pair#*:}
  # A viewer that already quit gets a stray "q" at its shell prompt; a stuck
  # one gets the quit key, and every fixture pane is closed either way.
  [ "$ui_role" = viewer ] && ui_send "$ui_p" ui-fixture viewer q 2>/dev/null

  ui_kill "$ui_p" ui-fixture "$ui_role"
done
tmux kill-session -t "$ui_ts2" 2>/dev/null
"$CREW" -s uia down >/dev/null 2>&1
"$CREW" -s uib down >/dev/null 2>&1
"$CREW" -s uistale down >/dev/null 2>&1
ui_kill "$ui_fresh" ui-fixture reused 2>/dev/null || true
# Roles whose panes were re-pointed are no longer owned by the crew; close them.
ui_owns uistale "$stale_orig" stale && tmux kill-pane -t "$stale_orig" 2>/dev/null
ui_owns uistale "$gone_orig" gone && tmux kill-pane -t "$gone_orig" 2>/dev/null
