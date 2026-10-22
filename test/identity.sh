# Sourced by smoke.sh while its identity-check task still exists.
identity_task=$(cat "$CREW_HOME/identity-task")
identity_before=$(cksum "$D/board.tsv")
for identity_force in '' --force; do
  identity_err=$(env CREW_AGENT=impl CREW_SESSION=other TMUX_PANE=%999999 "$CREW" -s t task set "$identity_task" working $identity_force 2>&1)
  identity_rc=$?
  check "unresolved task update fails with or without force" test "$identity_rc" -ne 0
  check "unresolved task diagnostic names the failed identity check" bash -c 'case "$1" in *"cannot set"*"CREW_SESSION=other does not match crew t"*) exit 0;; *) exit 1;; esac' _ "$identity_err"
  check "unresolved task diagnostic gives a role recovery prefix" bash -c 'case "$1" in *"crew -s t whoami"*"CREW_SESSION=t CREW_AGENT=<your-role>"*) exit 0;; *) exit 1;; esac' _ "$identity_err"
done
check "unresolved task updates leave the board unchanged" test "$(cksum "$D/board.tsv")" = "$identity_before"
check "explicit per-call identity repairs a stale daemon pane" bash -c '
  CREW_SESSION=t CREW_AGENT=impl TMUX_PANE=%999999 "$1" -s t task set "$2" working &&
  test "$(awk -F "\t" -v id="$2" '\''$1==id{print $3}'\'' "$3/board.tsv")" = working
' _ "$CREW" "$identity_task" "$D"
