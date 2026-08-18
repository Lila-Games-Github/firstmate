# Playbot Agent Integration Guide

**Purpose:** This document lets an external AI agent drive **Playbot** (the Playco "Playbot IDE" desktop app) programmatically — executing code inside a running game engine, automating the embedded browser, generating assets, and observing Playbot's own agent runs — **without using Playbot's GUI**.

**Audience:** an autonomous agent (or the code it writes). Everything here is concrete: endpoints, JSON-RPC shapes, schemas, and a ready-to-run client.

> Verified against Playbot **v0.78.0** (macOS, arm64) by connecting an external MCP client to the live app and by reading the app's bundled code and agent prompts. Bundle id `co.play.bot`.

---

## 1. TL;DR

Playbot runs a **local MCP server** (Model Context Protocol, Streamable-HTTP transport) on `127.0.0.1:<port>`. Any MCP-speaking agent can connect and call its tools. The two headline tools:

- **`execute_engine_code`** — run engine-native code (GDScript for Godot, C# for Unity) inside the live game engine session.
- **`execute_browser_script`** — run a Playwright script against Playbot's embedded browser.

Plus AI asset generation and read-only introspection of Playbot's own agent threads.

**Hard requirement:** the Playbot desktop process must be **running**, and for the engine tools a **project must be open** (the engine runs headless — no game window appears). There is no standalone/daemon mode and no cold REST API.

```
┌─ your agent ─┐   MCP over HTTP    ┌─ Playbot.app (Electron, must be running) ─┐
│  MCP client  │ ───────────────▶   │  127.0.0.1:<port>/mcp                      │
└──────────────┘   JSON-RPC 2.0     │    ├─ execute_engine_code  → Godot/Unity   │
                                     │    ├─ execute_browser_script → Playwright  │
                                     │    ├─ generate_assets / *_asset            │
                                     │    └─ app_* (read app + agent threads)     │
                                     └────────────────────────────────────────────┘
```

---

## 2. Architecture (what you're talking to)

- Playbot is an **Electron app** embedding an **OpenAI Codex agent** (`@openai/codex`) and an **MCP server** (`@modelcontextprotocol/sdk`).
- The MCP server + game engine are started **lazily, in-process**, when a project/engine session becomes active. They live inside the Electron main process — kill the app and the server is gone.
- The game engine (Godot or Unity) is launched **headless** (no visible game window). The Electron window can be minimized.
- Playbot's *own* built-in agent talks to this same MCP server. You are connecting to the exact interface Playbot itself uses.

---

## 3. Prerequisites & lifecycle (read this first)

| Requirement | Why | How to check |
|---|---|---|
| Playbot.app process running | Hosts the MCP server | `pgrep -f "MacOS/Playbot"` |
| A project **open** in Playbot | `execute_engine_code` only registers when an engine session is live | See tool-count check below |
| macOS user session (not headless SSH-only) | Electron GUI process | — |

**Key behavior — the engine tool is conditional:**
- **No project open →** 13 tools, **`execute_engine_code` is ABSENT**.
- **Project open (engine live) →** 14 tools, `execute_engine_code` present.

So always `tools/list` after connecting and confirm `execute_engine_code` exists before relying on it. `execute_browser_script` and all `app_*`/asset tools are always available while the app runs.

The server binds to a **random port** and rebinds on every app restart — never hardcode it. Discover it every run (§4).

---

## 4. Discovering the endpoint

The MCP server listens on `127.0.0.1:<port>`. Two independent discovery methods; use whichever works, prefer (A):

### Method A — port file (present only while a project is open)
Playbot writes the live port to:
```
~/.playbot/projects/<project-hash>/.port     # plain text, e.g. "54144"
```
`<project-hash>` is per-project. Grab the most recent one:
```sh
cat "$(ls -t ~/.playbot/projects/*/.port 2>/dev/null | head -1)"
```
The same folder contains `godot-headless.pid` (or unity equivalent) when the engine is live. Playbot also passes the port to processes it spawns as the env var **`PLAYBOT_PORT`**.

### Method B — probe listening sockets (works even with no project open)
The Playbot main process opens **two** `127.0.0.1` LISTEN sockets:
- one is Electron's **DevTools** port → `GET /` returns HTML (`Content shell remote debugging`) — *ignore it*.
- one is the **MCP server** → `GET /` returns the literal string `ok`.

```sh
PID=$(pgrep -f "Contents/MacOS/Playbot" | head -1)
for p in $(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" 2>/dev/null | awk '/127.0.0.1/{split($9,a,":"); print a[2]}'); do
  [ "$(curl -s -m2 http://127.0.0.1:$p/)" = "ok" ] && echo "MCP_PORT=$p"
done
```

**Health check:** `GET http://127.0.0.1:<port>/` → body `ok` (200). That is the confirmation you're on the MCP server.

---

## 5. The MCP wire protocol

- **Transport:** MCP **Streamable HTTP**. Endpoint path: `/mcp`. JSON-RPC 2.0.
- **Auth:** none for the local server. (The `x-playbot-api-key` header seen elsewhere is only for Playbot's *cloud* backend, not this local endpoint.)
- **Required request headers:**
  - `Content-Type: application/json`
  - `Accept: application/json, text/event-stream`  ← must include the SSE type; responses often come back as `text/event-stream`.
- **Session:** the `initialize` response returns an **`mcp-session-id`** response header. Echo it as a request header on every subsequent call.
- **Workspace-root context (query string on `/mcp`):** identifies which engine project the tools target. Two forms:
  - `?roots=<url-encoded JSON array>&primaryRootId=<id>`
  - `?contextId=<id>` (only for ids Playbot itself minted — external clients use `roots`)

  Each root object: `{ "rootId": string, "name": string, "path": string, "engineKind"?: "godot"|"unity" }`
  - `rootId` can be any non-empty string you choose (e.g. `"r1"`); `primaryRootId` must equal one of them.
  - `path` **must be the absolute path of the open project** for `execute_engine_code` routing to hit the live engine session.
  - You may also initialize with **no** `roots` at all (empty context) to use the `app_*` tools, then call `app_get_project_settings` to learn the real root paths, and reconnect with a proper `roots` value for engine work.

### Handshake sequence
1. `POST /mcp?roots=...&primaryRootId=r1`  body: `initialize` → capture `mcp-session-id` header + read result.
2. `POST /mcp?...` (same query, with session header) body: `notifications/initialized` (a notification — no `id`, no response expected).
3. `POST /mcp?...` (with session header) `tools/list`, then `tools/call`, etc.

Response bodies may be a bare JSON object **or** an SSE stream — in the SSE case the JSON-RPC payload is the value after `data:` on its own line. The client in §6 handles both.

> Only `tools/list` and `tools/call` are supported. `prompts/list` and `resources/list` return `-32601 Method not found`. Server advertises `capabilities: { tools: { listChanged: true } }`.

---

## 6. Drop-in MCP client (Node.js, zero dependencies)

Save as `playbot-client.mjs`. Works with Node ≥ 18.

```javascript
import http from 'node:http';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';

// ---- discovery ---------------------------------------------------------
export function discoverPort() {
  // A) newest project .port file
  try {
    const dir = `${os.homedir()}/.playbot/projects`;
    const files = fs.readdirSync(dir)
      .map(d => `${dir}/${d}/.port`)
      .filter(f => fs.existsSync(f))
      .map(f => ({ f, m: fs.statSync(f).mtimeMs }))
      .sort((a, b) => b.m - a.m);
    for (const { f } of files) {
      const p = fs.readFileSync(f, 'utf8').trim();
      if (p) return Number(p);
    }
  } catch {}
  // B) probe the Playbot main process's LISTEN sockets for the one that says "ok"
  try {
    const pid = execSync('pgrep -f "Contents/MacOS/Playbot" | head -1').toString().trim();
    const out = execSync(`lsof -nP -iTCP -sTCP:LISTEN -a -p ${pid}`).toString();
    for (const line of out.split('\n')) {
      const m = line.match(/127\.0\.0\.1:(\d+)/);
      if (m) { try { if (httpGetSync(m[1]) === 'ok') return Number(m[1]); } catch {} }
    }
  } catch {}
  throw new Error('Playbot MCP port not found — is Playbot running with a project open?');
}
function httpGetSync(port) {
  return execSync(`curl -s -m 2 http://127.0.0.1:${port}/`).toString().trim();
}

// ---- client ------------------------------------------------------------
export class PlaybotMCP {
  constructor({ port, roots = [], primaryRootId = '' }) {
    this.port = port;
    const qs = new URLSearchParams();
    if (roots.length) { qs.set('roots', JSON.stringify(roots)); qs.set('primaryRootId', primaryRootId); }
    this.path = '/mcp' + (qs.toString() ? `?${qs}` : '');
    this.sid = null;
    this.id = 0;
  }
  _post(body) {
    return new Promise((resolve, reject) => {
      const data = Buffer.from(JSON.stringify(body));
      const headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Content-Length': data.length,
      };
      if (this.sid) headers['mcp-session-id'] = this.sid;
      const req = http.request(
        { host: '127.0.0.1', port: this.port, path: this.path, method: 'POST', headers },
        res => {
          if (res.headers['mcp-session-id']) this.sid = res.headers['mcp-session-id'];
          let buf = '';
          res.on('data', c => (buf += c));
          res.on('end', () => resolve(this._parse(buf)));
        });
      req.on('error', reject);
      req.write(data); req.end();
    });
  }
  _parse(body) {
    const t = body.trim();
    if (!t) return null;                          // notification / empty
    if (t.startsWith('{')) return JSON.parse(t);
    const line = t.split('\n').find(l => l.startsWith('data:'));
    return line ? JSON.parse(line.slice(5).trim()) : { raw: body };
  }
  async initialize() {
    const r = await this._post({
      jsonrpc: '2.0', id: ++this.id, method: 'initialize',
      params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'external-agent', version: '1' } },
    });
    await this._post({ jsonrpc: '2.0', method: 'notifications/initialized' }); // no id
    return r.result;
  }
  async listTools() {
    const r = await this._post({ jsonrpc: '2.0', id: ++this.id, method: 'tools/list', params: {} });
    return r.result.tools;
  }
  async callTool(name, args) {
    const r = await this._post({ jsonrpc: '2.0', id: ++this.id, method: 'tools/call', params: { name, arguments: args } });
    if (r.error) throw new Error(`${name}: ${JSON.stringify(r.error)}`);
    return r.result; // { content: [{type:'text', text:'...'}], isError?: bool }
  }
}

