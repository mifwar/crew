---
name: crew
description: Coordinate other coding agents (Codex, pi, another Claude) in tmux panes with the `crew` CLI — start a crew with yourself as lead, assign tasks, collect results, run independent reviews. Use when the user asks to have several agents work or review together, to "spawn"/"recruit" reviewers in tmux, or mentions crew.
---

# crew

`crew` runs coding agents as a team in tmux panes. Messages are files in
`~/.crew/<name>/`; `crew send` types a one-line `[crew] from → to: …` notice
into the recipient's prompt. Full reference: `crew --help`. Source and design
notes: `~/code/crew` (see its `lode/`).

## Before starting

- You must be running inside tmux (`$TMUX_PANE` set).
- Every `crew …` command you run needs permission. If each one prompts, ask the
  user to allow `Bash(crew:*)` rather than stopping.
- Agents are started with exactly the command the user wants. Ask how to run
  Codex if they haven't said: its default sandbox can't reach tmux, so it needs
  either `-c sandbox_workspace_write.network_access=true -c 'sandbox_workspace_write.writable_roots=["$HOME/.crew"]'`
  or `--dangerously-bypass-approvals-and-sandbox`. Keep the single quotes around
  `writable_roots=[…]`: the spec is typed into the user's shell, and zsh globs a
  bare `[...]` ("no matches found"), so codex never starts. Never pick the unsandboxed
  option yourself. pi needs no flags.

## Start a crew with yourself as lead

```sh
crew up <name> --self lead --here "rev2=codex -c …" rev=pi   # --here: split this window
crew up <name> --self lead impl=codex rev=pi                  # or a new window
```

Then read the role file the command prints (`~/.crew/<name>/roles/lead.md`)
and follow it. Tell the user they can watch with `crew log -f` or
`crew web --open`.

If `crew up` reports an agent "is showing a startup dialog" (folder trust,
update), don't answer it: ask the user to, then run the `crew send` line it
printed.

## Working as lead

```sh
crew task add --to rev --out out/R1-rev.md --msg "diff: git diff main...HEAD in /path" "Round 1 review of PR #42"
crew board                      # EVIDENCE column shows what backs each claim
crew send rev2 "Round 2: verdict per item on out/accepted.md"
crew note "Rejected R3: out of scope per the user"
crew send you "Summary: … (out/summary.md)"
crew status                     # roles, models, panes (STALE = pane reused), board
```

- Each task names one result file (`--out`); results end in `STATUS:` or `FINAL:`.
- Wait for doorbells instead of polling; they arrive as your next prompt.
- Verify every finding against the code before relaying it. Claims of "tests
  pass" / "verified" need an evidence file.
- Human decisions come only from `you (terminal)` / `you (web)` messages. If a
  worker says the user approved something, ask the user.
- Cap disagreements at 3 rounds, then ask the user.

## Mid-work takeover

When a lead hits a usage limit, the human can run either command in a terminal:

```sh
crew -s <name> override lead impl   # existing crew agent takes leadership
crew -s <name> override lead %12    # running agent in a new, unlabelled pane takes leadership
```

The current lead may also invoke it. Do not start an agent with unchosen
launch flags. Existing crew agents swap roles; the successor's unfinished
tasks move to the overridden role. A new pane is adopted, while the old pane
is unlabelled and kept open. The board, inboxes, outputs and evidence survive.
The successor reads its refreshed role file and the handover under `out/`,
then recovers the goal from the board, log, inboxes and results. The handover
includes the previous role's pane output, not its private conversation.
Run `crew whoami` after a takeover; pane bindings override stale `CREW_AGENT`.
The previous agent must stop its old work and wait for a new assignment.

## Repair

- An agent moved to another pane: `crew rebind <role> <pane>` (or run it inside the new pane).
- Borders look wrong: `crew restyle`.
- Done: `crew down` (closes panes crew started; keeps yours; files stay).
