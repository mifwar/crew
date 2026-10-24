# pi

pi has no approval prompts or sandbox in the user's setup (`pi --help` only
offers `--approve/--no-approve` for trusting project-local files), so
`crew send` from pi works with no flags:

```sh
crew up pr358 --self lead rev=pi
```

## Model

The user's pi runs DeepSeek through a provider; the footer reads
`(commandcode) deepseek/deepseek-v4.1-flash • max`. `MODEL_RE`'s
`[A-Za-z0-9._-]+ • (off|minimal|low|medium|high|xhigh|max)` captures
`deepseek-v4.1-flash` (the `/` stops the match, dropping the provider).

```mermaid
flowchart LR
  footer["(commandcode) deepseek/deepseek-v4.1-flash • max"] --> re["name • effort"] --> m[deepseek-v4.1-flash]
```

## Skill

pi reads `~/.pi/agent/skills` and the shared `~/.agents/skills`;
`install.sh` links `skills/crew` into both. `loadSkills` in `dist/core/skills.js`
resolves symlinks and skips a second copy of the same real file, so the two
links load the skill once, with no collision warning.

## Observed

- After the intro it deliberated about "do not reply" and then printed a
  one-line standby note. Harmless.
- When a task message and the lead's `--msg` named different output paths,
  pi wrote both files ([../cli/tasks.md](../cli/tasks.md)).
- History from earlier manual sessions: pi was right on a big review item but
  wrong on arithmetic/counting claims it later retracted. Leads must verify
  reviewer claims against code.

## Working spinner and drafts

Pi puts its Working spinner in the editor's top border. Scans preserve raw
rows, and whitespace-only padding is empty editor space. This prevents a busy
pi from being labelled draft-pending; genuine text between its borders still
holds delivery. See [../cli/ring-hold.md](../cli/ring-hold.md).

## Unknowns

- Whether pi queues text typed into its prompt during a turn.
- Whether pi's shell tool has a tty (if it did, a non-member pi would be
  labelled `you (terminal)` instead of `outside`).

`pane_current_command` shows `node`; `detect_cli` finds `pi` in the tty's
process list, so adopted/rebound pi panes are labelled `pi`.

Related: [summary.md](summary.md).
