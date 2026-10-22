# Tasks and the board

```mermaid
stateDiagram-v2
  [*] --> queued: crew task add
  queued --> working: crew task set Tn working
  working --> done: set Tn done (result file must end STATUS: DONE / FINAL:)
  working --> blocked
  working --> needs_input: needs-input
  blocked --> working
  needs_input --> working
```

## `crew task add --to <role> [--dep T1] [--out out/x.md] [--gate "<cmd>"] [--msg "…"] <title…>`

`--out` (bare `x.md` becomes `out/x.md`; anything else must match
`^out/[A-Za-z0-9._-]+\.md$`) names the task's one result file; the default is
`out/<id>-<owner>.md`. Under the board lock: id = `T<rows+1>`, append
`id⇥owner⇥queued⇥dep|-⇥out⇥title⇥-⇥gate|-`. Then: log a `sys` line, set the owner's
`@crew_status` to `Tn queued`, and `crew send` the owner (so there is no need
for the lead to also message them):

```
T3 for you: <title> (needs T2) — <msg>. Write /Users/…/.crew/<name>/out/T3-rev.md
(not in your working directory), then: crew task set T3 done [--evidence <file>]
&& crew send lead "T3 done"
```

The result path is **absolute** on purpose: agents run in the repo, and a
relative `out/` would create files inside the worktree (breaking reviewers'
read-only rule). Prints the new id on stdout.

`{id}` in `--out` and `--msg` is replaced with the id this add has just taken,
so a lead can name the result file before the id exists:
`--out out/{id}-fix.md`. `crew task next-id` prints the same id without adding
anything (`T<rows+1>`; `T1` on empty). Both expansions happen before the
`--out` validation, so `out/{id}.md` is checked as `out/Tn.md`.

## Ids follow the order of `crew task add` calls

The id only exists after the row does (`T<rows+1>`), and `add` immediately
messages the owner with it. Decide the numbering first and add tasks in that
order; a later add never takes an earlier id.

A wrong order is fixed at the source, not with follow-up messages: while the
affected rows are still `queued`, take `$D/.board.lock` (same lock `add` and
`set` use), rewrite `board.tsv` into the intended order, then send each owner
one final line naming its id. Once a worker has moved its id off `queued`,
leave the board as it is and re-send the mapping instead. In `ringrace` three
workers were told T1/T3/T2 by add order, then got two "correction"
messages, then the board was regenerated and each was re-told; the
corrections were the wasted half — the timeline showed ids that no longer
existed.

A `--msg` that *also* names a path would still conflict; `lead.md` tells the
lead to name paths only with `--out` (pi once wrote both files when it wasn't).

## `crew task set <id> <status> [--out <file>] [--evidence <file>] [--force]`

Status must be `queued|working|done|blocked|needs-input`. Only the task's
owner, `lead` or `you` may set it (advisory, like sender labels: it stops a
worker closing someone else's task by mistake). An unresolved (`outside`) caller
fails before any gate or board write, even with `--force`, with the deciding
identity failure and a `whoami`/per-call hint. Identity is refreshed under the
lock before authorizing the update. Under the lock,
rewrites the row via `awk` → `board.tsv.tmp` → `mv`; `--evidence` fills
column 7 (old 6-column rows gain it). Then updates the owner's
pane label (only if `owns_pane`) and logs `"<caller> set Tn → status (file)"`
(plus `[forced]` when `--force` was used).

### `done` gate: the result file must say so

`set … done` reads the effective result file (`--out`, else column 5) and
requires its **last non-empty line** to start with `STATUS: DONE` or
`FINAL:`. Otherwise the task stays open and the error quotes what the file
says:

- no file named, or the file does not exist / is blank → points at the write and at `--force`;
- last line `STATUS: BLOCKED`, `STATUS: PARTIAL`, `STATUS: NEEDS-INPUT`, … → `Tn stays open: <file> ends with '…'`;
- anything else → asks for `STATUS: DONE`/`FINAL:`.

A trailing `\r` is stripped before that check, so CRLF result files — including a
CRLF blank row after `STATUS: DONE` — behave like LF ones.

`--force` skips the check and logs `[forced]` on the `set` line, so the board
history shows the shortcut. The gate applies to `lead` and `you` too. Only
`done` is gated; moving a task to `blocked` still does not need an exit file.

### `--gate "<cmd>"`: a command that must pass for `done`

Stored (one line) in column 8. `set … done` runs it with `bash -c` in the crew's
project dir (`meta cwd`) **before** taking the board lock, so a slow test run
can't make other writers time out; only for a caller allowed to set the task.
Output goes to `out/<id>-gate.log` (`$ cmd`, output, `[exit N]`) and becomes the
evidence unless `--evidence` is given. Non-zero exit: `Tn stays open: gate … exited N`.
Only `lead`/`you` may add a gate, and only the task's owner runs it (in the
owner's own shell and permissions); lead/you marking a gated task done are
refused unless `--force`. A gate guards against honest mistakes, not proof: the
owner can fake its own log, and role labels are advisory.
`--force` skips the gate like the result-file check. Other statuses never run it.

## Locking

```sh
lock board   # mkdir "$D/.board.lock" (retry 50 × 0.1 s, then die); trap 'rmdir …' EXIT
unlock board # also used as: lock panes / unlock panes (crew rebind)
```

Without it, two concurrent `task set`s lost an update and two `task add`s
could get the same id. `test/smoke.sh` runs 15 parallel adds and 15 parallel
sets. A crash between `mkdir` and the trap could leave a stale lock; the die
message names the directory to remove.

## `crew board` / `crew status`

`board` prints `ID OWNER STATUS NEEDS OUTPUT EVIDENCE TITLE` via `column -t`
(title last so long titles don't push columns). `status` prints
`ROLE CLI MODEL PANE RUNNING LAST-MESSAGE NOTE CONTEXT/QUOTA` for every role
(RUNNING is the short cli, `gone`, or `STALE (pane reused)`), then any active
command semaphore holders (wrapper/command pids, role and argv) and the board.
See [semaphore.md](semaphore.md).
The last message is capped at 70 Unicode characters via `truncate_text`
(Bash substring with `en_US.UTF-8`), rather than BSD awk's byte-based
`substr`: cutting a UTF-8 sequence makes BSD `column` drop the roster rows.
Timestamp-only `awk substr` calls slice ASCII and are safe.

## Result file contract (from protocol.md)

- Path `~/.crew/<name>/out/<task>-<role>.md`.
- Last line exactly `STATUS: DONE|BLOCKED|NEEDS-INPUT`; reviewers
  `FINAL: AGREE|DISAGREE`. Tools (the web viewer, the lead) key on these, and
  `task set … done` refuses to close a task whose file does not end that way
  (`--force` overrides; see above).
- Claims that something was run or verified need an evidence file (command +
  output, e.g. `out/T3-tests.log`) attached with `--evidence`. The lead treats
  claims without one as unverified; the web board shows `no evidence` on done
  tasks that lack it. Found in use: a brief said "verified E2E, 150 tests"
  while the PR said "not checked in a browser, 147".

`task set` resolves caller identity again after taking `.board.lock`, so a
role override while it waits cannot retain the previous lead privilege.

Related: [messaging.md](messaging.md), [../architecture/state-files.md](../architecture/state-files.md).
