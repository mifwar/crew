# AGENTS.md

`CLAUDE.md` is a symlink to this file. Always edit `AGENTS.md`.

## What this is

`crew`: run several coding-agent CLIs (Claude Code, Codex, pi) as a team in
tmux panes. Bash CLI `bin/crew`, templates in `share/crew/`, Bun web
viewer `share/crew/web.ts` + `web.html` (read-only unless `--allow-send`). Messages are files in `~/.crew/<name>/`;
`tmux send-keys` rings a one-line doorbell. Full picture: `lode/summary.md`.

## Commands

- `./install.sh` — symlink `~/.local/bin/crew` → `bin/crew` and `skills/crew` into `~/.claude/skills`, `~/.codex/skills`, `~/.pi/agent/skills` (the installed crew *is* this checkout).
- `test/smoke.sh` — the test suite; throwaway crew of `cat` agents in a detached tmux session. Must print `all passed`.
- `bash -n bin/crew` — syntax.
- Web checks: `node --check` on `web.html`'s script, `bun build --no-bundle share/crew/web.ts` (see `lode/practices.md`).

## Rules that are easy to break

- **bash 3.2 / BSD tools**: no associative arrays, no `grep -P`, `sed -i ''`.
- **Never test in the user's tmux session or `~/.crew`.** Use `--in <detached session>`, `CREW_NO_SWITCH=1`, a scratch `CREW_HOME`. The user has live crews; read-only commands on them are fine.
- **Any code that types into or kills a pane must pass `owns_pane`.** Pane ids get reused after a tmux server restart.
- **Don't add flags that weaken an agent's safeguards** (`--yolo` shortcuts, auto `--dangerously-*`, auto sandbox overrides, auto permission allowlists). The launch command is exactly the user's role spec. See `lode/plans/declined.md`.
- `crew web` stays bound to 127.0.0.1 with the Host check and path regexes; its only write path stays behind `--allow-send` + Origin + per-run token.
- Sender labels (`you (terminal)`, `you (web)`, `outside`) are advisory; never present them as authentication.
- When commands change, update `crew --help`, `skills/crew/SKILL.md` and the lode together.

# LODE Coding

All persistent project memory lives in `lode/`, an AI-owned markdown repository.
It is the only way to stay aligned across sessions and agents.

Core principles
- The human owns the code and makes final decisions. The agent is the memory and executor.
- Anything worth implementing is worth recording in the lode.
- Summarize lode contents for the user rather than dumping them, unless asked for a file.

Authority inside `lode/`
- Create, update, rename, move or delete files freely (delete only committed files with no uncommitted changes).
- Diagrams are Mermaid only.
- If the lode contradicts the code, the code wins: summarize the disparity and ask the user to confirm the lode fix.

Structure
```
lode/
  summary.md        one-paragraph living snapshot
  terminology.md    term - meaning lines
  practices.md      patterns and practices
  lode-map.md       index of every lode file
  plans/            roadmap, declined decisions
  tmp/              git-ignored session scraps and handovers
  <domain>/         summary.md + one focused topic per file (kebab-case)
```

Every lode file
- covers one topic, with concrete code examples and a Mermaid diagram;
- links related lode files by relative path;
- records invariants, contracts, rationale and lessons learned;
- stays under 250 lines (split into sub-files otherwise);
- describes the **current state**, never a changelog. Changelog-style notes go in `lode/tmp/`.

Workflow
1. At session start read `lode/lode-map.md`, `lode/terminology.md`, `lode/summary.md`, then the files relevant to the task. Briefly show the user you have that context.
2. Before searching the code, check `lode/lode-map.md`.
3. Discuss and decide first; implement after a clear decision.
4. After any change to behaviour or structure, update the matching lode files (and `lode/plans/roadmap.md`) before moving on. When the user says "looks good / ship it", make sure the lode matches reality.
5. After big changes, check the lode structure still mirrors the code.
6. On request for a handover, write `lode/tmp/handover-<date>.md`: task state, decisions, approaches tried, blockers, next steps.
