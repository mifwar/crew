# Sourced by smoke.sh, using its scratch home and detached tmux session.
. "$ROOT/share/crew/semaphore.sh"
check 'semaphore syntax (bash 3.2)' bash -n "$ROOT/share/crew/semaphore.sh"
check 'lock has command help' bash -c '"$1" lock --help | grep -q "crew lock"' _ "$CREW"
"$CREW" up sem-test --in "$TS" lead=cat worker=cat >/dev/null 2>&1
sem_dir="$CREW_HOME/sem-test"
sem_until() { local i=0
  until "$@" >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 100 ] || return 1; sleep 0.1; done
}
sem_file() { [ -f "$1" ]; }
sem_not_file() { [ ! -f "$1" ]; }
sem_empty() { local slot
  for slot in "$1"/slot.*; do [ ! -d "$slot" ] || return 1; done
}
for invalid in 0 0x -1 1.5 ''; do
  check "lock rejects capacity [$invalid]" bash -c '! "$1" -s sem-test lock --max "$2" -- true' _ "$CREW" "$invalid"
done
check 'lock rejects unsafe namespace' bash -c '! "$1" -s sem-test lock --name ../out -- true' _ "$CREW"
check 'lock requires command separator' bash -c '! "$1" -s sem-test lock true' _ "$CREW"
check 'lock requires a command' bash -c '! "$1" -s sem-test lock --' _ "$CREW"
check 'lock preserves command exit status' bash -c '"$1" -s sem-test lock --name failure -- sh -c "exit 7"; [ "$?" = 7 ]' _ "$CREW"
check 'failed command releases slot' sem_empty "$sem_dir/locks/failure"
check 'lock preserves argument boundaries' bash -c '[ "$("$1" -s sem-test lock --name args -- printf "<%s><%s>" "a b" "\$(literal)")" = "<a b><\$(literal)>" ]' _ "$CREW"
check 'lock preserves standard input' bash -c '[ "$(printf input-data | "$1" -s sem-test lock --name stdin -- cat)" = input-data ]' _ "$CREW"
check 'lock preserves standard error' bash -c '"$1" -s sem-test lock --name stderr -- sh -c "echo command-stderr >&2" 2> "$2" && grep -q command-stderr "$2"' _ "$CREW" "$CREW_HOME/sem-stderr"

# Two held jobs prove capacity two; a third must wait until release.
sem_fixture="$CREW_HOME/sem-job.sh"
cat > "$sem_fixture" <<'SH'
#!/bin/sh
printf 'start %s\n' "$2" >> "$1/events"
if [ "$3" = gate ]; then
  touch "$1/ready-$2"
  while [ ! -f "$1/release" ]; do sleep 0.1; done
else sleep 0.3; fi
printf 'end %s\n' "$2" >> "$1/events"
SH
sem_jobs="$CREW_HOME/sem-jobs"; mkdir "$sem_jobs"
"$CREW" -s sem-test lock --name parallel --max 2 -- sh "$sem_fixture" "$sem_jobs" one gate > "$CREW_HOME/sem-one" 2>&1 & sem_one=$!
"$CREW" -s sem-test lock --name parallel --max 2 -- sh "$sem_fixture" "$sem_jobs" two gate > "$CREW_HOME/sem-two" 2>&1 & sem_two=$!
check 'capacity two admits two simultaneous jobs' sem_until bash -c '[ -f "$1/ready-one" ] && [ -f "$1/ready-two" ]' _ "$sem_jobs"
"$CREW" -s sem-test lock --name parallel --max 2 -- sh "$sem_fixture" "$sem_jobs" three quick > "$CREW_HOME/sem-three" 2>&1 & sem_three=$!
check 'excess contender reports waiting' sem_until grep -q 'waiting for lock parallel' "$CREW_HOME/sem-three"
check 'third command does not run while capacity is held' bash -c '! grep -q "start three" "$1/events"' _ "$sem_jobs"
"$CREW" -s sem-test status > "$CREW_HOME/sem-status"
check 'status shows current lock holders' grep -q 'LOCK HOLDERS' "$CREW_HOME/sem-status"
check 'status shows both holder pids' bash -c 'grep -q "$1" "$3" && grep -q "$2" "$3"' _ "$sem_one" "$sem_two" "$CREW_HOME/sem-status"
check 'conflicting capacity is rejected' bash -c '! "$1" -s sem-test lock --name parallel --max 1 -- true' _ "$CREW"
check 'separate namespace runs independently' "$CREW" -s sem-test lock --name other -- true
touch "$sem_jobs/release"
check 'first held job finishes' wait "$sem_one"
check 'second held job finishes' wait "$sem_two"
check 'waiting job eventually runs' wait "$sem_three"
sem_pids=""
for n in 1 2 3 4 5 6 7 8; do
  "$CREW" -s sem-test lock --name parallel --max 2 -- sh "$sem_fixture" "$sem_jobs" "burst$n" quick > "$CREW_HOME/sem-burst$n" 2>&1 & sem_pids="$sem_pids $!"
