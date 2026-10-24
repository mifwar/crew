# Sourced by smoke.sh: `crew task cancel`. A cancelled task retains its row and
# id while leaving open work, without unblocking dependents or reopening.
# A scratch "project" directory, so a gate that writes a file cannot land in
# the crew repo.
mkdir -p "$CREW_HOME/w-project"
(cd "$CREW_HOME/w-project" && "$CREW" up w --in "$TS" --no-watch lead=cat impl=cat rev=cat >/dev/null 2>&1)
W="$CREW_HOME/w"
asw() { # role, then crew args — run crew as that agent in crew w
  local role="$1"; shift
  CREW_SESSION=w CREW_AGENT="$role" "$CREW" "$@"
}
w_state() { awk -F'\t' -v id="$1" '$1==id{print $3}' "$W/board.tsv"; }

c_done=$(asw lead task add --to impl "already finished")
printf 'STATUS: DONE\n' > "$W/out/$c_done-impl.md"
asw impl task set "$c_done" done >/dev/null
c_one=$(asw lead task add --to impl --out c-one.md "misread task")
c_dep=$(asw lead task add --to rev --dep "$c_one" "depends on the misread task")
cancel_out=$(asw lead task cancel "$c_one" --reason "misread the human" 2>&1)
check "cancel closes the task"                  test "$(w_state "$c_one")" = cancelled
check "cancel keeps the row, id and output path" awk -F'\t' -v id="$c_one" '$1==id && $5=="out/c-one.md"{f=1} END{exit !f}' "$W/board.tsv"
check "cancel logs the reason"                  grep -q "cancelled $c_one (was queued): misread the human" "$W/channel.log"
check "cancel keeps the 9-column board format"  test "$(awk -F'\t' -v id="$c_one" 'NR==1{n=NF} $1==id{n=NF} END{print n}' "$W/board.tsv")" = 9
check "cancel lists the dependent"              bash -c 'printf "%s" "$1" | grep -qF "$2"' _ "$cancel_out" "$c_dep"
check "  and names crew task dep"               bash -c 'printf "%s" "$1" | grep -qF "crew task dep"' _ "$cancel_out"
check "a cancelled task never unblocks its dependent" bash -c '! grep -qF "$1 is unblocked" "$2"' _ "$c_dep" "$W/inbox/rev.md"
check "the owner is told to stop"               grep -qF "$c_one is cancelled (misread the human)" "$W/inbox/impl.md"
check "cancelling twice says so and succeeds"   bash -c 'CREW_SESSION=w CREW_AGENT=lead "$1" task cancel "$2" 2>&1 | grep -q "already cancelled"' _ "$CREW" "$c_one"
check "a cancelled row cannot be set again"     bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task set "$2" done --force' _ "$CREW" "$c_one"
check "  and it stays cancelled"                test "$(w_state "$c_one")" = cancelled
check "task set refuses the cancelled status"   bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task set "$2" cancelled' _ "$CREW" "$c_dep"
check "a done task is not cancellable"          bash -c '! CREW_SESSION=w CREW_AGENT=lead "$1" task cancel "$2"' _ "$CREW" "$c_done"
check "a worker cannot cancel"                  bash -c '! CREW_SESSION=w CREW_AGENT=impl "$1" task cancel "$2"' _ "$CREW" "$c_dep"
check "refused cancels leave the row alone"     test "$(w_state "$c_dep")" = queued
check "cancel leaves no board lock"             test ! -e "$W/.board.lock"

# Cancelling work in flight: the owner must hear about it, and the task must
# stay closed even if the owner was already about to close it.
c_work=$(asw lead task add --to impl "in flight")
asw impl task set "$c_work" working >/dev/null
check "a working task can be cancelled"         asw lead task cancel "$c_work"
check "  the owner is told to stop"             grep -qF "$c_work is cancelled" "$W/inbox/impl.md"
check "  and a late done cannot resurrect it"   bash -c '! CREW_SESSION=w CREW_AGENT=impl "$1" task set "$2" done --force' _ "$CREW" "$c_work"
check "  so it stays cancelled"                 test "$(w_state "$c_work")" = cancelled

# A cancelled task must not run its gate: closing it again is refused up front.
c_gate=$(asw lead task add --to impl --out c-gate.md --gate "touch $W/gate-ran" "gated then cancelled")
asw lead task cancel "$c_gate" >/dev/null
check "an already-cancelled row does not run its gate" bash -c '! CREW_SESSION=w CREW_AGENT=impl "$1" task set "$2" done' _ "$CREW" "$c_gate"
check "  and it wrote no gate log"      test ! -e "$W/out/$c_gate-gate.log"
check "  and the gate command never ran" test ! -e "$W/gate-ran"

# The human at a terminal can cancel too.
c_human=$(asw lead task add --to impl "human cancels this")
check "you can cancel from a terminal"          human "$CREW" -s w task cancel "$c_human"
check "  and it is cancelled"                   test "$(w_state "$c_human")" = cancelled

# Ids: cancelling the highest task must not hand its number to the next add.
c_high=$(asw lead task add --to impl "highest so far")
asw lead task cancel "$c_high" >/dev/null
check "a cancelled id is not reused"            test "$(asw lead task next-id)" = "T$(( ${c_high#T} + 1 ))"
check "  and the next add takes the next number" test "$(asw lead task add --to impl "after cancel")" = "T$(( ${c_high#T} + 1 ))"

# Closed rows are not open work: ls and the watcher both count done+cancelled.
w_cancelled=$(awk -F'\t' '$3=="cancelled"{n++} END{print n+0}' "$W/board.tsv")
w_open=$(awk -F'\t' '$3!="done" && $3!="cancelled"{n++} END{print n+0}' "$W/board.tsv")
check "ls counts cancelled as closed"           bash -c '"$1" ls | grep -q "($2 open, $3 cancelled)"' _ "$CREW" "$w_open" "$w_cancelled"
watch_state() { # -> empty|open for the w board, using the sourced watcher rule
  bash -c '
    D="$1"; S=w
    die() { echo "$*" >&2; exit 1; }
    . "$2/watch.sh"; . "$3/tasks.sh"
    watch_board_state
  ' _ "$W" "$ROOT/share/crew" "$ROOT/share/crew"
}
printf 'T1\tlead\tdone\t-\tout/a.md\ta\t-\nT2\tlead\tcancelled\t-\tout/b.md\tb\t-\n' > "$W/board.tsv"
check "done+cancelled is an empty board for the watcher" test "$(watch_state)" = empty
printf 'T1\tlead\tqueued\t-\tout/a.md\ta\t-\nT5\tlead\tqueued\t-\tout/b.md\tb\t-\n' > "$W/board.tsv"
check "next-id is the max id + 1 when a row vanished"  test "$(asw lead task next-id)" = T6
