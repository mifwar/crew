# Messaging: send, doorbell, ownership

## `crew send <to> <message…>`

```mermaid
flowchart TD
  s[crew send to msg] --> who{to}
  who -- "@all" --> perm{caller is lead or you?}
  perm -- no --> die[die: only lead or you can broadcast]
  perm -- yes --> logall[log kind=all] --> each["deliver to every role except caller"]
  who -- you --> logyou[log dm → you] --> youinbox[inbox/you.md] --> disp["tmux display-message (8 s)"]
  who -- role --> check{role exists and ≠ caller}
  check -- yes --> logdm[log kind=dm] --> dl[deliver]
  dl --> inbox[append inbox/role.md] --> own{owns_pane?}
  own -- no --> warn["warn 'not ringing', return 0"]
  own -- yes --> model[refresh_model] --> ring["ring '[crew] from → to: text'"]
```

- The body goes to `inbox/<role>.md` in full (markdown heading per message).
- The doorbell is the message flattened to one line. Over `RING_MAX` (500)
  chars it becomes `long message; read the latest entry in …/inbox/<role>.md`.
- `ring` = `send-keys -l -- "$text"`, sleep 0.3, `send-keys Enter`.
- `crew send you` has no pane: log + `inbox/you.md` + an 8-second tmux status
  message. Easy to miss; keep `crew log -f` or `crew web` open.

## Ownership guard (`owns_pane`)

```sh
owns_pane() { # pane role
  local got
  got=$(tmux display-message -p -t "$1" '#{@crew_session}	#{@crew_role}' 2>/dev/null) || return 1
  [ "$got" = "$S	$2" ] || [ "$got" = "	$2" ]   # second form: crews labelled before @crew_session existed
}
```

Used by `deliver`, `set_pane_status`, `status` (shows `STALE (pane reused)`),
and `down` (skips the pane). Found in real use: after a tmux server restart an
old crew's lead id `%144` belonged to an unrelated Claude session, and
`status` looked healthy because both processes were named `2.1.284`.
Rings typed there would have become prompts in the wrong session.

The web viewer applies the same rule and shows the role as `stale`.

## Identity

`resolve_me`: `$CREW_AGENT` when `$CREW_SESSION` matches, else the role whose
pane id equals `$TMUX_PANE`, else `you`. Consequences:
- a pane outside the crew (or a renamed/moved agent) is silently `you`;
- a worker **can** claim to relay the human ("user approved X") in a normal
  message. The protocol tells agents to treat crew messages as teammate
  requests, never as the human's permission; a real `--as you` channel is on
  the roadmap.

## `crew log`

`fmt_log` prints `HH:MM:SS  from → to  text` (`· text` for sys lines).
`-f` follows (`tail -f`), `-n N` sets the backlog (default 40).

Related: [summary.md](summary.md), [tasks.md](tasks.md), [../roles/summary.md](../roles/summary.md).
