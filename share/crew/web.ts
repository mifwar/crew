// crew web — read-only local viewer for ~/.crew/<name>/ sessions.
// Serves web.html plus a small JSON API; never writes files or sends keys.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const HOME = process.env.CREW_HOME ?? join(process.env.HOME ?? "", ".crew");
const PORT = Number(process.env.CREW_WEB_PORT ?? 7777);
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const FILE_RE = /^(out|inbox|roles)\/[A-Za-z0-9._-]+\.md$/;
const page = readFileSync(join(import.meta.dir, "web.html"), "utf8");

const read = (p: string) => (existsSync(p) ? readFileSync(p, "utf8") : "");
const tsv = (p: string) => read(p).split("\n").filter(Boolean).map((l) => l.split("\t"));
const mtime = (p: string) => (existsSync(p) ? statSync(p).mtimeMs : 0);

function tmux(args: string[]): string | null {
  const r = Bun.spawnSync(["tmux", ...args], { stderr: "ignore" });
  return r.exitCode === 0 ? r.stdout.toString() : null;
}

// Same status-bar patterns as `crew` (claude "Opus 5.5", codex "GPT-6-Sol", pi "model • effort").
const MODEL_RE = /(?:Opus|Sonnet|Haiku|Fable) [0-9.]+|GPT-[A-Za-z0-9.-]+|gpt-[A-Za-z0-9.-]+|[A-Za-z0-9._-]+(?= • (?:off|minimal|low|medium|high|xhigh|max))/g;
function model(pane: string): string {
  const screen = tmux(["capture-pane", "-p", "-t", pane]);
  if (!screen) return "";
  const tail = screen.split("\n").filter((l) => l.trim()).slice(-6).join("\n");
  return tail.match(MODEL_RE)?.pop() ?? "";
}

function sessions() {
  if (!existsSync(HOME)) return [];
  return readdirSync(HOME)
    .filter((n) => NAME_RE.test(n) && existsSync(join(HOME, n, "panes")))
    .map((n) => ({
      name: n,
      ended: existsSync(join(HOME, n, "ended")),
      updated: Math.max(mtime(join(HOME, n, "channel.log")), mtime(join(HOME, n, "panes"))),
    }))
    .sort((a, b) => Number(a.ended) - Number(b.ended) || b.updated - a.updated);
}

function state(s: string) {
  const d = join(HOME, s);
  const panes = tsv(join(d, "panes")).map(([role, pane, cli, origin]) => {
    const info = tmux(["display-message", "-p", "-t", pane, "#{pane_current_command}\t#{@crew_status}\t#{session_name}:#{window_index}\t#{@crew_session}\t#{@crew_role}"]);
    const [cmd, status, where, labelSession, labelRole] = info ? info.replace(/\n$/, "").split("\t") : ["", "", "", "", ""];
    // Same ownership rule as `crew`: a reused pane id no longer carries our labels.
    const owned = info !== null && labelRole === role && (labelSession === s || labelSession === "");
    return { role, pane, cli, origin: origin ?? "spawned", alive: info !== null, stale: info !== null && !owned, cmd, status, where, model: owned ? model(pane) : "" };
  });
  const board = tsv(join(d, "board.tsv")).map(([id, owner, status, dep, out, title]) => ({ id, owner, status, dep, out, title }));
  const log = tsv(join(d, "channel.log")).map(([t, kind, from, to, text]) => ({ t, kind, from, to, text }));
  const files = ["out", "inbox", "roles"].flatMap((dir) =>
    existsSync(join(d, dir)) ? readdirSync(join(d, dir)).filter((f) => f.endsWith(".md")).sort().map((f) => `${dir}/${f}`) : [],
  );
  return { name: s, dir: d, ended: existsSync(join(d, "ended")), panes, board, log, files };
}

function json(data: unknown, status = 200) {
  return Response.json(data, { status, headers: { "cache-control": "no-store" } });
}

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  fetch(req) {
    const u = new URL(req.url);
    // Only answer requests addressed to this machine (blocks DNS-rebinding reads).
    const host = (req.headers.get("host") ?? "").replace(/:\d+$/, "");
    if (host !== "127.0.0.1" && host !== "localhost") return new Response("forbidden", { status: 403 });

    if (u.pathname === "/") return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
    if (u.pathname === "/api/sessions") return json(sessions());

    const s = u.searchParams.get("s") ?? "";
    if (!NAME_RE.test(s) || !existsSync(join(HOME, s, "panes"))) return json({ error: `unknown crew: ${s}` }, 404);

    if (u.pathname === "/api/state") return json(state(s));
    if (u.pathname === "/api/file") {
      const p = u.searchParams.get("p") ?? "";
      if (!FILE_RE.test(p)) return json({ error: "bad path" }, 400);
      return json({ path: p, text: read(join(HOME, s, p)) });
    }
    if (u.pathname === "/api/peek") {
      const role = u.searchParams.get("role") ?? "";
      const row = tsv(join(HOME, s, "panes")).find((r) => r[0] === role);
      if (!row) return json({ error: `no agent ${role}` }, 404);
      const out = tmux(["capture-pane", "-p", "-J", "-t", row[1], "-S", "-80"]);
      return json({ role, pane: row[1], text: out === null ? null : out.replace(/\s+$/, "") });
    }
    return json({ error: "not found" }, 404);
  },
});

console.log(`crew web: http://127.0.0.1:${PORT}  (read-only · ${HOME})`);
