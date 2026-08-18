#!/usr/bin/env node
// Validate Playbot's exact Codex thread identity for the Firstmate session lock.
// Usage: fm-playbot-session-lock.mjs identity <root>
//        fm-playbot-session-lock.mjs alive <session-id> <root>
// identity prints the current CODEX_THREAD_ID only when Playbot persists that
// unarchived thread under the requested project root.
// alive exits 0 for that same live persisted shape, 1 for absent/archived, and
// 2 for database or ambiguity errors so callers can fail closed.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

let DatabaseSync;

function desktopDir() {
  if (process.env.PLAYBOT_DESKTOP_DIR) return path.resolve(process.env.PLAYBOT_DESKTOP_DIR);
  if (process.platform === "win32") return path.join(process.env.APPDATA ?? "", "@playbot", "desktop");
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support", "@playbot", "desktop");
  return path.join(os.homedir(), ".config", "@playbot", "desktop");
}

function canonicalPath(value) {
  if (!value) return "";
  let result = path.resolve(String(value).replace(/^\\\\\?\\/, ""));
  try {
    result = fs.realpathSync.native(result);
  } catch {
    // Persisted roots remain comparable while temporarily unavailable.
  }
  result = result.replace(/[\\/]+$/, "");
  return process.platform === "win32" ? result.toLowerCase() : result;
}

function sessionState(sessionId, root) {
  const dbPath = path.join(desktopDir(), "playbot.db");
  if (!fs.existsSync(dbPath)) throw new Error(`Playbot database not found: ${dbPath}`);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const rows = db.prepare(`
      SELECT
        t.session_id,
        t.archived,
        w.archive_state,
        p.deletion_state,
        wr.path AS root_path
      FROM workspace_threads t
      JOIN workspaces w ON w.id = t.workspace_id
      JOIN projects p ON p.id = w.project_id
      JOIN workspace_roots wr ON wr.workspace_id = w.id
      WHERE t.session_id = ?
    `).all(sessionId);
    const matching = rows.filter((row) => canonicalPath(row.root_path) === canonicalPath(root));
    if (matching.length === 0) return "absent";
    if (matching.length > 1) throw new Error(`Playbot session ${sessionId} maps to multiple matching roots`);
    const row = matching[0];
    return row.archived === 0 && row.archive_state === "active" && row.deletion_state === "active"
      ? "live"
      : "absent";
  } finally {
    db.close();
  }
}

function main() {
  const command = process.argv[2];
  if (command === "identity") {
    const root = process.argv[3];
    const sessionId = process.env.CODEX_THREAD_ID;
    if (!root || !sessionId || !process.env.PLAYBOT_APP_RUN_ID) process.exit(1);
    if (sessionState(sessionId, root) !== "live") process.exit(1);
    process.stdout.write(`${sessionId}\n`);
    return;
  }
  if (command === "alive") {
    const sessionId = process.argv[3];
    const root = process.argv[4];
    if (!sessionId || !root) process.exit(2);
    process.exit(sessionState(sessionId, root) === "live" ? 0 : 1);
  }
  throw new Error(`Unknown command: ${command ?? ""}`);
}

try {
  ({ DatabaseSync } = await import("node:sqlite"));
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}
