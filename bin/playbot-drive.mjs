#!/usr/bin/env node
// Drive Playbot's built-in agent + chat via the Electron DevTools (CDP) port.
// Cross-platform (Windows / macOS / Linux). Node >= 20 (global fetch + WebSocket), zero deps.
// Usage:
//   node playbot-drive.mjs send "<message>"     -> types into the chat composer and clicks Send
//   node playbot-drive.mjs status               -> lists recent threads + agent_status
//   node playbot-drive.mjs read [threadId]      -> prints the conversation transcript (newest thread if omitted)
//   node playbot-drive.mjs watch [threadId]     -> polls until the agent goes idle, printing new messages
//   node playbot-drive.mjs approve [once|session] -> click a pending approval dialog
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();

// ---------- platform-specific locations ----------
function desktopDir() {
  if (process.platform === 'win32') return path.join(process.env.APPDATA, '@playbot', 'desktop');
  if (process.platform === 'darwin') return path.join(HOME, 'Library', 'Application Support', '@playbot', 'desktop');
  return path.join(HOME, '.config', '@playbot', 'desktop'); // linux best-guess
}
const APPDB   = path.join(desktopDir(), 'playbot.db');                     // workspace_threads (GUI/agent status)
const STATEDB = path.join(HOME, '.playbot', 'harness', 'state_5.sqlite'); // threads + rollout_path

// ---------- sqlite (execFile: no shell, no quoting hell) ----------
function sql(db, q) {
  try { return execFileSync('sqlite3', ['-json', db, q], { encoding: 'utf8' }).trim(); }
  catch { return ''; }
}
function sqlJSON(db, q) { const o = sql(db, q); return o ? JSON.parse(o) : []; }

// ---------- DevTools (CDP) discovery ----------
async function devtoolsBase() {
  // Electron writes the active remote-debugging port here (first line = port).
  const portFile = path.join(desktopDir(), 'DevToolsActivePort');
  const candidates = [];
  try {
    const p = fs.readFileSync(portFile, 'utf8').split('\n')[0].trim();
    if (p) candidates.push(p);
  } catch {}
  for (const port of candidates) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(1500) });
      const j = await r.json();
      if (j.webSocketDebuggerUrl) return `http://127.0.0.1:${port}`;
    } catch {}
  }
  throw new Error(`DevTools port not found via ${portFile} — is Playbot running with a project window open?`);
}
async function pageTargets(base) {
  const r = await fetch(`${base}/json`);
  return (await r.json()).filter(t => t.type === 'page');
}

// ---------- minimal CDP client ----------
async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0; const pend = new Map();
  ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } };
  const send = (method, params = {}) => new Promise(res => { const i = ++id; pend.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  await send('Runtime.enable');
  const evaluate = async expr => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true, userGesture: true }); return r.result && r.result.result ? r.result.result.value : r.result; };
  return { send, evaluate, close: () => ws.close() };
}
async function chatWindow() {
  const base = await devtoolsBase();
  let pendingQuestion = false;
  for (const t of await pageTargets(base)) {
    const c = await cdp(t.webSocketDebuggerUrl);
    const has = await c.evaluate(`!!document.querySelector('.ui-tiptap-composer,[contenteditable="true"]')`);
    if (has) return c;
    // composer unmounts while the visible thread shows a question/approval card
    pendingQuestion = !!(await c.evaluate(`!!document.querySelector('[data-testid="chat-panel"]') && [...document.querySelectorAll('button')].some(b=>/^(Skip|\\d+\\s*Other)$/.test((b.innerText||'').replace(/\\s+/g,' ').trim()))`)) || pendingQuestion;
    c.close();
  }
  if (pendingQuestion) throw new Error('Chat composer not mounted: the visible thread is awaiting a question/approval response. Answer it (GUI or `approve`) or open a new thread, then retry.');
  throw new Error('No Playbot chat window found (open a project first)');
}

