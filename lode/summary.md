# crew — Living Snapshot

`crew` runs several coding-agent CLIs (Claude Code, Codex, pi) as a team inside
tmux. It is one bash script (`bin/crew`, macOS bash 3.2 compatible) plus
markdown role templates (`share/crew/`) and a read-only Bun web viewer
(`share/crew/web.ts` + `web.html`). Messages are plain files under
`~/.crew/<name>/`; tmux `send-keys` is only the "doorbell" that types a
one-line `[crew] from → to: …` notice into the recipient's prompt. There is no
daemon and no IPC: each `crew` call does its work and exits, and agents call it
from their own shell tool. A crew has one **lead** that assigns tasks on a
board (`board.tsv`), workers that write results to `out/` ending in an exact
`STATUS:` / `FINAL:` line, and the human (`you`) who can message anyone from
any shell. Before typing into or closing a pane, `crew` checks the pane still
carries this crew's labels, because tmux pane ids are reused after a server
restart. The web viewer (`crew web`, 127.0.0.1:7777) polls a small JSON API
and shows roster (with screen-scraped model names), timeline, board, files and
pane captures; it never writes. Verification is `test/smoke.sh`, which runs a
throwaway crew of `cat` agents in a detached tmux session.

```mermaid
flowchart LR
  you((you)) -- crew send --> files[(~/.crew/name/)]
  lead[lead pane] -- crew task add / send --> files
  worker[worker panes] -- crew send / task set --> files
  files -- tmux send-keys doorbell --> lead & worker
  files -- polled read-only --> web[crew web :7777]
```

Start with [lode-map.md](lode-map.md); open work is in
[plans/roadmap.md](plans/roadmap.md).
