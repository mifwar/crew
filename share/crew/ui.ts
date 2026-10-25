// Optional terminal view. Shell commands remain the authority for observations,
// pane ownership and navigation; no server, input forwarding or new state files.
import { existsSync, readdirSync, readFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { emitKeypressEvents, type Key } from "node:readline";

const home = process.env.CREW_HOME!;
const crewBin = process.env.CREW_BIN!;
const namePattern = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const closed = new Set(["done", "cancelled"]);
type Agent = { role: string; pane: string; cli: string; state: string; model: string; resources: string; note: string };
type Task = { id: string; owner: string; status: string; title: string };
type Message = { time: string; from: string; to: string; text: string };

function read(path: string): string {
  try { return readFileSync(path, "utf8"); } catch { return ""; }
}
function crews(): string[] {
  try {
    return readdirSync(home).filter((name) => namePattern.test(name)
      && existsSync(join(home, name, "panes")) && !existsSync(join(home, name, "ended"))).sort();
  } catch { return []; }
}
// Strip terminal instructions from every external string, including OSC and
// C1 controls. Only the renderer's own escape sequences reach the terminal.
export function clean(value: string): string {
  return Bun.stripANSI(value).replace(/[\x00-\x1f\x7f-\x9f]/g, " ");
}
const segments = new Intl.Segmenter(undefined, { granularity: "grapheme" });
export function fit(value: string, width: number): string {
  let text = "", used = 0;
  for (const { segment } of segments.segment(clean(value))) {
    const size = Bun.stringWidth(segment);
    if (used + size > width) break;
    text += segment; used += size;
  }
  return text + " ".repeat(Math.max(0, width - used));
}

async function main() {
  if (typeof Bun.stringWidth !== "function" || typeof Bun.stripANSI !== "function") {
    throw new Error("crew ui needs a newer Bun with stringWidth and stripANSI support");
  }
  const available = crews();
  if (process.argv[2] && (!namePattern.test(process.argv[2]) || !existsSync(join(home, process.argv[2], "panes")))) {
    throw new Error(`unknown crew: ${process.argv[2]}`);
  }
  let name = process.argv[2] || read(join(home, ".current")).trim();
  if (!namePattern.test(name) || !existsSync(join(home, name, "panes"))) name = available[0] ?? "";
  if (!name) throw new Error("no crews found; start one with crew up");
  let agents: Agent[] = [], tasks: Task[] = [], messages: Message[] = [];
  let selected = "", preview = "", notice = "", updated = "", refreshing = false, refreshAgain = false, quitting = false;
  let ended = false;
  let held: Record<string, string> = {};
  const children = new Set<ReturnType<typeof Bun.spawn>>();
  const originalRaw = process.stdin.isRaw;
  const color = (code: number, text: string) => `\x1b[${code}m${text}\x1b[0m`;

  async function command(session: string, args: string[]) {
    const child = Bun.spawn([crewBin, "-s", session, ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    children.add(child);
    try {
      const [stdout, stderr, code] = await Promise.all([
        new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
      ]);
      return { stdout, stderr, code };
    } finally { children.delete(child); }
  }

  function draw() {
    if (quitting) return;
    const width = Math.max(1, (process.stdout.columns || 80) - 1);
    const height = Math.max(1, (process.stdout.rows || 24) - 1);
    const lines: string[] = [];
    const line = (text: string) => lines.push(fit(text, width));
    const rule = (label: string) => color(36, fit(`── ${label} ${"─".repeat(width)}`, width));
    lines.push(color(1, fit(` crew / ${name}${ended ? "  [ended]" : ""}`, width)));
    line(` ${agents.length} agents · read-only · status is heuristic · ${updated ? `observed ${updated}` : "loading…"}`);
    const agent = agents.find((a) => a.role === selected);
    const roster = (count: number, rosterWidth: number): string[] => {
      const index = Math.max(0, agents.findIndex((a) => a.role === selected));
      const start = Math.max(0, Math.min(index - Math.floor(count / 2), agents.length - count));
      return Array.from({ length: count }, (_, i) => {
        const a = agents[start + i];
        if (!a) return fit("", rosterWidth);
        const task = tasks.find((t) => t.owner === a.role && !closed.has(t.status));
        const row = fit(`${a.role === selected ? "›" : " "} ${a.role} · ${a.cli} · ${a.state}${a.note ? " !" : ""}${task ? ` · ${task.id} ${task.status}` : ""}`, rosterWidth);
        return a.role === selected ? color(7, row) : row;
      });
    };
    const details: string[] = [];
    if (agent) {
      details.push(`${agent.role} / ${agent.pane} · ${agent.model || agent.cli} · ${agent.state}`);
      if (agent.note) details.push(agent.note);
      if (agent.resources) details.push(agent.resources);
      const count = held[agent.role] ?? "";
      if (/^[1-9][0-9]*$/.test(count)) details.push(`${count} held doorbell(s) · message saved in inbox`);
      const assigned = tasks.filter((t) => t.owner === selected && !closed.has(t.status));
      for (const t of assigned.slice(0, 3)) details.push(`${t.id} [${t.status}] ${t.title}`);
      if (!assigned.length) details.push("No open tasks");
      if (assigned.length > 3) details.push(`+${assigned.length - 3} more open tasks · crew board`);
      const recent = messages.filter((m) => m.from === selected || m.to === selected || m.to === "all").slice(-2);
      for (const m of recent) details.push(`${m.time.slice(11, 19)} ${m.from} → ${m.to}: ${m.text}`);
    } else details.push("No agents in this crew");

    if (width >= 110) {
      const leftWidth = Math.min(52, Math.floor(width * 0.38));
      const rightWidth = width - leftWidth - 3;
      lines.push(rule("AGENTS / DETAILS"));
      const count = Math.min(8, Math.max(2, Math.floor(height / 3)));
      const left = roster(count, leftWidth);
      for (let i = 0; i < count; i++) lines.push(`${left[i]} │ ${fit(details[i] ?? "", rightWidth)}`);
    } else {
      lines.push(rule("AGENTS"));
      lines.push(...roster(Math.min(4, Math.max(1, Math.floor(height / 5))), width));
      for (const detail of details.slice(0, 6)) line(detail);
    }
    lines.push(rule(`LIVE PANE / ${selected || "—"}`));
    const footer = notice || "↑/↓ j/k select · Tab crew · Enter open pane · r refresh · q/Esc quit";
    const remaining = Math.max(0, height - lines.length - 1);
    const paneLines = remaining ? (preview || "Waiting for pane preview…").trimEnd().split("\n").slice(-remaining) : [];
    for (let i = 0; i < remaining; i++) line(paneLines[i] ?? "");
    // Leave one column and row unused: writing the bottom-right cell can
    // trigger scrolling or wrapping, especially after a resize.
    const visible = lines.slice(0, Math.max(0, height - 1));
    while (visible.length < height - 1) visible.push(fit("", width));
    visible.push(color(notice ? 33 : 2, fit(footer, width)));
    process.stdout.write(`\x1b[H${visible.map((row) => `${row}\x1b[K`).join("\r\n")}\x1b[J`);
  }

  let peeking = false, peekAgain = false;
  async function peek() {
    if (peeking) { peekAgain = true; return; }
    peeking = true;
    const session = name, role = selected;
    try {
      if (!role) { preview = "No pane selected"; return; }
      const result = await command(session, ["peek", role, "160"]);
      if (quitting || name !== session || selected !== role) return;
      preview = result.code === 0 ? result.stdout : result.stderr;
    } catch (error) { if (!quitting) notice = String(error); }
    finally {
      peeking = false; draw();
      if (peekAgain && !quitting) { peekAgain = false; void peek(); }
    }
  }

  async function refresh() {
    if (quitting) return;
    if (refreshing) { refreshAgain = true; return; }
    refreshing = true;
    const session = name;
    try {
      const result = await command(session, ["_ui-state"]);
      if (quitting || session !== name) return;
      if (result.code !== 0) { notice = result.stderr; return; }
      agents = result.stdout.replace(/\n$/, "").split("\n").filter(Boolean).map((row) => {
        if (row.split("\t").length !== 7) throw new Error("invalid observation row from crew _ui-state");
        const [role, pane, cli, state, model = "", resources = "", note = ""] = row.split("\t");
        return { role, pane, cli, state, model, resources, note };
      });
      ended = existsSync(join(home, name, "ended"));
      held = Object.fromEntries(agents.map((agent) => [agent.role, read(join(home, name, "pending", agent.role)).trim()]));
      tasks = read(join(home, name, "board.tsv")).split("\n").filter(Boolean).map((row) => {
        const [id, owner, status, , , title] = row.split("\t");
        return { id, owner, status, title };
      });
      messages = read(join(home, name, "channel.log")).trimEnd().split("\n").filter(Boolean).slice(-100).map((row) => {
        const [time, , from, to, text] = row.split("\t");
        return { time, from, to, text };
      });
      if (!agents.some((a) => a.role === selected)) selected = agents[0]?.role ?? "";
      updated = new Date().toLocaleTimeString();
      await peek();
    } catch (error) { if (!quitting) notice = String(error); }
    finally {
      refreshing = false; draw();
      if (refreshAgain && !quitting) { refreshAgain = false; void refresh(); }
    }
  }

  function stop(code = 0) {
    if (quitting) return;
    quitting = true;
    clearInterval(timer);
    for (const child of children) child.kill();
    process.stdin.off("keypress", input);
    process.stdout.off("resize", draw);
    process.stdin.setRawMode(originalRaw ?? false);
    process.stdin.pause();
    writeSync(1, "\x1b[0m\x1b[?25h\x1b[?1049l");
    // A misbehaving child must not keep a closed dashboard alive indefinitely.
    setTimeout(() => process.exit(code), 200).unref();
  }
  let opening = false;
  async function openPane() {
    if (opening || !selected) return;
    opening = true;
    try {
      const result = await command(name, ["_ui-jump", selected]);
      if (result.code === 0) stop(); else { notice = result.stderr; draw(); }
    } catch (error) { notice = String(error); draw(); }
    finally { opening = false; }
  }
  // Node's decoder handles fragmented escape sequences and both normal and
  // application-mode arrow keys, without a second terminal protocol parser.
  function input(_text: string, key: Key) {
    if (quitting) return;
    notice = "";
    if (key.name === "q" || key.name === "escape" || (key.ctrl && key.name === "c")) { stop(); return; }
    if (key.name === "return" || key.name === "enter") { void openPane(); return; }
    if (key.name === "tab") {
      const names = crews();
      const next = names[(names.indexOf(name) + 1) % names.length];
      if (next && next !== name) {
        name = next; agents = []; tasks = []; messages = []; held = {}; ended = false; selected = ""; preview = ""; updated = "";
      }
      void refresh();
    } else if (["j", "k", "up", "down"].includes(key.name ?? "")) {
      const index = agents.findIndex((a) => a.role === selected);
      const offset = key.name === "j" || key.name === "down" ? 1 : -1;
      selected = agents[Math.max(0, Math.min(agents.length - 1, index + offset))]?.role ?? "";
      preview = ""; void peek();
    } else if (key.name === "r") void refresh();
    draw();
  }
  const timer = setInterval(() => void refresh(), 2000);
  process.once("exit", stop);
  const fatal = (error: unknown) => {
    stop(1);
    console.error(`crew ui: ${clean(String(error))}`);
    process.exitCode = 1;
  };
  process.once("uncaughtException", fatal);
  process.once("unhandledRejection", fatal);
  try {
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdout.write("\x1b[?1049h\x1b[?25l\x1b[2J");
    emitKeypressEvents(process.stdin);
    process.stdin.on("keypress", input);
    process.stdin.on("end", () => stop());
    process.stdout.on("resize", draw);
    process.once("SIGINT", () => stop());
    process.once("SIGTERM", () => stop());
    process.once("SIGHUP", () => stop());
    draw();
    await refresh();
  } catch (error) { fatal(error); }
}

if (import.meta.main) main().catch((error) => {
  console.error(`crew ui: ${clean(String(error))}`);
  process.exitCode = 1;
});
