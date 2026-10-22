# Crew lifecycle: up, add, adopt, remove, down

```mermaid
stateDiagram-v2
  [*] --> Up: crew up / crew adopt
  Up --> Up: add / remove / send / task / status / web
  Up --> Ended: crew down (writes ended)
  Ended --> Up: crew up same name (old dir moved to name.TIMESTAMP)
```

## `crew up <name> [options] role=cli …`

1. Parse `--in <tmux-session>`, `--self <role>`, `--here`; anything else
   starting with `-` is an error; `x=y` args are role specs.
2. Target session: `--in`, else the caller's (`display -p -t "$TMUX_PANE" '#S'`).
   `--self`/`--here` require a live `$TMUX_PANE`, resolved before creating
   crew files. A missing/dead id fails without leaving a crew directory.
3. `check_roles` on every spec (and `--self`): valid name, non-empty value,
   no duplicates. It runs before anything exists, so a bad spec can't leave
   orphan panes or a crew dir that blocks the name.
   Then `init_dir`: refuse if the crew is up; move an ended one aside; create dirs.
4. `--self R`: label the validated caller pane as `R`, record it as `adopted`.
   Warn when its detected CLI is a filter/pager (`tail`, `head`, `less`, `more`,
   `cat`), and print the role, pane and CLI near the final output. Do not guess
   a different pane: a live but incorrect `TMUX_PANE` needs explicit `rebind`.