// ---- example -----------------------------------------------------------
// const port = discoverPort();
// const pb = new PlaybotMCP({ port,
//   roots: [{ rootId:'r1', name:'prototype-game', path:'/abs/path/to/project', engineKind:'godot' }],
//   primaryRootId:'r1' });
// await pb.initialize();
// console.log((await pb.listTools()).map(t => t.name));
// const res = await pb.callTool('execute_engine_code', {
//   explanation: 'read godot version and main scene',
//   executionEnvironment: 'current',
//   code: '@tool\nextends RefCounted\nfunc run():\n\treturn { "v": Engine.get_version_info(), "main": ProjectSettings.get_setting("application/run/main_scene","") }',
// });
// console.log(res.content[0].text);
```

**Bootstrapping the project path** (if you don't know it): construct `PlaybotMCP` with no roots, `initialize()`, call `app_get_project_settings` (returns roots with absolute `path` and `projectRootId`), then rebuild the client with those roots for engine calls.

---

## 7. Tool reference

Every `tools/call` returns `{ content: [{ type:'text', text: <string> }], isError?: boolean }`. `execute_engine_code` returns whatever its runner `return`s, serialized to text. Tool descriptions ask for an `explanation` field on most tools: **a 6–15 word phrase stating the intended outcome** (required for `execute_engine_code` and `execute_browser_script`).

### Availability matrix
| Tool | Available when | Purpose |
|---|---|---|
| `execute_engine_code` | project/engine open only | run code in the live engine |
| `execute_browser_script` | always | Playwright vs embedded browser |
| `generate_assets` | always | AI-generate images/sfx/music/video/3D |
| `wait_for_asset_generation` | always | block until an asset batch finishes |
| `search_assets` / `get_asset` | always | query prior generations |
| `app_get_current_account` | always | signed-in account (no key) |
| `app_get_project_settings` | always | roots, repos, branches (read-only) |
| `app_list_workspaces` | always | worktrees + `projectRootId`s |
| `app_list_workspace_scripts` | always | runnable scripts for a workspace |
| `app_list_models` | always | selectable models (id/name/provider) |
| `app_list_threads` | always | Playbot's own agent threads + status |
| `app_get_thread_snapshot` | always | one thread's live status |
| `app_read_thread` | always | read a thread's conversation/answer |

### 7.1 `execute_engine_code`  ⭐ core
Runs engine-native code in the active session. **Only the returned value is sent back to you** — `print()`/console output is NOT captured.

Input schema:
```jsonc
{
  "code": "string (required)",                 // full runner script (see language rules below)
  "explanation": "string (required)",           // 6-15 word outcome phrase
  "executionEnvironment": "current|edit|play",  // default "current"
                                                //   current = keep engine's current mode
                                                //   edit    = ensure edit mode (persistent changes)
                                                //   play    = enter play mode (runtime testing)
  "instanceType": "" | "interactive" | "headless", // default "" (normal routing)
                                                //   ""          = let Playbot route
                                                //   interactive = the user's open editor (selection etc.)
                                                //   headless    = the headless session
  "root": "string"                              // root id or exact root name; required only in multi-root
                                                // workspaces. The tool description lists available roots,
                                                // e.g. "prototype-game (godot)".
}
```

**Godot (GDScript) runner rules** — from Playbot's own engine prompt, follow exactly:
- Submit **one complete GDScript runner script**, not a snippet body.
- The script MUST use `@tool`, `extends RefCounted`, and define `func run()`.
- Do **not** use `extends EditorScript`, `func _run()`, or a top-level `return`.
- `return <value>` **inside `run()`** sends data back through the tool. Prefer returning a Dictionary/Array. `print()` writes to the Godot console and can yield empty tool output even on success.
- Available in the runner: `EditorInterface`, `ProjectSettings`, `ResourceLoader`, `ResourceSaver`, `Engine`, etc.
- Runs **synchronously on Godot's main thread**. Never `OS.execute`, sleep, poll, wait on signals, or run unbounded loops. Keep each call to a short editor/scene operation.
- Leave `instanceType` empty unless the user refers to their manually-opened editor.
- Never hand-edit `.tscn`/`.tres`/`.res`/`.godot/`/`.import/`; load, modify, and save via Godot APIs + `ResourceSaver`.

Minimal Godot example:
```gdscript
@tool
extends RefCounted