done
for sem_pid in $sem_pids; do check 'burst contender completes' wait "$sem_pid"; done
check 'parallel jobs never exceed capacity and all complete' awk '
  $1=="start" {active++; starts++; if (active>peak) peak=active; if (active>2) bad=1}
  $1=="end" {active--; if (active<0) bad=1}
  END {exit bad || active!=0 || peak!=2 || starts!=11}' "$sem_jobs/events"
check 'all completed slots are removed' sem_empty "$sem_dir/locks/parallel"

# A living owner with unpublished metadata is reserved, never falsely reaped.
sem_public="$sem_dir/locks/publication"; mkdir -p "$sem_public/slot.$$.pending"
printf '1\n' > "$sem_public/max"
"$CREW" -s sem-test lock --name publication -- touch "$CREW_HOME/sem-published" > "$CREW_HOME/sem-publication" 2>&1 & sem_public_pid=$!
check 'unpublished live reservation blocks contenders' sem_until grep -q 'waiting for lock publication' "$CREW_HOME/sem-publication"
check 'unpublished reservation is kept' test -d "$sem_public/slot.$$.pending"
check 'blocked command remains unstarted' sem_not_file "$CREW_HOME/sem-published"
rmdir "$sem_public/slot.$$.pending"
check 'publication contender runs after release' wait "$sem_public_pid"

# Recovery removes dead and reused-pid leases; it never signals their pids.
sem_stale="$sem_dir/locks/stale"; mkdir -p "$sem_stale/slot.99999999.dead" "$sem_stale/slot.$$.reused"
printf '1\n' > "$sem_stale/max"
printf '99999999\told start\tworker\tstale-command\n' > "$sem_stale/slot.99999999.dead/owner"
printf '%s\told start\tworker\tstale-command\n' "$$" > "$sem_stale/slot.$$.reused/owner"
check 'dead and reused pid slots recover' "$CREW" -s sem-test lock --name stale -- true
check 'recovery removes dead slots' sem_empty "$sem_stale"
check 'reused pid process is never signalled' kill -0 "$$"

# Signal handling stops the direct command before releasing its slot.
CREW_SESSION=sem-test CREW_AGENT=worker "$CREW" lock -- sleep 30 > "$CREW_HOME/sem-holder" 2>&1 & sem_holder=$!
sem_holder_shown() {
  "$CREW" -s sem-test status > "$CREW_HOME/sem-current-status"
  grep -q "build.*$sem_holder.*worker.*sleep 30" "$CREW_HOME/sem-current-status"
}
check 'default capacity holder appears with role and command' sem_until sem_holder_shown
"$CREW" -s sem-test lock -- touch "$CREW_HOME/sem-never-start" > "$CREW_HOME/sem-waiter" 2>&1 & sem_waiter=$!
check 'default capacity serializes commands' sem_until grep -q 'waiting for lock build' "$CREW_HOME/sem-waiter"
kill -TERM "$sem_waiter"
sem_rc=0; wait "$sem_waiter" 2>/dev/null || sem_rc=$?
check 'waiting interruption returns signal status' test "$sem_rc" = 143
check 'interrupted waiter never runs its command' sem_not_file "$CREW_HOME/sem-never-start"
kill -TERM "$sem_holder"
sem_rc=0; wait "$sem_holder" 2>/dev/null || sem_rc=$?
check 'holding interruption returns signal status' test "$sem_rc" = 143
check 'interrupted holder releases slot' sem_empty "$sem_dir/locks/build"
check 'semaphore can be reacquired after interruption' "$CREW" -s sem-test lock -- true
"$CREW" -s sem-test down >/dev/null 2>&1
check 'ended crew rejects locked commands' bash -c '! "$1" -s sem-test lock -- true' _ "$CREW"
