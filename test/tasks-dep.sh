# Sourced by smoke.sh: `crew task dep`. Editing dependencies must be lead/you
# only, reject unknown ids, self-dependencies and cycles, and notify a queued
# owner exactly once when the edit removes the last unmet prerequisite.
asw() { # role, then crew args — crew w comes from test/tasks-cancel.sh
  local role="$1"; shift
  CREW_SESSION=w CREW_AGENT="$role" "$CREW" "$@"
}
W="$CREW_HOME/w"
: > "$W/board.tsv"
d_state() { awk -F'\t' -v id="$1" '$1==id{print $3}' "$W/board.tsv"; }
d_deps() { awk -F'\t' -v id="$1" '$1==id{print $4}' "$W/board.tsv"; }

d_a=$(asw lead task add --to impl "prereq A")
d_b=$(asw lead task add --to impl "prereq B")
d_c=$(asw lead task add --to rev --dep "$d_a,$d_b" "waits for both")
asw impl task set "$d_a" done --force >/dev/null
check "one missing prerequisite keeps the task waiting" test "$(d_deps "$d_c")" = "$d_a,$d_b"
check "  and no unblock notice was sent yet" bash -c '! grep -qF "$1 is unblocked" "$2"' _ "$d_c" "$W/inbox/rev.md"
check "editing deps is lead/you only"   bash -c '! CREW_SESSION=w CREW_AGENT=impl "$1" task dep "$2" -' _ "$CREW" "$d_c"
check "dep leaves a refused task alone"  test "$(d_deps "$d_c")" = "$d_a,$d_b"
dep_out=$(asw lead task dep "$d_c" "$d_a" 2>&1)
check "dep rewrites the dependency list" test "$(d_deps "$d_c")" = "$d_a"
check "removing the last unmet dep unblocks the owner once" grep -qF "$d_c is unblocked" "$W/inbox/rev.md"
check "  and says which ids it now needs" bash -c 'printf "%s" "$1" | grep -qF "$2"' _ "$dep_out" "$d_a"
check "  the task is still queued until its owner starts" test "$(d_state "$d_c")" = queued
asw lead task dep "$d_c" "$d_a" >/dev/null
check "repeating the same deps is quiet" test "$(grep -cF "$d_c is unblocked" "$W/inbox/rev.md")" = 1
check "clearing deps is quiet once it is already ready" asw lead task dep "$d_c" -
check "  and the row shows no dependencies" test "$(d_deps "$d_c")" = "-"
check "clearing did not repeat the notice" test "$(grep -cF "$d_c is unblocked" "$W/inbox/rev.md")" = 1
check "dep rejects an unknown task"      bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" T99999' _ "$CREW" "$d_c"
check "dep rejects an unknown target"    bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep T99999 -' _ "$CREW"
check "dep rejects a malformed id"       bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" T1x' _ "$CREW" "$d_c"
check "dep rejects a self dependency"    bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" "$2"' _ "$CREW" "$d_c"
check "dep rejects an empty list"        bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" ""' _ "$CREW" "$d_c"
check "dep normalises spaces and duplicates" asw lead task dep "$d_c" " $d_a , $d_a "
check "  and stores one id"              test "$(d_deps "$d_c")" = "$d_a"
# Cycles: e_y → e_x exists, so e_x → e_y must be refused and named.
e_x=$(asw lead task add --to impl "cycle X")
e_y=$(asw lead task add --to impl "cycle Y")
check "dep accepts a one-way dependency" asw lead task dep "$e_y" "$e_x"
check "  stored on the row"              test "$(d_deps "$e_y")" = "$e_x"
cycle=$(asw lead task dep "$e_x" "$e_y" 2>&1 || true)
check "dep refuses a cycle"              bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" "$3"' _ "$CREW" "$e_x" "$e_y"
check "  and names the loop"             bash -c 'printf "%s" "$1" | grep -qF "$2 → $3"' _ "$cycle" "$e_y" "$e_x"
check "  and the refused row keeps its deps" test "$(d_deps "$e_x")" = "-"
e_done=$(asw lead task add --to impl "closed already")
asw lead task set "$e_done" done --force >/dev/null
check "dep refuses a closed task"        bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task dep "$2" -' _ "$CREW" "$e_done"
check "dep leaves no board lock"         test ! -e "$W/.board.lock"