func run():
    return {
        "version": Engine.get_version_info(),
        "main_scene": ProjectSettings.get_setting("application/run/main_scene", "")
    }
```

**Unity:** the equivalent driver targets Unity via C# through the Unity bridge; the general contract (return value is your only output, no blocking, don't hand-edit serialized `.unity`/`.prefab`/`.asset`/`.meta`) is the same. Confirm the exact C# runner contract from the `unity` engine prompt / tool description at runtime.

### 7.2 `execute_browser_script`
Runs a **Playwright script body** against Playbot's embedded browser.
```jsonc
{
  "script": "string (required)",     // Playwright script body (has access to a page/context)
  "explanation": "string (required)",// 6-15 word outcome phrase
  "timeoutMs": 30000,                 // default 30000, max 120000
  "root": "string"                    // engine project to target (multi-root only)
}
```

### 7.3 `generate_assets` (+ `wait_for_asset_generation`, `search_assets`, `get_asset`)
AI generation of game assets. Buckets: `images`, `sfx`, `music`, `videos`, `models3d` — each an array of specs; populate one or more in a single call for a coordinated batch. Returns a **`batchId`** immediately (runs in background). Call `wait_for_asset_generation({ batchId })` only at a real dependency boundary — it blocks until every asset reaches a terminal state.

Image spec highlights:
```jsonc
{
  "prompt": "string (required)",
  "targetPath": "assets/sprites/hero.png",   // snake_case; extension forced by type
  "transparent": true,                          // REQUIRED: true=alpha, false=opaque
  "aspectRatio": "1:1|4:3|16:9|3:4|9:16",
  "specificSize": { "width": <=1536, "height": <=1536 },  // exact dims, overrides aspectRatio
  "linkedAssets": ["path-or-url"],              // reference images: PNG/JPEG/WebP/GIF only
  "model": "fal-ai/nano-banana-pro | fal-ai/nano-banana-2 | fal-ai/gpt-image-1.5 | openai/gpt-image-2 | fal-ai/flux-2/flash | fal-ai/flux-2/turbo | fal-ai/flux-2-max | fal-ai/bytedance/seedream/v4 | fal-ai/qwen-image-edit-2511"  // omit unless a model is explicitly requested
}
```
`sfx`/`music` specs take `duration` (music also `instrumental`); `videos` take `duration`, `aspectRatio`, `resolution`, `generateAudio`, and a starting-frame `linkedAssets`. Use `search_assets({query})` before claiming a prior generation is gone; `get_asset({id})` returns full metadata for a generation id.

### 7.4 `app_*` — introspection & watching Playbot's own agent
> **⚠️ VERIFIED LIMITATION:** For an **external** MCP client that supplies its own `roots` query param, every `app_*` tool returns **`"No project is in scope for this connection"`**. These tools resolve the project from Playbot's own **internally-minted `contextId`**, which an external client cannot forge (the `rootId`s you pass don't match Playbot's registered `projectRootId`s). In practice **the `app_*` tools are not usable by an external roots-based client.** `execute_engine_code` and `execute_browser_script` *do* work externally because they route by the live engine-session path, not by the app project registry. To observe Playbot's own agent threads from outside, read the SQLite state directly instead (see §8).

Read-only (only reachable from Playbot's own agent / an in-app context):
- `app_get_project_settings` → roots (with absolute `path`, `projectRootId`), repositories, branches, remotes.
- `app_list_workspaces` → worktrees with clickable `url`, roots, branches.
- `app_list_threads({ workspaceId? })` → agent threads with persisted status + `url`.
- `app_get_thread_snapshot({ threadId })` → live status; whether it needs approval/input; `isLive`.
- `app_read_thread({ threadId, turnLimit?, includeOutputs?, maxOutputCharsPerItem? })` → conversation + final answer without resuming it.
- `app_list_models` → selectable model ids/names/providers.

> There is **no** MCP tool to *start* a new Playbot agent thread. Starting a chat is done via the CLI/GUI (§8). Via MCP you drive the engine/browser/assets directly and *observe* agent threads.

---

## 8. Driving Playbot's built-in agent (and model selection)

If instead of calling tools yourself you want **Playbot's own agent** (running on the GPT-5.6 family) to do the work, the intended non-interactive trigger is:

```sh
# Launcher installed by the app (may not be on PATH); or call the app binary directly:
~/.playbot/bin/playbot "open the main scene and run 50 tap tests, report crashes" \
  -C /abs/path/to/project --mode default     # --mode default|plan

