// Run a built crew board's shipped inline script under a minimal DOM shim and
// print what it rendered, so the page is asserted through the real template
// rather than by reading its source. Optionally points at one row the way the
// captain does - type a note, press the row's button, press Send - against a
// recording stand-in for the Lavish page API.
//
// Usage: node crew-board-render-harness.mjs <built-board.html> <now-epoch> [<task-id> [<note>]]
// Prints one JSON document:
//   { stats:[{n,label}], sections:[{group,title,rows:[{task,id,badge,tone,title,sub,note,since,pr}]}],
//     prompts:[{prompt,options}], sent, sendBar:{hidden,text}, error }
import { readFileSync } from "node:fs";

const [file, nowArg, pointTask, pointNote] = process.argv.slice(2);
const html = readFileSync(file, "utf8");
Date.now = () => Number(nowArg) * 1000;

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.listeners = {};
    this._text = "";
    this.hidden = false;
    this.value = "";
    this.classList = {
      add: (c) => { if (!this.className.split(/\s+/).includes(c)) this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type) { (this.listeners[type] || []).forEach((fn) => fn({ target: this })); }
}

const byId = new Map();
const node = (id) => {
  if (!byId.has(id)) byId.set(id, new Node("div"));
  return byId.get(id);
};
node("crew-board-data").textContent = html
  .split('<script id="crew-board-data" type="application/json">')[1]
  .split("</script>")[0];

const prompts = [];
let sent = 0;
globalThis.document = { createElement: (tag) => new Node(tag), getElementById: node };
globalThis.window = {
  lavish: {
    queuePrompt: (prompt, options) => prompts.push({ prompt, options: { ...options, element: options.element?.getAttribute("data-task") } }),
    sendQueuedPrompts: () => { sent += 1; },
  },
};
globalThis.setInterval = () => 0;

const script = html.slice(html.lastIndexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const find = (n, cls) => {
  const out = [];
  const walk = (x) => { for (const c of x.children) { if (c.classList.contains(cls)) out.push(c); walk(c); } };
  walk(n);
  return out;
};
const one = (n, cls) => find(n, cls)[0];

if (pointTask) {
  const row = find(node("cb-sections"), "cb-row").find((r) => r.getAttribute("data-task") === pointTask);
  if (row) {
    const input = one(row, "cb-point__note");
    input.value = pointNote || "";
    input.fire("input");
    one(row, "cb-point__button").fire("click");
    node("cb-send-button").fire("click");
  }
}

const stats = node("cb-stats").children.map((t) => ({
  n: Number(one(t, "cb-stat__num")?.textContent),
  label: one(t, "cb-stat__label")?.textContent,
}));
const sections = node("cb-sections").children
  .filter((s) => s.tagName === "section")
  .map((s) => ({
    group: s.getAttribute("data-group"),
    title: s.children[0].textContent,
    rows: find(s, "cb-row").map((r) => {
      const badge = one(r, "fm-badge");
      return {
        task: r.getAttribute("data-task"),
        id: r.getAttribute("id"),
        badge: badge?.textContent,
        tone: badge?.className.replace(/.*fm-badge--/, "").trim(),
        title: one(r, "cb-row__title")?.textContent,
        sub: one(r, "cb-row__sub")?.textContent,
        note: one(r, "cb-row__note")?.textContent ?? null,
        since: one(r, "cb-row__since")?.textContent,
        pr: one(r, "cb-row__pr")?.getAttribute("href") ?? null,
      };
    }),
  }));
const empty = find(node("cb-sections"), "cb-empty").map((n) => n.textContent);
const error = find(node("cb-main"), "cb-error").map((n) => n.textContent).join(" ");

process.stdout.write(JSON.stringify({
  stats, sections, empty, prompts, sent,
  sendBar: { hidden: node("cb-send").hidden, text: node("cb-send-text").textContent },
  error,
}) + "\n");
