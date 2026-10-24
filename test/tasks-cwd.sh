# Sourced by smoke.sh: per-worker working directories (`crew add --cwd`,
# `crew task add --cwd`). A second worktree must not let a gate pass against the
# crew's own tree, and a task that changes hands must keep its directory.
asw() { # role, then crew args — crew w comes from test/tasks-cancel.sh
  local role="$1"; shift
  CREW_SESSION=w CREW_AGENT="$role" "$CREW" "$@"
}
W="$CREW_HOME/w"
phys() { (cd "$1" && pwd -P); }   # tmux and agent CLIs report physical paths
crew_dir=$(awk -F'=' '$1=="cwd"{sub(/^cwd=/, ""); print}' "$W/meta")
wt_raw="$CREW_HOME/wt feat"; mkdir -p "$wt_raw"
wt=$(phys "$wt_raw")
w_cwd() { awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$W/cwd.tsv" 2>/dev/null; }

asw lead add --cwd "$wt_raw" w1=cat >/dev/null 2>&1
w1_pane=$(awk -F'\t' '$1=="w1"{print $2}' "$W/panes")
check "add --cwd records the role directory"  test "$(w_cwd w1)" = "$wt"
check "add --cwd starts the pane there"       test "$(tmux display -p -t "$w1_pane" '#{pane_current_path}')" = "$wt"
check "a role without --cwd stays on the crew dir" test -z "$(w_cwd impl)"
check "add --cwd rejects a missing directory" bash -c '! "$1" -s w add --cwd "$2/missing" w9=cat' _ "$CREW" "$CREW_HOME"
check "  and adds no role"                    bash -c '! awk -F"\t" "\$1==\"w9\"{f=1} END{exit !f}" "$1/panes"' _ "$W"

# A gate runs in the owner's directory: a marker in the crew tree must not
# satisfy a worktree gate (the failure this feature exists to prevent).
w_gate=$(asw lead task add --to w1 --out wt.md --gate "pwd > gate-pwd; test -f marker" "worktree gate")
check "task add snapshots the owner directory" awk -F'\t' -v id="$w_gate" -v d="$wt" '$1==id && $9==d{f=1} END{exit !f}' "$W/board.tsv"
printf 'STATUS: DONE\n' > "$W/out/wt.md"
: > "$crew_dir/marker"
check "a crew-dir marker does not satisfy a worktree gate" bash -c '! CREW_SESSION=w CREW_AGENT=w1 "$1" task set "$2" done' _ "$CREW" "$w_gate"
check "  and the gate log names the worktree" grep -qF "$wt" "$W/out/$w_gate-gate.log"
rm -f "$crew_dir/marker"; : > "$wt/marker"
check "the worktree gate passes in its own tree" asw w1 task set "$w_gate" done
check "  and pwd was the worktree"            test "$(cat "$wt/gate-pwd")" = "$wt"
check "the gate log records the directory first" grep -qF "# cwd $wt" "$W/out/$w_gate-gate.log"

# task add --cwd overrides the owner's directory for that one task.
other_raw="$CREW_HOME/wt-other"; mkdir -p "$other_raw"; other=$(phys "$other_raw"); : > "$other/marker"
w_ov=$(asw lead task add --to w1 --cwd "$other_raw" --out ov.md --gate "pwd > ov-pwd; test -f marker" "override gate")
check "task add --cwd wins over the owner directory" awk -F'\t' -v id="$w_ov" -v d="$other" '$1==id && $9==d{f=1} END{exit !f}' "$W/board.tsv"
printf 'STATUS: DONE\n' > "$W/out/ov.md"
check "the override gate runs there"          asw w1 task set "$w_ov" done
check "  and pwd was the override directory"  test "$(cat "$other/ov-pwd")" = "$other"
check "only lead may set a task --cwd"        bash -c '! CREW_SESSION=w CREW_AGENT=impl "$1" task add --to w1 --cwd "$2" nope' _ "$CREW" "$wt_raw"
check "task --cwd rejects a missing directory" bash -c '! "$1" -s w task add --to w1 --cwd "$2/missing" nope' _ "$CREW" "$CREW_HOME"

# An override hands the replacement's unfinished tasks to the role. The task
# keeps the directory it was added with, not the directory of its new owner.
w_mv=$(asw lead task add --to rev --out mv.md --gate "pwd > mv-pwd" "moves to w1")
printf 'STATUS: DONE\n' > "$W/out/mv.md"
w_closed=$(asw lead task add --to rev "cancelled history before override")
asw lead task cancel "$w_closed" >/dev/null
# Native IDs are synthetic: these owned cat panes need no real provider call.
awk -F'\t' -v OFS='\t' '$1=="w1" || $1=="rev" {$3="pi"} {print}' "$W/panes" > "$W/panes.next"
mv "$W/panes.next" "$W/panes"
asw lead session w1 worktree-session >/dev/null
asw lead session rev crew-session >/dev/null
asw lead override w1 rev >/dev/null 2>&1
check "override moves the replacement's unfinished task" awk -F'\t' -v id="$w_mv" '$1==id && $2=="w1"{f=1} END{exit !f}' "$W/board.tsv"
check "  and keeps the directory it was added with" awk -F'\t' -v id="$w_mv" -v d="$crew_dir" '$1==id && $9==d{f=1} END{exit !f}' "$W/board.tsv"
check "the transferred task's gate runs in its original directory" asw w1 task set "$w_mv" done
check "  and pwd was that directory, not the worktree" test "$(cat "$crew_dir/mv-pwd")" = "$crew_dir"
check "override moves the worktree directory with its pane" test "$(w_cwd rev)" = "$wt"
check "  the other role falls back to the crew directory" test -z "$(w_cwd w1)"
check "override preserves cancelled history's owner" awk -F'\t' -v id="$w_closed" '$1==id && $2=="rev" && $3=="cancelled"{f=1} END{exit !f}' "$W/board.tsv"
check "override keeps the native worktree session usable" test "$(asw lead session rev)" = worktree-session
check "  and keeps the crew-directory session usable" test "$(asw lead session w1)" = crew-session
check "handover names the successor's actual directory" grep -qF "Working directory for w1: $crew_dir" "$W"/out/override-w1-*.md
w_after=$(asw lead task add --to rev --out after-swap.md --gate 'pwd > after-swap-pwd; test -f marker' 'new task after override')
printf 'STATUS: DONE\n' > "$W/out/after-swap.md"
check "new tasks after a swap gate in the new owner's tree" asw rev task set "$w_after" done
check "  and use that worktree rather than the old role's" test "$(cat "$wt/after-swap-pwd")" = "$wt"

# Paths with spaces and backslashes must survive the record unfiltered.
odd_raw="$CREW_HOME/wt odd/back\\slash"; mkdir -p "$odd_raw"; odd=$(phys "$odd_raw")
asw lead add --cwd "$odd_raw" w2=cat >/dev/null 2>&1
check "a directory with a space and a backslash round-trips" test "$(w_cwd w2)" = "$odd"
w2_pane=$(awk -F'\t' '$1=="w2"{print $2}' "$W/panes")
check "  and its pane starts there"           test "$(tmux display -p -t "$w2_pane" '#{pane_current_path}')" = "$odd"
tab_dir=$(printf '%s/tab\there' "$CREW_HOME"); mkdir -p "$tab_dir"
check "a symlinked --cwd is recorded as its target" bash -c '
  ln -s "$1" "$2/link" && CREW_SESSION=w CREW_AGENT=lead "$3" add --cwd "$2/link" w4=cat >/dev/null 2>&1' _ "$wt_raw" "$CREW_HOME" "$CREW"
check "  recorded path is the physical one"   test "$(w_cwd w4)" = "$wt"
check "a directory with a tab is rejected"     bash -c '! "$1" -s w add --cwd "$2" w8=cat' _ "$CREW" "$tab_dir"
check "  and adds no role"                     bash -c '! awk -F"\t" "\$1==\"w8\"{f=1} END{exit !f}" "$1/panes"' _ "$W"
newline_dir="${CREW_HOME}/trailing-newline"$'\n'
mkdir -p "$newline_dir"
check "a physical directory ending in newline is rejected" bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" add --cwd "$2" wnewline=cat' _ "$CREW" "$newline_dir"
check "task --cwd also rejects that directory" bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task add --to rev --cwd "$2" bad-path' _ "$CREW" "$newline_dir"
check "an empty add --cwd is rejected" bash -c '! "$1" -s w add --cwd "" wempty=cat' _ "$CREW"
check "an empty task --cwd is rejected" bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task add --to rev --cwd "" empty-path' _ "$CREW"

# Removing a role drops its recorded directory.
asw lead remove w2 >/dev/null 2>&1
check "remove forgets the role directory"     test -z "$(w_cwd w2)"
check "  and the other roles keep theirs"     test "$(w_cwd rev)" = "$wt"