# equivalent direct form:
/Applications/Playbot.app/Contents/MacOS/Playbot --playbot-cli "<prompt>" -C <dir> --mode default
```

> **⚠️ VERIFIED: this CLI handoff silently no-ops — treat it as non-functional.** The wrapper always exits `0` (it backgrounds the app), but that tells you nothing. Tested against **two different projects** — a git-worktree project **and** a plain Godot project (repo `.git` not even at the project root) — both with the app fully warm and the built-in agent otherwise responsive (a GUI-typed message got a reply). **Neither created a chat.** So the `--playbot-cli` second-instance → `newThread` intent is not being delivered to the renderer in this build/environment; it is *not* merely a worktree edge case. Suspected code path: the handler does `qo(cwd)` → `u(repository.id, cwd)` → `Ir({kind:"newThread", …})`; any failure there logs `"[main] Failed to open Playbot CLI chat"` / `"Failed to find workspace for Playbot CLI path"` to the app's own stderr (not your terminal) and bails. **Do not trust exit code 0.** After invoking, verify a new thread actually appeared (poll the SQLite below); if not — which is the observed norm — fall back to one of:
> - **GUI (reliable):** type the prompt into a chat in the Playbot window — the built-in agent works there regardless of worktree layout.
> - **Direct MCP (reliable, headless):** you (the external agent) call `execute_engine_code` / `execute_browser_script` yourself per §6–§7 to do the work, rather than delegating to Playbot's agent.
> - Try `-C` pointing at the repo's **main working tree** rather than a linked worktree, which may let `u()` resolve.

**Verifying / watching the built-in agent from outside** (since `app_*` MCP tools are unavailable externally, read the SQLite state directly — read-only):
```sh
# a new chat/thread and its live status + model:
sqlite3 ~/Library/Application\ Support/@playbot/desktop/playbot.db \
  "SELECT id,title,agent_status,execution_model,updated_at FROM workspace_threads ORDER BY updated_at DESC LIMIT 5;"
