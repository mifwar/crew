# Messaging: send, doorbell, ownership

## `crew send <to> <message…>`

```mermaid
flowchart TD
  s[crew send to msg] --> who{to}
  who -- "@all" --> perm{caller is lead or you?}
  perm -- no --> die[die: only lead or you can broadcast]
  perm -- yes --> logall[log kind=all] --> each["deliver to every role except caller"]
  who -- you --> logyou[log dm → you] --> youinbox[inbox/you.md] --> disp["tmux display-message (8 s)"]
  who -- "a,b" --> all{every name exists and ≠ caller?}
  all -- no --> die2[die: nothing sent]
  all -- yes --> each2["crew send a msg; crew send b msg"]
  who -- role --> check{role exists and ≠ caller}
  check -- yes --> logdm[log kind=dm] --> dl[deliver]
  dl --> inbox[append inbox/role.md] --> own{owns_pane?}
  own -- no --> notrung["warn + log sys 'role not rung: why'"]
  own -- yes --> dlg{in_dialog?}
  dlg -- yes --> notrung
  dlg -- no --> model[refresh_model] --> ring["ring '[crew] from → to: text'"]
  ring -- fails --> notrung
```

- Delivery to the calling pane prints the notice on stdout. A startup dialog
  receives no typed input; the message stays in its inbox with a warning.
- The body goes to `inbox/<role>.md` in full (markdown heading per message).
  The inbox is the delivery; the doorbell is best-effort.
- A doorbell that isn't rung (pane gone/reused, showing a dialog or approval
  prompt, or `send-keys` failed) warns the sender on stderr and logs
  `sys <sender> <role> "<role> not rung: <why>; message is in inbox/<role>.md"`.
  So the timeline (`crew log`, web) answers "did impl ever get this?". crew
  does not retry: the sender (usually the lead) resends once the pane is free.
- Approval prompts are why `deliver` checks `in_dialog`: a doorbell such as
  `T1 done` types a `1`, which picks option 1 ("Yes") in claude's and codex's
  approval selectors, before any Enter. Patterns and their sources:
  [lifecycle.md](lifecycle.md#readiness-heuristic). An agent that itself
  writes "Do you want to proceed?" near its prompt also holds doorbells; that
  errs on the safe side.
- `send a,b msg` checks every name first (nothing is sent if one is bad), then
  does one plain `send` per name: separate log lines, doorbells and inbox
  entries. `@all` can't be in a list.
- The doorbell is the message flattened to one line. Over `RING_MAX` (500)
  chars it becomes `long message; read the latest entry in …/inbox/<role>.md`.
- `ring` = `send-keys -l -- "$text"`, sleep 0.3, `send-keys Enter`, holding
  `$D/.ring<pane>.lock` (mkdir) throughout. Without it, parallel sends to one
  pane typed all texts into one prompt line and then N Enters (seen with 5
  parallel `crew send`s). After 10 s of waiting the lock counts as left by
  a killed call and the ring goes ahead; the ring removes it either way.
- `crew send you` has no pane: log + `inbox/you.md` + an 8-second tmux status
  message. Easy to miss; keep `crew log -f` or `crew web` open.
- The doorbell and inbox heading show `sender_label`: the role, `you (terminal)`,
  `you (web)`, or `outside %N (not in this crew)`.
- `crew say` = `send` that dies unless the caller resolves to `you`. It is the
  documented way for the human to give decisions.
- `crew note <text>` logs `sys: note (<caller>): text` (manual repairs, decisions).

## Ownership guard (`owns_pane`)

```sh
owns_pane() { # pane role
  local got
  got=$(tmux display-message -p -t "$1" '#{@crew_session}	#{@crew_role}' 2>/dev/null) || return 1
  [ "$got" = "$S	$2" ] || [ "$got" = "	$2" ]   # second form: crews labelled before @crew_session existed
}
```

Used before command launches and intros, for env identity fallback, by
`deliver`, `set_pane_status`, `status` (shows `STALE (pane reused)`), `down`
(skips the pane), and `ls`/`sweep` (classify liveness without touching panes).
Found in real use: after a tmux server restart an
old crew's lead id `%144` belonged to an unrelated Claude session, and
`status` looked healthy because both processes were named `2.1.284`.
Rings typed there would have become prompts in the wrong session.

The web viewer applies the same rule and shows the role as `stale`.

## Identity

```mermaid
flowchart TD
  a{TMUX_PANE present?} -- yes --> lookup{pane bound in this crew?}
  lookup -- yes --> role[current role]
  lookup -- no --> missing{pane gone or labelled to another crew?}
  missing -- yes --> b{CREW_AGENT + matching CREW_SESSION + owned role pane?}
  missing -- no --> c{"stdin is a tty?"}
  a -- no --> b
  b -- yes --> role
  b -- no --> c
  c -- yes --> term["you (terminal)"]
  c -- no --> d{CREW_VIA=web?}
  d -- yes --> web["you (web)"]
  d -- no --> out[outside]
```

Pane bindings take precedence over `CREW_AGENT` after overrides. A pane that
has been detached and left unlabelled cannot claim its previous identity via
stale environment variables. A matching `CREW_SESSION` / `CREW_AGENT` hint
is accepted only if that role's recorded pane passes `owns_pane`, and the
caller has no `TMUX_PANE`, its id is gone, or its pane is labelled to another
crew. This handles Codex tool shells inheriting a missing/foreign id from a
shared background process. Existing unlabelled or unbound same-crew panes
stay outside. Unknown roles, stale role panes and mismatched session hints
never get fallback identity. These remain advisory labels, not authentication.
`env_identity_ok` owns these early-return checks; `resolve_me` selects the
pane binding, then eligible env identity, then human/outside provenance.

`up` and spawning `add` both pass `CREW_SESSION` / `CREW_AGENT` to their new
panes. Adoption cannot modify an already-running agent's environment.

Agents' shell tools run without a tty (checked for Claude Code), so an agent
that isn't a crew member shows up as `outside`, not as the human. `outside`
cannot broadcast or `say`. This is **advisory provenance**: it stops honest
mistakes (a reused pane, an agent relaying "the user approved X"), not a
hostile process, which could fake a tty (`script`), set `CREW_VIA`, or write
the files directly. Consequences for the human: `! crew send …` typed into a
Claude Code prompt runs without a tty and is labelled `outside`; use a
terminal pane or `crew web --allow-send`.

`crew whoami` in a pane that isn't in the crew adds a stderr hint:
`pane %157 isn't in crew X; if an agent moved here: crew rebind <role>`.

## `crew log`

`fmt_log` prints `HH:MM:SS  from → to  text` (`· text` for sys lines).
`-f` follows (`tail -f`), `-n N` sets the backlog (default 40).

Related: [summary.md](summary.md), [tasks.md](tasks.md), [../roles/summary.md](../roles/summary.md).
