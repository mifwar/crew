# Sourced by bin/crew; board transitions are computed under its board lock.
task_unblocked_by() { # completed id -> queued task id<TAB>owner; read the pre-update board
  awk -F '\t' -v completed="$1" '
    { status[$1]=$3; id[NR]=$1; owner[NR]=$2; state[NR]=$3; deps[NR]=$4 }
    END {
      if (status[completed] == "done") exit
      for (i=1; i<=NR; i++) {
        if (state[i] != "queued") continue
        n=split(deps[i], dep, ","); affected=0; ready=1
        for (j=1; j<=n; j++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", dep[j])
          if (dep[j] == completed) affected=1
          else if (status[dep[j]] != "done") ready=0
        }
        if (affected && ready) printf "%s\t%s\n", id[i], owner[i]
      }
    }' "$D/board.tsv"
}

task_notify_ready() { # task id<TAB>owner rows; called only after publishing and unlocking
  local id owner text ME=system
  [ -n "$1" ] || return 0
  while IFS="$(printf '\t')" read -r id owner; do
    text="$id is unblocked: all dependencies are done. Read crew -s $S board and proceed with your assigned task."
    log_line dm "$ME" "$owner" "$text"
    deliver "$owner" "$text" "$owner"
  done <<< "$1"
}
