# Claude Code

## Permission to run `crew`

In manual mode every `crew …` call raises an approval prompt and the agent
stalls until the human answers. Options, all chosen by the user:

```sh
crew up x "lead=claude --allowedTools 'Bash(crew:*)'"   # pre-allow only crew
# or run it in auto mode, or answer "don't ask again for crew …" once,
# or add "Bash(crew:*)" to the allow list in ~/.claude/settings.json
```

`--allowedTools 'Bash(crew:*)'` only covers commands that *start with* `crew`.
A compound like `crew whoami; env | grep crew` still prompts. Seen in testing:
the lead hit one prompt for a debugging compound command.

`crew up` does **not** add this flag itself ([../plans/declined.md](../plans/declined.md)).

## Process name

`#{pane_current_command}` for Claude Code is its version (`2.1.284`), not
`claude`. `detect_cli` reads the pane's tty process list instead and finds
`claude`, so adopted / `--self` / rebound Claude panes are recorded as
`claude`. `short_cli` / `shortCli` still map a bare `N.N…` to `claude` for
crews recorded before detection.

```mermaid
flowchart LR
  ps["ps -o args= -t ttys048 → -zsh, claude, …"] --> dc["detect_cli → claude"] --> label["lead · claude Opus 5.5 · %124"]
```

## Model

Status bar line like `Opus 5.5 medium · Context 92% left · …` →
`MODEL_RE` alternative `(Opus|Sonnet|Haiku|Fable) [0-9.]+`.

## As lead with `--self`

A Claude session already running in tmux can start its own crew:

```sh
crew up pr358 --self lead --here "rev2=codex …" rev=pi
```

It reads the "You are agent 'lead' …" line from the command's stdout (not
typed into its prompt), then follows `roles/lead.md`.

## No tty

Claude Code's Bash tool runs without a tty, so a Claude session that is not a
crew member is labelled `outside`, and a human's `! crew send …` typed into
Claude Code is `outside` too ([../cli/messaging.md](../cli/messaging.md)).

## Observed in real runs

- Read its role file and waited correctly after the intro.
- Created tasks with `crew task add`, then waited for the doorbell.
- A reviewer once relayed "the user approved X" to the lead. It was true, but
  indistinguishable from a false claim; the protocol now routes decisions
  through `crew say`, and the relayed message is visibly from the reviewer.

Related: [summary.md](summary.md).