// ---------- commands ----------
async function cmdSend(message) {
  const before = sqlJSON(STATEDB, `SELECT count(*) n FROM threads`)[0]?.n ?? 0;
  const c = await chatWindow();
  await c.evaluate(`(()=>{const el=document.querySelector('.ui-tiptap-composer,[contenteditable="true"]');el.focus();return document.activeElement===el;})()`);
  await c.send('Input.insertText', { text: message });
  const typed = String(await c.evaluate(`document.querySelector('.ui-tiptap-composer,[contenteditable="true"]').innerText`));
  if (!typed.trim()) { c.close(); throw new Error('Text did not insert into composer'); }
  const clicked = await c.evaluate(`(()=>{const b=[...document.querySelectorAll('button')].find(x=>x.getAttribute('aria-label')==='Send message');if(!b)return 'no-button';if(b.disabled)return 'disabled';b.click();return 'clicked';})()`);
  c.close();
  console.log(`typed ${typed.length} chars; send: ${clicked}`);
  // wait briefly for the new thread
  for (let i = 0; i < 15; i++) {
    await new Promise(r => setTimeout(r, 1000));
    const rows = sqlJSON(STATEDB, `SELECT id,title FROM threads ORDER BY created_at DESC LIMIT 1`);
    const n = sqlJSON(STATEDB, `SELECT count(*) n FROM threads`)[0]?.n ?? 0;
    if (n > before) { console.log(`new thread: ${rows[0].id}  "${rows[0].title}"`); return; }
  }
  console.log('(sent; no new thread row yet — may be continuing an existing thread)');
}
function cmdStatus() {
  const t = sqlJSON(APPDB, `SELECT title,agent_status,execution_model,updated_at FROM workspace_threads ORDER BY updated_at DESC LIMIT 8`);
  for (const r of t) console.log(`${(r.agent_status || '').padEnd(14)} ${(r.execution_model || '').padEnd(12)} ${r.title}`);
}
function newestThread() { return sqlJSON(STATEDB, `SELECT id,rollout_path FROM threads ORDER BY created_at DESC LIMIT 1`)[0]; }
function rolloutPath(id) { return sqlJSON(STATEDB, `SELECT rollout_path FROM threads WHERE id=${JSON.stringify(id)}`)[0]?.rollout_path; }
function readTranscript(id) {
  const rp = id ? rolloutPath(id) : newestThread()?.rollout_path;
  if (!rp || !fs.existsSync(rp)) { console.log('no transcript'); return; }
  for (const ln of fs.readFileSync(rp, 'utf8').split('\n')) {
    if (!ln.trim()) continue; let o; try { o = JSON.parse(ln); } catch { continue; }
    const it = o.payload || o;
    if (it.type === 'message' || it.role) { const role = it.role || it.type; const text = (it.content || []).map(x => x.text || x.content || '').join(' ').trim(); if (text) console.log(`\n[${role}] ${text.slice(0, 600)}`); }
    else if (it.type === 'function_call' || it.name) { const nm = it.name || it.function?.name; if (nm) console.log(`  -> tool: ${nm} ${(it.arguments || '').toString().slice(0, 80)}`); }
    else if (it.type === 'reasoning' && it.summary) { const s = (it.summary || []).map(x => x.text || '').join(' ').trim(); if (s) console.log(`  ~ ${s.slice(0, 160)}`); }
  }
}
async function cmdWatch(id) {
  id = id || newestThread()?.id;
  for (let i = 0; i < 120; i++) {
    const st = sqlJSON(APPDB, `SELECT agent_status FROM workspace_threads WHERE id LIKE 'chat-%' ORDER BY updated_at DESC LIMIT 1`)[0]?.agent_status;
    process.stdout.write(`\r[watch] status=${st}   `);
    if (st && st !== 'working' && st !== 'thinking') { console.log('\n--- agent idle ---'); break; }
    await new Promise(r => setTimeout(r, 3000));
  }
  readTranscript(id);
}

// Approve a pending file-write / command approval dialog. mode: 'once' (Yes) or 'session' (Yes, don't ask again — default).
async function cmdApprove(mode = 'session') {
  const base = await devtoolsBase();
  let done = false;
  for (const t of await pageTargets(base)) {
    const c = await cdp(t.webSocketDebuggerUrl);
    const has = await c.evaluate(`document.body.innerText.includes('Do you want to allow')||document.body.innerText.includes("don't ask again")`);
    if (!has) { c.close(); continue; }
    const res = await c.evaluate(`(()=>{const norm=s=>(s||'').replace(/\\s+/g,' ').trim();
      const want=${mode === 'once' ? '/^\\\\d?\\\\s*Yes$/i' : '/don.t ask again/i'};
      let cand=[...document.querySelectorAll('button,[role=button],[role=option],li,div,a')].filter(e=>want.test(norm(e.innerText))&&e.childElementCount<=3);
      cand.sort((a,b)=>norm(a.innerText).length-norm(b.innerText).length);
      if(!cand[0])return 'no-option';
      cand[0].click();
      const s=[...document.querySelectorAll('button,[role=button]')].find(e=>norm(e.innerText)==='Submit'); if(s)s.click();
      return 'approved: '+norm(cand[0].innerText).slice(0,50);})()`);
    console.log(res); c.close(); done = true; break;
  }
  if (!done) console.log('no pending approval dialog found');
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === 'send') await cmdSend(rest.join(' '));
else if (cmd === 'status') cmdStatus();
else if (cmd === 'read') readTranscript(rest[0]);
else if (cmd === 'watch') await cmdWatch(rest[0]);
else if (cmd === 'approve') await cmdApprove(rest[0] === 'once' ? 'once' : 'session');
else console.log('usage: playbot-drive.mjs send "<msg>" | status | read [threadId] | watch [threadId] | approve [once|session]');