# the agent's own run state (thread + first user message + model):
sqlite3 ~/.playbot/harness/state_5.sqlite \
  "SELECT id,title,model,substr(first_user_message,1,80),datetime(created_at,'unixepoch','localtime') FROM threads ORDER BY created_at DESC LIMIT 5;"
# live agent activity / tool calls (per thread_id):
sqlite3 ~/.playbot/harness/logs_2.sqlite \
  "SELECT datetime(ts,'unixepoch','localtime'),substr(feedback_log_body,1,140) FROM logs WHERE thread_id='<id>' ORDER BY id DESC LIMIT 30;"
```
When it works, the CLI opens/starts a chat visible in the Playbot window and the agent acts through the same tools described here (engine, browser, assets).

### 8.1 ✅ WORKING METHOD — drive the agent + chat via the Electron DevTools (CDP) port

Since the CLI handoff is unreliable, the **verified** way to start/continue a chat and make Playbot's built-in agent do work is to automate the renderer through Playbot's **Chrome DevTools Protocol** endpoint. This mimics a human typing in the chat, so it works whenever the GUI works.

**How it works**
- Playbot's Electron process exposes a CDP endpoint on a `127.0.0.1` port. **It is a *different* port from the MCP server:** the MCP port answers `GET /` with `ok`; the **DevTools port** answers `GET /json/version` with a JSON blob containing `webSocketDebuggerUrl` and serves `GET /json` (the list of debuggable `page` targets).
- The project window's renderer (`file://…/main_window/index.html`) contains the chat composer — a TipTap `contenteditable` with class `.ui-tiptap-composer` — and a button with `aria-label="Send message"`.
- Attach to that page target's `webSocketDebuggerUrl`, then:
  1. focus the composer (`el.focus()` via `Runtime.evaluate`),
  2. type with CDP **`Input.insertText`** (plain `innerText=` does *not* update ProseMirror state — `Input.insertText` does),
  3. click the **Send message** button.