5. For each spec: first pane via `new-window -d -n <name>` (or, with `--here`,
   `split-window` into the caller's window), the rest via `split-window` +
   `select-layout tiled`. Each gets `-e CREW_SESSION -e CREW_AGENT -e CREW_HOME`
   and `-c "$PWD"`. Record as `spawned`.
6. Write `meta`, `.current`, render role files, log a `sys` line.
7. For supported CLIs, record each role's launch epoch with an empty session
   ID before typing the spec into its pane. Then warn if a codex spec is
   sandboxed without network access ([../agents/codex.md](../agents/codex.md)).
8. In parallel per pane: `wait_ready` (screen `cksum` unchanged twice, ≥3 s,
   max `CREW_BOOT_WAIT`). If `detect_cli` finds only a shell, the command
   failed (see Readiness): warn with the pane's last line and send no intro.
   Otherwise `intro` (which refuses dialogs, see Readiness), then `refresh_model`.
   Session IDs are captured lazily on a later crew command, after the CLI has
   received its first message and created its native session file (see
   [sessions.md](sessions.md)).
9. `select-window` to the new window unless `--self`, `--here` or `CREW_NO_SWITCH`.
10. With `--self`, print the intro line on stdout: the calling agent reads it
    from its own command output instead of having it typed into its prompt.

```sh
crew up voucher lead=claude impl=codex rev=pi          # new window "voucher"
crew up pr358 --self lead --here "rev2=codex -c …" rev=pi   # agent starts its own crew
```

A pipeline fixture running `crew up --self lead --here … | tail -20` inside a
throwaway pane keeps the correct pane id but detects the pipeline's `tail` as
the CLI. This reproduces filter detection, not the historical wrong-id report.
The report's Claude `!` transient-pane cause remains unverified. Avoid a pipe,
check the printed binding and rebind explicitly if needed.

`--here` re-tiles the caller's window, resizing the user's existing panes.

## `crew adopt <name> role=<pane> …`

Pane refs are anything tmux resolves: `%7`, `.2`, `6.1`. `check_roles` and
resolving every ref (`resolve_pane_specs`; the same pane twice is refused) happen before
`init_dir`, so a bad ref labels nothing. `pane_id` treats empty output as
not found: tmux 3.5 `display-message -p -t %999999` prints nothing and exits 0.
Then it labels each pane,
styles its window, records it as `adopted` with the detected program as cli
(`detect_cli`, [summary.md](summary.md)),
renders role files, rings the intro into every pane. Nothing is started or
moved. Adopted agents can't get `CREW_*` env vars, so identity comes from the
pane-id lookup.

## `crew add role=<cli spec|%pane|fork:role> …`

```sh
crew -s voucher add "rev2=pi" impl2=%12
crew -s voucher add rev2=fork:lead
```

- Requires a running crew. Holds `.panes.lock` for initial validation, releases
  it while spawned CLIs start, then re-locks and checks the roster before any
  binding changes. If the crew changed, newly spawned panes are closed.
  Validate all roles and adopted panes: no duplicates, missing panes, panes
  already bound here, or panes labelled by another crew.
- CLI specs split the recorded `meta window` (including `--here`). The window
  must contain an owned crew pane; if agents moved, use the first owned pane's
  window instead. With no owned pane, rebind or adopt a pane before spawning.
  Use `meta cwd` and propagate `CREW_HOME`, `CREW_SESSION`, `CREW_AGENT`.
- `role=fork:<source-role>` creates a spawned role by forking the source's
  native conversation. It uses the source role's recorded or safely discovered
  exact session ID and native CLI command; if another same-CLI role makes the
  source ambiguous, pin its ID first with `crew session <source-role> <id>`.
  The new role keeps the source CLI spec in `panes`; fork-specific native
  options are used only for its launch. Crew records a launch epoch with a
  blank ID before starting it. A later role command lazily captures the ID
  after the CLI creates its native file; pin it explicitly if capture is
  ambiguous.
- Spawn each resolved command through the shared pane helper, which sets the
  crew environment and working directory, waits for a stable screen, and checks
  `detect_cli`. Plain CLI specs are typed verbatim; fork specs add only that
  provider's native fork arguments. A failed command closes its pane and
  leaves the roster unchanged. Record a successful start as `spawned`.
  `%pane` adopts an unlabelled existing pane, keeps its window, detects its
  CLI, and records it as `adopted`.
- `resolve_pane_specs` is shared with `adopt`: resolve pane refs, refuse the
  same pane twice, and normalize each spec into `role|pane|origin|cli`.
  Spawning specs start with an empty pane; creation fills it. CLI is last,
  so literal pipes in the user command survive `read`. These records are
  transient; persisted `panes` rows keep their existing TSV format. `add`
  alone rejects already-bound/labelled adopted panes; `adopt` keeps its
  existing validation rules.
- `crew_window` selects the stored window when it contains an owned pane,
  otherwise the first owned pane's window; it fails when none is owned.
- Render only new role files with `write_role_file`. Existing files stay
  untouched. All role files point to the live `panes` file and `crew status`
  rather than embedding a roster snapshot.
- Log a `sys` line, release the lock, and send intros using the same
  dialog checks as `up`. An intro to the caller prints on stdout.
- Before each spawned CLI starts, record its launch epoch with no session ID.
  A later crew command captures one unique new session after the CLI creates
  its native file; ambiguous launches stay unrecorded.
- `owns_pane` is checked again before intros. Failed commands get no intro;
  startup dialogs get no input and print a manual follow-up command.
  Existing agents are not restarted or rung. `down` follows each addition's
  spawned/adopted origin.

## `crew down`

First hold `.timers.lock`, mark the crew ended and its timers cancelled,
then release that lock. Stop workers through their individual dispatch locks
before pane teardown; pane I/O never holds the crew-wide timer lock. No timer
dispatch can occur after shutdown completes. See [timers.md](timers.md).

For each pane in `panes`:
- skip (with a warning) if `owns_pane` fails — the id is gone or reused;
- `spawned` → `kill-pane` (the caller's own pane last, so the script isn't
  killed mid-loop);
- `adopted` → unset `@crew_*` options and the window border options.

Then `ended` is written and `.current` cleared. Files stay.

## Pane ids

Roles are bound to tmux pane ids (`%124`). Ids are stable for a pane's life
(swap, resize, re-layout, `join-pane`, `break-pane`, `respawn-pane` all keep
them), so users can rearrange freely and add their own panes (e.g. nvim).
Ids restart after a tmux **server** restart, so an old crew's `%144` can
become an unrelated session — hence `owns_pane` ([messaging.md](messaging.md)).
If an agent's pane is closed and the agent restarted elsewhere, fix the pane
mapping with `crew rebind`. To restore the native conversation too, run
`crew resume <role>` inside a new unbound pane; see [sessions.md](sessions.md).

## `crew rebind <role> [pane] [--intro]`

```sh
crew rebind lead            # run inside the lead's new pane
crew rebind rev %201        # from anywhere
```

- Target defaults to the caller's `$TMUX_PANE`. Refuses if the target is
  already a role in this crew, or carries another crew's labels.
- Unlabels the old pane only if it still `owns_pane` (a reused id belongs to
  someone else — don't touch it).
- Holds `.panes.lock` through validation, rewriting and labelling, so a
  concurrent override cannot overwrite a validated binding. Rewrites the row: new id, detected cli,
  `origin=adopted` (so `down` never closes a pane crew didn't create).
- Labels + styles the new pane, logs `sys: <caller> rebound <role> %old → %new`.
- Sends no intro unless `--intro` (the agent usually already knows its role);
  when run from the new pane it prints a reminder line on stdout.

## `crew override <role> <replacement-role|pane>`

```sh
crew -s voucher override lead impl   # promote the running implementation agent
crew -s voucher override lead %12    # take over from an agent in a new pane
crew -s voucher override lead=pi     # spawn and verify a fresh successor
```

Manual mid-work recovery when a role hits a usage limit. Only `you` or the
current `lead` may invoke it; sender identity remains advisory. Both existing
crew panes must pass `owns_pane`; a new pane must be unlabelled. Validation
runs under `.panes.lock` and `.board.lock`, before changing bindings. For
`<role>=<cli spec>`, a bare value is a CLI command; only `%pane` adopts a pane
in that form. The shared spawn helper launches and verifies the CLI without a
roster lock. It closes a failed pane; after relocking, a changed roster also
closes the new pane and leaves the old binding in place. Caller identity is
checked again after acquiring the locks; the shared lock helper cleans up all
locks acquired by a command, including on validation failure. `task set` also
refreshes identity under its board lock. Both TSV
rewrites are prepared before publishing; updates are not crash-atomic across
files.

- An existing replacement swaps occupants with the overridden role. CLI and
  spawned/adopted origin follow the pane. Its unfinished board rows move to
  the overridden role; existing tasks for that role remain there. Completed
  rows, result paths, dependencies and evidence stay unchanged. Any recorded
  native session IDs move with the pane's role.
- A new pane replaces the binding with `origin=adopted`; a CLI started by
  `role=spec` uses `origin=spawned`. In both cases the previous pane is
  unlabelled and kept open. Before a spawned successor starts, crew records
  its launch epoch with no session ID. A later crew command lazily captures
  one unique new session after the intro creates its file. Board ownership is
  unchanged.
- Save the old pane's visible output and up to 200 scrollback lines to
  `out/override-<role>-<timestamp>-<pid>.md`, with recovery instructions.
  Private conversation history is unavailable: the successor must read the
  board, channel log, relevant inboxes, results and evidence.
- Refresh rendered role files and pane labels, log the override, notify all
  roles. Inboxes retain their history under the original role names.
  Startup dialogs receive no typed input; the notice stays in the inbox.
  A calling pane receives its own notice on stdout rather than a doorbell.
- The old agent must stop its previous work and wait for a new assignment.
  Crew changes routing and instructions; it does not interrupt an active turn.
- `resolve_me` uses current pane bindings before `CREW_AGENT`, since running
  processes retain the role environment from startup. An owned env-role hint
  is accepted only without a calling pane or with a gone/foreign-crew pane;
  deliberately detached unlabelled panes stay outside (see [messaging.md](messaging.md)).

```mermaid
flowchart TD
  override[override role replacement] --> validate[validate caller and panes]
  validate --> capture[save recovery context]
  capture --> kind{replacement}
  kind -- crew role --> swap[swap pane occupants and transfer unfinished tasks]
  kind -- new pane --> adopt[adopt successor and detach previous pane]
  swap & adopt --> refresh[refresh roles and notify agents]
  refresh --> recover[successor reads board and history and continues]
```

## `crew remove <role> [--keep-pane]`

```sh
crew -s voucher remove rev                # close rev's spawned pane, block its tasks
crew -s voucher remove rev --keep-pane    # keep the pane, unlabelled
```

Drops a role from the roster. Only `you` or the current `lead` may invoke it
(checked before and after the locks, like `override`); `lead` itself cannot be
removed — hand over with `crew override lead impl` first. An unknown role or an
ended crew dies. The pane follows `down`'s rules: a spawned pane is closed, an
adopted one is unlabelled and kept, and `--keep-pane` keeps even a spawned pane
(unlabelled, so `owns_pane` still guards it from later typing). A pane that is
gone or reused is left alone, with a warning. The roster row is dropped under
`.panes.lock`; the role's `queued`/`working` board rows become `blocked` under
`.board.lock` (done/blocked rows and dependencies untouched), and the `sys` log
line names the role, the pane action and the blocked ids. The board has no note
column, so that log line **is** the removal's note; the blocked rows stay bare.
Inbox, `out/` results, evidence and the rendered role file stay; adding the role
again (`crew add rev=codex`) starts from a new pane.

```mermaid
flowchart TD
  remove[remove role] --> guard[refuse lead; caller must be lead/you]
  guard --> look[pane_of role]
  look --> own{owns_pane?}
  own -- "spawned, no --keep-pane" --> close[close pane]
  own -- "adopted or --keep-pane" --> unlabel[unlabel, keep pane]
  own -- "gone / reused" --> leave[leave alone]
  close & unlabel & leave --> drop[drop roster row]
  drop --> block[queued/working tasks to blocked]
  block --> log[sys log naming the blocked ids]
```

## Readiness heuristic

`wait_ready` is a guess: spinners or clocks in a TUI can keep the screen
changing until the timeout. Claude and Codex queue input typed during a turn;
pi was not checked.

A startup dialog also "settles", and Enter picks its highlighted choice
(seen 2026-09-30, tmux 3.5a):

| CLI | dialog | highlighted choice |
|-----|--------|--------------------|
| claude | folder trust, footer `Enter to confirm · Esc to cancel` | `❯ No, exit` |
| codex | update, footer `enter continue · esc skip` | `› 1. Update now` (`brew upgrade`) |
| codex | folder trust, `Trust this folder?`, `enter continue · esc back` | `› 1. Trust and continue` |

A command that fails also "settles". The spec is typed into the user's shell,
so a shell error such as zsh's `no matches found` for an unquoted `[...]` in a
codex `-c` value (seen 2026-09-30) leaves the pane at a prompt. The intro would
then run as a shell command too. So `up` checks `detect_cli` after
`wait_ready`: no non-shell process means the agent isn't running. This check is
used for spawned agents in `up` and `add`; adoption may take a pane the human
runs a shell in. A live pane always lists at least its shell, so an empty `ps`
list means ps itself is blocked (a sandboxed caller, seen 2026-10-21 inside a
Codex workspace sandbox), not a failed command: crew says so and sends the
intro anyway.

Mid-session approval prompts are the same hazard for every doorbell (see
[messaging.md](messaging.md)); their text, from the CLI binaries (claude
2.1.285, codex 0.159.0): claude "Do you want to proceed?", codex "Would you
like to run the following command?" / "make the following edits" / "grant
these permissions" / "send input…", both "Yes, and don't ask again …".

`in_dialog` feeds the capture to `dialog_capture` in `share/crew/pane.sh`.
It trims leading whitespace and UI gutters (`│`, `›`, `❯`), then matches a UI
row from its start, case-insensitively. Footer hints (`enter [to]
confirm|continue|select … esc [to] back|cancel|skip`) must end at the end of the
row and occur in the last **3 nonblank rows**. Approval/trust questions and
“don't ask again” option rows use the last **15 nonblank rows**: a claude
question can sit above a variable-height option list without an enter footer.
Codex's model picker (`enter select · esc back`) is classified as a dialog.
Anchoring avoids mid-sentence transcript quotations; a transcript quoting an
exact standalone UI row can still cause a conservative false hold.
`intro()` itself checks, so `up`, `add`, `adopt` and `rebind --intro` are all
covered: on a match it types nothing and prints the `crew send` line that
delivers the intro once the human has answered. crew never answers a dialog itself:
that would be trusting a folder or updating on the user's behalf. A per-CLI
"ready prompt" regex was rejected: claude's dialog uses the same `❯` as its
prompt. `--self` never types an intro (it prints one on stdout).

`intro` also goes through the ring hold to avoid appending to a recognised
draft in an adopted or rebound pane: it waits for the editor to clear
(bounded by `CREW_RING_WAIT`), then prints the same `crew send` line if it
remains held ([messaging.md](messaging.md#ring-hold-never-type-into-a-draft)).
`start_agent` uses `ring --now`: it types into a pane crew just created. With
`CREW_RING_WAIT=0` intros inspect once and refuse a busy pane immediately.

A CLI still starting can swallow ring's Enter, leaving crew's intro as a
draft that then holds every later doorbell (pi did this for hours in
`ringrace`). After a typed intro, `intro_submit` waits (~3 s, bounded), and if
the editor still holds a draft it presses Enter once more — but only when
`draft_text` shows the editor holds exactly the line crew typed, so no other
draft is ever submitted. Still a draft after that prints a warning with the
`tmux send-keys -t %P Enter` hint; there is no loop. `crew status`/`crew watch`
flag the state as `draft pending: doorbells are held` ([watch.md](watch.md)).

`crew sweep --apply` ends only crews with zero owned panes, without touching
any pane; default sweep is a dry run. See [listing.md](listing.md).

Related: [summary.md](summary.md), [../architecture/state-files.md](../architecture/state-files.md).
