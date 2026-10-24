# Sourced by bin/crew; board rules, task commands and readiness notices.
# cmd_task lives here so bin/crew does not grow another two hundred lines.

# A task is open until it is done or cancelled. Only `done` ever satisfies a
# dependency: cancelled is closed, not completed, so a dependent keeps waiting
# until the lead re-points it with `crew task dep <id> <T…|->`. Cancelled rows
# stay in board.tsv so their id is never handed to a later task.
TASK_CLOSED_RE='^(done|cancelled)$'

task_row() { # id field → that column; empty when the id or the column is absent
  awk -F '\t' -v id="$1" -v f="$2" '$1==id {print $f; exit}' "$D/board.tsv"
}

task_next_id() { # -> T<highest existing numeric id + 1>, so ids only move forward
  local max
  max=$(awk -F '\t' '$1 ~ /^T[0-9]+$/ {n = substr($1, 2) + 0; if (n > max) max = n}
    END {printf "%d", max + 0}' "$D/board.tsv" 2>/dev/null) || max=0
  printf 'T%d\n' "$((max + 1))"
}

task_gate_cwd() { # id owner → directory that task's gate runs in
  local dir
  dir=$(task_row "$1" 9)
  case "$dir" in ''|-) dir=$(role_cwd "$2") ;; esac
  printf '%s' "$dir"
}

task_dep_cycle() { # id dep → "dep → … → id" when id depending on dep would close a loop
  awk -F '\t' -v id="$1" -v dep="$2" '
    { deps[$1] = $4 }
    END {
      head = 1; tail = 1; queue[1] = dep; seen[dep] = 1
      while (head <= tail) {
        cur = queue[head]; head++
        if (cur == id) {
          chain = id; node = cur
          while (node != dep) { node = parent[node]; chain = node " → " chain }
          print chain; exit
        }
        n = split(deps[cur], parts, ",")
        for (i = 1; i <= n; i++) {
          p = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
          if (p == "" || p == "-" || (p in seen)) continue
          seen[p] = 1; parent[p] = cur; tail++; queue[tail] = p
        }
      }
    }' "$D/board.tsv"
}

task_dep_ready() { # id new-deps → "id<TAB>owner" when the edit leaves every dep done
  awk -F '\t' -v id="$1" -v deps="$2" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function all_done(list,   n, i, p) {
      if (list == "" || list == "-") return 1
      n = split(list, parts, ",")
      for (i = 1; i <= n; i++) {
        p = trim(parts[i])
        if (p == "") continue
        if (status[p] != "done") return 0
      }
      return 1
    }
    { status[$1] = $3; owner[$1] = $2; olddeps[$1] = $4 }
    END {
      if (status[id] != "queued") exit   # only queued work gets an unblock notice
      if (all_done(olddeps[id])) exit    # it was already ready: nothing changed
      if (all_done(deps)) printf "%s\t%s\n", id, owner[id]
    }' "$D/board.tsv"
}

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

task_notify_cancel() { # id owner reason
  local id="$1" owner="$2" reason="$3" text ME=system
  text="$id is cancelled${reason:+ ($reason)}. Stop work on it and leave its result file untouched; ask lead what to do next."
  log_line dm "$ME" "$owner" "$text"
  deliver "$owner" "$text" "$owner"
}

# ---------- crew task ----------