- That starts (or continues) a real agent thread — identical to a user message. Read the agent's replies from the **rollout transcript** JSONL at `threads.rollout_path` (`~/.playbot/harness/sessions/YYYY/MM/DD/rollout-*-<threadId>.jsonl`), which contains user/assistant messages, reasoning summaries, and tool calls.

**Verified (v0.79.0):** sending *"make all enemies render as circles instead of squares…"* this way spawned thread **"Render All Enemies as Circles"** (`gpt-5.6-sol`, `xhigh`), `agent_status=working`, and the agent began inspecting scenes and editing the project — all without the GUI CLI and without touching the keyboard.

**Ready-to-use tool:** `bin/playbot-drive.mjs` in this repo (Node ≥ 20, zero deps):
```sh
node bin/playbot-drive.mjs send "make all enemies render as circles instead of squares"
node bin/playbot-drive.mjs status                 # recent threads + agent_status (working/ready)
node bin/playbot-drive.mjs read  [threadId]       # print the conversation transcript (newest thread if omitted)
node bin/playbot-drive.mjs watch [threadId]       # poll until the agent goes idle, then print the transcript
node bin/playbot-drive.mjs approve [once|session] # click a pending file-write/command approval dialog
```
It auto-discovers the DevTools port (the Playbot LISTEN socket whose `/json/version` returns a `webSocketDebuggerUrl`), finds the page target that has the composer, and drives it.

