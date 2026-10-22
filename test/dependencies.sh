# Sourced by smoke.sh before its board reset; use only throwaway roles.
dep_a=$(as lead task add --to impl 'dependency A')
dep_b=$(as lead task add --to impl 'dependency B')
dep_single=$(as lead task add --to impl --dep "$dep_a" 'single dependency')
dep_multi=$(as lead task add --to rev --dep "$dep_a,$dep_b" 'multiple dependencies')
dep_blocked=$(as lead task add --to rev --dep "$dep_a,$dep_b" 'blocked dependent')
dep_missing=$(as lead task add --to rev --dep "$dep_a,T99999" 'missing dependency')
as rev task set "$dep_blocked" blocked
# Same-owner completion must work without crew send's self-send rejection.
CREW_SESSION=t CREW_AGENT=impl TMUX_PANE="$impl" "$CREW" task set "$dep_a" done --force > "$CREW_HOME/dependency-self-output"
check "completing a dependency notifies its same-owner successor" grep -qF "$dep_single is unblocked" "$D/inbox/impl.md"
check "a ready task stays queued until its owner starts" test "$(awk -F '\t' -v id="$dep_single" '$1==id{print $3}' "$D/board.tsv")" = queued
check "a multi-dependency task waits for every dependency" bash -c '! grep -qF "$1 is unblocked" "$2"' _ "$dep_multi" "$D/inbox/rev.md"
check "a missing dependency never counts as done" bash -c '! grep -qF "$1 is unblocked" "$2"' _ "$dep_missing" "$D/inbox/rev.md"
rev_dep_pane=$(awk -F '\t' '$1=="rev"{print $2}' "$D/panes")
tmux copy-mode -t "$rev_dep_pane"
CREW_RING_WAIT=0 as impl task set "$dep_b" done --force > "$CREW_HOME/dependency-mode-out" 2> "$CREW_HOME/dependency-mode-err"
check "last dependency sends one system notice to the owner inbox" test "$(grep -cF "$dep_multi is unblocked" "$D/inbox/rev.md")" = 1
check "dependency notice respects pane mode protection" grep -q 'copy/choose mode' "$CREW_HOME/dependency-mode-err"
check "blocked dependents are not automatically resumed" bash -c '! grep -qF "$1 is unblocked" "$2"' _ "$dep_blocked" "$D/inbox/rev.md"
as impl task set "$dep_b" done --force >/dev/null
check "repeating done does not repeat the unblock notice" test "$(grep -cF "$dep_multi is unblocked" "$D/inbox/rev.md")" = 1
tmux copy-mode -q -t "$rev_dep_pane"
# Concurrent predecessor completion must announce exactly one ready transition.
dep_c=$(as lead task add --to impl 'concurrent predecessor C')
dep_d=$(as lead task add --to impl 'concurrent predecessor D')
dep_race=$(as lead task add --to rev --dep "$dep_c,$dep_d" 'concurrent successor')
as impl task set "$dep_c" done --force >/dev/null & dep_c_pid=$!
as impl task set "$dep_d" done --force >/dev/null & dep_d_pid=$!
wait "$dep_c_pid"; wait "$dep_d_pid"
check "concurrent completions produce one unblock notice" test "$(grep -cF "$dep_race is unblocked" "$D/inbox/rev.md")" = 1
check "dependency notifications leave no board lock" test ! -d "$D/.board.lock"
