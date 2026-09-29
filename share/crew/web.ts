// crew web — local viewer for ~/.crew/<name>/ sessions.
// Serves web.html plus a small JSON API. Read-only unless started with
// `crew web --allow-send`, which adds POST /api/send (runs `crew send` as you).
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const HOME = process.env.CREW_HOME ?? join(process.env.HOME ?? "", ".crew");
const PORT = Number(process.env.CREW_WEB_PORT ?? 7777);
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const FILE_RE = /^(?:(?:out|inbox|roles)\/[A-Za-z0-9._-]+\.md|out\/[A-Za-z0-9._-]+\.(?:log|txt))$/;
const ALLOW_SEND = process.env.CREW_WEB_ALLOW_SEND === "1";
const CREW_BIN = process.env.CREW_BIN ?? "crew";
// Per-run secret the page must echo in a custom header; a custom header also
// forces a CORS preflight, which this server never approves.
const TOKEN = randomBytes(16).toString("hex");
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
  const board = tsv(join(d, "board.tsv")).map(([id, owner, status, dep, out, title, evidence]) => ({ id, owner, status, dep, out, title, evidence: evidence ?? "-" }));
  const log = tsv(join(d, "channel.log")).map(([t, kind, from, to, text]) => ({ t, kind, from, to, text }));
  const files = ["out", "inbox", "roles"].flatMap((dir) =>
    existsSync(join(d, dir)) ? readdirSync(join(d, dir)).sort().map((f) => `${dir}/${f}`).filter((f) => FILE_RE.test(f)) : [],
  );
  return { name: s, dir: d, ended: existsSync(join(d, "ended")), panes, board, log, files };
}

async function send(req: Request, s: string) {
  if (!ALLOW_SEND) return json({ error: "sending is off; start with crew web --allow-send" }, 403);
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const origin = req.headers.get("origin") ?? "";
  if (origin !== `http://127.0.0.1:${PORT}` && origin !== `http://localhost:${PORT}`) return json({ error: "bad origin" }, 403);
  if (req.headers.get("x-crew-token") !== TOKEN) return json({ error: "bad token" }, 403);
  const body = (await req.json().catch(() => ({}))) as { to?: string; text?: string };
  const to = String(body.to ?? ""), text = String(body.text ?? "").trim();
  if (!(to === "@all" || NAME_RE.test(to))) return json({ error: "bad recipient" }, 400);
  if (!text || text.length > 4000) return json({ error: "message must be 1–4000 characters" }, 400);
  // crew attributes this to "you (web)"; stdin is not a tty, so CREW_VIA decides.
  const r = Bun.spawnSync([CREW_BIN, "-s", s, "send", to, text], {
    env: { ...process.env, CREW_HOME: HOME, CREW_VIA: "web", CREW_AGENT: "", CREW_SESSION: "", TMUX_PANE: "" },
    stdin: "ignore",
  });
  const err = r.stderr.toString().trim();
  return json({ ok: r.exitCode === 0, error: r.exitCode === 0 ? undefined : err, warning: r.exitCode === 0 && err ? err : undefined }, r.exitCode === 0 ? 200 : 400);
}

function json(data: unknown, status = 200) {
  return Response.json(data, { status, headers: { "cache-control": "no-store" } });
}

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  async fetch(req) {
    const u = new URL(req.url);
    // Only answer requests addressed to this machine (blocks DNS-rebinding reads).
    const host = (req.headers.get("host") ?? "").replace(/:\d+$/, "");
    if (host !== "127.0.0.1" && host !== "localhost") return new Response("forbidden", { status: 403 });

    if (u.pathname === "/") return new Response(page, { headers: { "content-type": "text/html; charset=utf-8" } });
    if (u.pathname === "/api/sessions") return json(sessions());
    if (u.pathname === "/api/config") return json({ allowSend: ALLOW_SEND, token: ALLOW_SEND ? TOKEN : null });

    const s = u.searchParams.get("s") ?? "";
    if (!NAME_RE.test(s) || !existsSync(join(HOME, s, "panes"))) return json({ error: `unknown crew: ${s}` }, 404);

    if (u.pathname === "/api/state") return json(state(s));
    if (u.pathname === "/api/send") return send(req, s);
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

console.log(`crew web: http://127.0.0.1:${PORT}  (${ALLOW_SEND ? "sending ENABLED as you (web)" : "read-only"} · ${HOME})`);