**Caveats**
- Requires a **project window open** in Playbot (the composer must exist). The engine can be headless; the app window can be minimized but must not be closed.
- Relies on Playbot's Electron **remote-debugging port being enabled** — it is in v0.78–0.79. If a future build ships with it disabled, this method stops working (fall back to typing in the GUI, or direct MCP engine calls per §6–§7).
- The model used is whatever the chat has selected (per §8's model note) — still not settable programmatically.
- Selectors (`.ui-tiptap-composer`, `aria-label="Send message"`) are UI-version-specific; re-inspect `GET /json` targets if a Playbot update changes them.

**Model selection — important limitation:**
- The chat-creation payload is only `{ initialPrompt, planMode }`. **There is no way to choose the model via CLI, deep link, or MCP.**
- The model is a **persisted, per-chat GUI setting** (stored in `workspace_threads.planning_model` / `execution_model`, with separate `*_reasoning_level` and `*_service_tier`). Set it once in the IDE (e.g. `gpt-5.6-sol`, reasoning `xhigh`); new chats inherit the current selection.
- Selectable models observed: `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, `gpt-5.3-codex-spark`, `gpt-5.2`, `codex-auto-review`. Query live via `app_list_models`.
- These run through the **"Playbot Gateway"**, an OpenAI **Responses-API-compatible** proxy (`https://*.play.bot/.../responses`) authenticated by a short-lived, account-scoped token minted from Playbot's backend. Treat direct gateway use as out of scope unless Playco sanctions it.

**Remote control:** the app has a `remote_control_enrollments` table (websocket URL + account/server enrollment), indicating an official path to drive the desktop agent remotely over a WebSocket. Not documented here; explore only if you intend to use Playco's sanctioned remote-control feature.

### 8.2 Workspace management over the same CDP transport (verified v0.93.1, Linux)

The renderer's `window.electronAPI.invoke(channel, payload)` bridge (the transport from §8.1, and the one `bin/fm-playbot-lanes.mjs` uses) also reaches Playbot's workspace IPC module. Handlers register dynamically via `ipcMain.handle` on the channel `<module.name>:<key>` with zod-validated payloads. Confirmed by extracting `.vite/build/main.js` from the running app's `app.asar` (v0.93.1) and locating the `workspace` module registration and its schemas:

- **`workspace:create`** — payload is a **strict** zod discriminated union on `strategy`:
  - `{ strategy: "project", projectId, branch?, name?, baseBranch?, rootOverrides? }` — creates a workspace with a worktree on **every** project root. `baseBranch` selects the branch each worktree is taken from; a missing `branch` gets a generated name; `name` is the display name. This is the strategy Firstmate's lane tools use.
  - `{ strategy: "quick", projectId, projectRootId?, baseRef?, branch?, expectedCommit?, targetBranch?, pullRequestProviderId?, pullRequestNumber?, mode, rootOverrides? }` — single-root provisioning where `mode` selects one of the `open`/`from`/`copy` provisioning functions. Confirmed in the schema but not exercised by Firstmate.
  - Both objects are `.strict()`: any extra key, or an empty string for a `min(1)` field, is rejected. `branch`/`name`/`baseBranch` are `trim().min(1)` — omit them rather than sending blanks.
  - The handler **awaits provisioning** and returns the fresh workspace record (with its `id`); on default-root failure it rolls the workspace back and throws.
- **`workspace:delete`** — `{ workspaceId, preserveWorktrees? }` (default `false`). Refuses to delete the Local workspace, and refuses to delete the selected workspace unless a replacement exists.
- Related channels confirmed present in the same module: `workspace:update`, `workspace:archive`, `workspace:select`, `workspace:renameBranch`, and `workspaceRoots:list`. Avoid `workspace:select` from automation — it changes what the user is looking at.

Firstmate's `playbot_lanes` MCP exposes this as the `create_workspace` tool plus a `newWorkspace` option on `create_chat`/`dispatch` (see `docs/playbot-lanes.md`); prefer those over raw CDP calls.

---

## 9. Limitations & gotchas

- **App must be running.** No daemon, no cold API. If the process is down, start it (`open -a Playbot`) — but that shows the GUI; there is no headless-app mode (only the *engine* is headless).
- **`execute_engine_code` requires an open project.** With none open it is not in `tools/list`. Always re-check.
- **Port is random and changes on restart.** Discover every run (§4). Two LISTEN sockets exist — only the one returning `ok` is the MCP server; the other is Electron DevTools.
- **Engine code returns only its `return` value.** `print()` is not captured. Return structured data.
- **Engine runners are synchronous & main-thread.** No sleeping/polling/loops/`OS.execute`.
- **Don't hand-edit serialized engine files.** Go through the engine tools / engine APIs.
- **Model can't be chosen programmatically** (see §8).
- **Session id is per connection.** Reuse it for the life of the connection; a new `initialize` starts a new session.
- **`explanation` is required** on the two `execute_*` tools.

---

## 10. Security notes

- The local MCP server is **unauthenticated** and bound to `127.0.0.1`. Any local process can call it while Playbot runs. Do not expose the port beyond loopback.
- Playbot stores a **plaintext auth JWT** at `~/Library/Application Support/@playbot/desktop/playbot.db` (`app_settings.auth.apiKey`), alongside account email/id. That token mints gateway tokens — treat the file as a secret; do not read, log, or transmit it.

---

## 11. Cheat sheet

```sh
# 1. Is Playbot up?
pgrep -f "Contents/MacOS/Playbot"

# 2. Find MCP port (project open):
cat "$(ls -t ~/.playbot/projects/*/.port | head -1)"
#    or probe: the 127.0.0.1 LISTEN socket whose GET / returns "ok"

# 3. Health:
curl -s http://127.0.0.1:<port>/            # -> ok

# 4. Connect (Node): discoverPort() -> new PlaybotMCP({port, roots, primaryRootId})
#    -> initialize() -> listTools() -> callTool(name, args)

# 5. Confirm engine tool present:
#    listTools() includes "execute_engine_code"  (only when a project is open)

# 6. Or drive the built-in agent (the ~/.playbot/bin/playbot CLI silently no-ops, §8):
node bin/playbot-drive.mjs send "<prompt>"   # CDP method, §8.1
```

MCP endpoint: `POST http://127.0.0.1:<port>/mcp?roots=<json>&primaryRootId=<id>`
Headers: `Content-Type: application/json`, `Accept: application/json, text/event-stream`, `mcp-session-id: <from initialize>`
Methods: `initialize` → `notifications/initialized` → `tools/list` / `tools/call`. No auth.