cmd_task() {
  resolve_session; resolve_me
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      local to="" dep="" msg="" title="" out="" gate="" cwd=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --to) to="$2"; shift 2 ;;
          --dep) dep="$2"; shift 2 ;;
          --msg) msg="$2"; shift 2 ;;
          --out) out="$2"; shift 2 ;;
          --gate) gate="$(oneline "$2")"; shift 2 ;;
          --cwd) [ $# -ge 2 ] && [ -n "$2" ] || die '--cwd needs a directory'; cwd="$2"; shift 2 ;;
          *) title="${title:+$title }$1"; shift ;;
        esac
      done
      [ -n "$to" ] && [ -n "$title" ] || die 'usage: crew task add --to <role> [--dep T1] [--out out/x.md] [--gate "<cmd>"] [--cwd <dir>] [--msg ..] <title>'
      [ -n "$(pane_of "$to")" ] || die "no agent '$to'"
      # A gate runs shell commands, so only lead or you may plant one.
      [ -z "$gate" ] || [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can set a --gate"
      # --cwd decides where that gate runs; it is the same kind of lever.
      if [ -n "$cwd" ]; then
        [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can set a task --cwd"
        cwd=$(resolve_cwd_arg --cwd "$cwd")
      fi
      # A rendered role file can carry the explicit review-only marker. A task
      # whose title or --msg names review work is what that role is for; warn
      # only on the rest, so the guard doesn't become noise that gets tuned out.
      if grep -q 'crew:review-only' "$D/roles/$to.md" 2>/dev/null; then
        case " $(printf '%s %s' "$title" "$msg" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ') " in
          *" review "*|*" verdict "*|*" audit "*) ;;
          *) echo "crew: $to is marked review-only; the task was added anyway" >&2 ;;
        esac
      fi
      lock board
      local id
      id=$(task_next_id)
      # {id} lets a brief name its own result file before the id exists.
      out=${out//\{id\}/$id}; msg=${msg//\{id\}/$id}
      # --out names the one result file (inside the crew's out/), so a task
      # message never offers two paths.
      case "$out" in ""|out/*) ;; */*) die "--out must be out/<name>.md" ;; *) out="out/$out" ;; esac
      [ -z "$out" ] || printf '%s' "$out" | grep -Eq '^out/[A-Za-z0-9._-]+\.md$' || die "--out must be out/<name>.md"
      [ -n "$out" ] || out="out/$id-$to.md"
      # Snapshot the directory this task belongs to, so a later override, rebind
      # or a later add cannot move an existing task's gate into another tree.
      [ -n "$cwd" ] || cwd=$(role_cwd "$to")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$to" queued "${dep:--}" "$out" "$(oneline "$title")" - "${gate:--}" "${cwd:--}" >> "$D/board.tsv"
      unlock
      log_line sys "$ME" "$to" "$ME added $id → $to: $title"
      set_pane_status "$to" "$id queued"
      cmd_send "$to" "$id for you: $title${dep:+ (needs $dep)}${msg:+ — ${msg%.}}. Write $D/$out (not in your working directory), then: crew task set $id done [--evidence <file>] && crew send lead \"$id done\"" >/dev/null
      echo "$id" ;;
    set)
      [ $# -ge 2 ] || die 'usage: crew task set <id> <status> [--out <file>] [--evidence <file>] [--force]'
      local id="$1" st="$2" out="" ev="" force=""; shift 2
      while [ $# -gt 0 ]; do
        case "$1" in
          --out) out="$(oneline "$2")"; shift 2 ;;
          --evidence) ev="$(oneline "$2")"; shift 2 ;;
          --force) force=1; shift ;;
          *) die "bad option: $1" ;;
        esac
      done
      case "$st" in
        queued|working|done|blocked|needs-input) ;;
        # Cancelling also has to list dependents and is lead/you only, so it has
        # its own command; keeping one path means no worker finds a loophole.
        cancelled|canceled) die "$id is closed with 'crew task cancel $id' (lead or you), not 'task set'" ;;
        *) die "bad status: $st" ;;
      esac
      [ "$ME" != outside ] || die "cannot set $id as outside: $WHY; run crew -s $S whoami. If your tool shell inherited a dead/foreign pane, prefix crew calls with CREW_SESSION=$S CREW_AGENT=<your-role> and verify whoami first."
      # Cancelled is terminal. Two checks on purpose: this one refuses before
      # a slow gate could run for a task that cancel already closed, and its
      # twin inside the board lock below sees a cancel that lands while the
      # gate runs (task set → done and task cancel are concurrent).
      case "$(task_row "$id" 3)" in
        cancelled) die "$id is cancelled and stays closed; add a new task instead (see crew log for the reason)" ;;
      esac
      # A gate command runs before the lock (it can be slow) and only for a caller
      # the owner (so it runs in the owner's own shell); its output is the evidence unless one is given.
      if [ "$st" = done ] && [ -z "$force" ]; then
        local gcmd gowner gcwd glog grc=0
        gcmd=$(task_row "$id" 8)
        gowner=$(task_row "$id" 2)
        if [ -n "$gcmd" ] && [ "$gcmd" != - ] && [ "$ME" != "$gowner" ]; then
          die "$id has a gate; its owner runs it with 'task set $id done', or pass --force"
        fi
        if [ -n "$gcmd" ] && [ "$gcmd" != - ]; then
          gcwd=$(task_gate_cwd "$id" "$gowner")
          [ -d "$gcwd" ] || die "$id stays open: its gate directory is missing: $gcwd (the worktree may be gone; recreate it, or --force)"
          glog="out/$id-gate.log"
          printf '# cwd %s\n$ %s\n' "$gcwd" "$gcmd" > "$D/$glog"
          (cd "$gcwd" && bash -c "$gcmd") >> "$D/$glog" 2>&1 || grc=$?
          printf '[exit %s]\n' "$grc" >> "$D/$glog"
          [ -n "$ev" ] || ev="$glog"
          [ "$grc" -eq 0 ] || die "$id stays open: gate '$gcmd' exited $grc in $gcwd (output: $D/$glog); fix it or --force"
        fi
      fi
      lock board
      resolve_me
      local ready_notices="" owner rowout last; owner=$(task_row "$id" 2)
      [ -n "$owner" ] || die "no task $id"
      # The pre-lock twin of the cancelled check above, and the one that is
      # permissive: a cancel that landed while the gate ran closes the task
      # here, inside the lock, so the gate's exit cannot resurrect it.
      case "$(task_row "$id" 3)" in
        cancelled) die "$id is cancelled and stays closed; add a new task instead (see crew log for the reason)" ;;
      esac
      # Advisory like sender labels: catches a worker closing someone else's task.
      [ "$ME" = "$owner" ] || [ "$ME" = lead ] || [ "$ME" = you ] || die "$id is $owner's; only $owner, lead or you can set it (caller: $ME; $WHY; see crew -s $S whoami)"
      # done needs the named result file to say so; --force is the logged escape
      # hatch, so a task can't be closed on a missing or blocked result.
      if [ "$st" = done ] && [ -z "$force" ]; then
        rowout=$(task_row "$id" 5)
        [ -n "$out" ] || out="$rowout"
        [ -n "$out" ] && [ "$out" != - ] || die "$id stays open: no result file; pass --out or --force"
        [ -f "$D/$out" ] || die "$id stays open: $D/$out does not exist (write the result, or --force)"
        # CRLF files: drop the trailing CR so the blank test and the prefix
        # match see the line, not a carriage return.
        last=$(awk '{sub(/\r$/,"")} $0 !~ /^[[:space:]]*$/ {l=$0} END{print l}' "$D/$out")
        case "$last" in
          'STATUS: DONE'*|'FINAL:'*) ;;
          'STATUS:'*) die "$id stays open: $out ends with '$last'; fix the result or --force" ;;
          '') die "$id stays open: $out has no result line; write 'STATUS: DONE …' or use --force" ;;
          *) die "$id stays open: $out's last line is not 'STATUS: DONE' or 'FINAL: …'; --force to override" ;;
        esac
      fi
      [ "$st" != done ] || ready_notices=$(task_unblocked_by "$id")
      awk -F'\t' -v OFS='\t' -v id="$id" -v st="$st" -v out="$out" -v ev="$ev" \
        '$1==id{$3=st; if(out!="") $5=out; if(ev!="") $7=ev; else if($7=="") $7="-"} {print}' "$D/board.tsv" > "$D/board.tsv.tmp"
      mv "$D/board.tsv.tmp" "$D/board.tsv"
      unlock
      set_pane_status "$owner" "$id $st"
      log_line sys "$ME" - "$ME set $id → $st${out:+ ($out)}${ev:+ evidence: $ev}${force:+ [forced]}"
      task_notify_ready "$ready_notices" ;;
    cancel)
      local id="" reason=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --reason) [ $# -ge 2 ] || die '--reason needs a text'; reason="$(oneline "$2")"; shift 2 ;;
          -*) die "bad option: $1" ;;
          *) [ -z "$id" ] || die "unexpected argument: $1"; id="$1"; shift ;;
        esac
      done
      [ -n "$id" ] || die 'usage: crew task cancel <id> [--reason "<text>"]'
      [ "$ME" != outside ] || die "cannot cancel $id as outside: $WHY; run crew -s $S whoami"
      [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can cancel a task (caller: $ME; see crew -s $S whoami)"
      lock board
      resolve_me
      [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can cancel a task (caller: $ME; $WHY)"
      local owner was dependents
      owner=$(task_row "$id" 2); was=$(task_row "$id" 3)
      [ -n "$owner" ] || die "no task $id"
      case "$was" in
        cancelled) unlock; echo "$id is already cancelled"; return 0 ;;
        done) die "$id is done: cancel closes open tasks, and done history stays as it is" ;;
      esac
      awk -F'\t' -v OFS='\t' -v id="$id" '$1==id{$3="cancelled"} {print}' "$D/board.tsv" > "$D/board.tsv.tmp"
      mv "$D/board.tsv.tmp" "$D/board.tsv"
      # Dependents keep naming the id: it stays closed, never satisfied.
      dependents=$(awk -F'\t' -v id="$id" '
        { n=split($4, d, ","); for (i=1; i<=n; i++) { p=d[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); if (p==id) { printf "%s\t%s\t%s\n", $1, $3, $2; next } } }' "$D/board.tsv")
      unlock
      set_pane_status "$owner" "$id cancelled"
      log_line sys "$ME" "$owner" "$ME cancelled $id (was $was)${reason:+: $reason}"
      task_notify_cancel "$id" "$owner" "$reason"
      echo "$id cancelled (was $was)"
      if [ -n "$dependents" ]; then
        printf 'dependents still name %s; cancellation never satisfies them. Re-point with crew task dep <id> <T…|->:\n' "$id"
        printf '%s\n' "$dependents" | while IFS="$(printf '\t')" read -r d st o; do
          printf '  %s (%s, %s)\n' "$d" "$st" "$o"
        done
      fi ;;
    dep)
      [ $# -ge 2 ] || die 'usage: crew task dep <id> <T1,T2|->'
      local id="$1" spec="$2" deps="" list="" d chain ready
      shift 2
      [ $# -eq 0 ] || die "unexpected argument: $1"
      [ "$ME" != outside ] || die "cannot edit $id's dependencies as outside: $WHY; run crew -s $S whoami"
      [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can change dependencies (caller: $ME; see crew -s $S whoami)"
      case "$spec" in
        -) deps="-" ;;
        '') die "no task ids given (use '-' to clear the dependencies)" ;;
        *)
          local parts=()
          IFS=',' read -r -a parts <<< "$spec"
          for d in "${parts[@]}"; do
            d=$(printf '%s' "$d" | tr -d '[:space:]')
            [ -n "$d" ] || continue
            printf '%s' "$d" | grep -Eq '^T[0-9]+$' || die "bad task id in dependency list: $d"
            [ "$d" != "$id" ] || die "$id can't depend on itself"
            case " $list " in *" $d "*) continue ;; esac
            list="$list${list:+ }$d"
            deps="${deps:+$deps,}$d"
          done
          [ -n "$deps" ] || die "no task ids given (use '-' to clear the dependencies)" ;;
      esac
      lock board
      resolve_me
      [ "$ME" = lead ] || [ "$ME" = you ] || die "only lead or you can change dependencies (caller: $ME; $WHY)"
      [ -n "$(task_row "$id" 2)" ] || die "no task $id"
      case "$(task_row "$id" 3)" in
        done|cancelled) die "$id is closed ($(task_row "$id" 3)); dependencies only matter for open tasks" ;;
      esac
      for d in $list; do
        [ -n "$(task_row "$d" 2)" ] || die "no task $d"
        chain=$(task_dep_cycle "$id" "$d")
        [ -z "$chain" ] || die "$id can't depend on $d: $chain"
      done
      ready=$(task_dep_ready "$id" "$deps")
      awk -F'\t' -v OFS='\t' -v id="$id" -v deps="$deps" '$1==id{$4=deps} {print}' "$D/board.tsv" > "$D/board.tsv.tmp"
      mv "$D/board.tsv.tmp" "$D/board.tsv"
      unlock
      log_line sys "$ME" - "$ME set $id dependencies → $deps"
      if [ "$deps" = - ]; then echo "$id has no dependencies"; else echo "$id needs $deps"; fi
      task_notify_ready "$ready" ;;
    next-id)
      [ $# -eq 0 ] || die 'usage: crew task next-id'
      task_next_id ;;
    *) die 'usage: crew task add|set|cancel|dep|next-id ...' ;;
  esac
}
