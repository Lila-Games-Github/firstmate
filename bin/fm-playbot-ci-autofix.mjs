#!/usr/bin/env node
// Watch open FrogPile PRs bound to Playbot workspaces and invoke Playbot's own
// Fix CI checks quick action only for clearly classified code failures.
// Usage: fm-playbot-ci-autofix.mjs poll [--dry-run]
//        fm-playbot-ci-autofix.mjs arm
// The poll prints one watcher wake line for infrastructure/unknown failures,
// uncertain dispatches, and the two-failed-round stop; routine work is silent.
// arm installs and hash-registers a private watcher check in FM_HOME/state.
// SQLite reservations are committed before dispatch; a lost response never
// retries the same head automatically. Requires Node.js 22.5 and gh-axi.

import { execFile, spawnSync } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { DatabaseSync } from "node:sqlite";

const exec = promisify(execFile);
const REPO = "Lila-Games-Github/frogpile";
const PR_URL = `https://github.com/${REPO}/pull/`;
const SCRIPT = path.resolve(process.argv[1]);
const LANES = process.env.FM_PLAYBOT_CI_AUTOFIX_LANES ?? path.join(path.dirname(SCRIPT), "fm-playbot-lanes.mjs");
const HOME = process.env.FM_HOME ?? path.resolve(path.dirname(SCRIPT), "..");
const STATE = process.env.FM_STATE_OVERRIDE ?? path.join(HOME, "state");
const DB_FILE = path.join(STATE, "playbot-ci-autofix.sqlite");
const DESKTOP_DB = path.join(process.env.PLAYBOT_DESKTOP_DIR ?? path.join(os.homedir(), ".config", "@playbot", "desktop"), "playbot.db");

function fail(message) { throw new Error(message); }
function assert(condition, message) { if (!condition) fail(message); }
function validSha(value) { return /^[0-9a-f]{40}$/.test(value ?? ""); }
function validPrUrl(number, url) { return Number.isSafeInteger(number) && number > 0 && url === `${PR_URL}${number}`; }

// gh-axi formats a scalar jq result as api_response.body. Base64 keeps its
// ToON presentation from changing the JSON boundary or truncating evidence.
function apiBody(output) {
  const match = /^  body: ([A-Za-z0-9+/=]+)$/m.exec(output);
  assert(match && /\n  truncated: false(?:\n|$)/.test(output), "gh-axi API result was missing or truncated");
  return JSON.parse(Buffer.from(match[1], "base64").toString("utf8"));
}

async function api(endpoint, query) {
  const { stdout } = await exec("gh-axi", ["api", `repos/${REPO}/${endpoint}`, "--jq", `${query}|@base64`], { timeout: 8000, maxBuffer: 2_000_000 });
  return apiBody(stdout);
}

function workspaces() {
  const db = new DatabaseSync(DESKTOP_DB, { readOnly: true });
  try {
    return db.prepare(`
      SELECT w.id AS workspace_id, p.id AS project_id, wr.project_root_id,
             wr.branch, wr.path, wr.pull_request_number AS number,
             r.remote_url
      FROM workspace_roots wr
      JOIN workspaces w ON w.id = wr.workspace_id
      JOIN project_roots pr ON pr.id = wr.project_root_id
      JOIN projects p ON p.id = pr.project_id
      JOIN repositories r ON r.id = pr.repository_id
      WHERE w.archive_state = 'active' AND p.deletion_state = 'active'
        AND wr.pull_request_number IS NOT NULL
    `).all().filter((row) => /^(https:\/\/github\.com\/|git@github\.com:)Lila-Games-Github\/frogpile(?:\.git)?$/.test(row.remote_url));
  } finally { db.close(); }
}

function threadsForWorkspace(workspaceId) {
  const db = new DatabaseSync(DESKTOP_DB, { readOnly: true });
  try {
    return db.prepare("SELECT id,title,agent_status,archived,ephemeral FROM workspace_threads WHERE workspace_id = ?").all(workspaceId);
  } finally { db.close(); }
}

function fixRunning(rows) {
  return rows.some((row) => row.ephemeral === 1 && row.archived !== 1
    && !["ready", "error"].includes(row.agent_status));
}

function classify(failures) {
  if (!failures.length) return "none";
  let own = false;
  for (const failure of failures) {
    const job = String(failure.name ?? "").toLowerCase();
    const steps = failure.steps;
    if (failure.conclusion !== "failure" || !Array.isArray(steps) || steps.length === 0) return "infrastructure";
    for (const stepName of steps) {
      const step = String(stepName).toLowerCase();
      // Infrastructure wins even when a job has an application-facing name.
      if (/runner|queue|setup|install|checkout|fetch|cache|secret|token|sign|upload|download|artifact|farm|gate|verdict|permission|auth|network|docker|container|dependency|release|deploy|publish|environment|provision/.test(`${job} ${step}`)) return "infrastructure";
      if (!/test|spec|assert|lint|docs?|description|gameplay|godot|unit|integration|quick checks|behavior/.test(`${job} ${step}`)) return "infrastructure";
      own = true;
    }
  }
  return own ? "own-code" : "infrastructure";
}

function stateDb() {
  fs.mkdirSync(STATE, { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(DB_FILE);
  db.exec("PRAGMA busy_timeout = 1000; PRAGMA synchronous = FULL; CREATE TABLE IF NOT EXISTS attempts (number INTEGER NOT NULL, head TEXT NOT NULL, workspace_id TEXT NOT NULL, chat_id TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(number,head)); CREATE TABLE IF NOT EXISTS alerts (number INTEGER NOT NULL, head TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(number,head,kind));");
  fs.chmodSync(DB_FILE, 0o600);
  return db;
}

function alert(db, number, head, kind, detail, dryRun) {
  if (!dryRun) {
    const changed = db.prepare("INSERT OR IGNORE INTO alerts VALUES (?,?,?)").run(number, head, kind).changes;
    if (!changed) return;
  }
  console.log(`playbot-ci-autofix: ${PR_URL}${number} head ${head}: ${detail}`);
}

function terminal(row) { return !row || row.archived === 1 || ["ready", "error"].includes(row.agent_status); }

async function checks(head) {
  const result = await api(`commits/${head}/check-runs?per_page=100`, "{total_count,checks:[.check_runs[]|{name,conclusion,status,details_url,started_at}]} ");
  assert(result.total_count === result.checks.length, "check run page was incomplete");
  const failed = result.checks.filter((check) => check.conclusion && check.conclusion !== "success" && check.conclusion !== "skipped" && check.conclusion !== "neutral");
  const withSteps = await Promise.all(failed.map(async (check) => {
    const match = /^https:\/\/github\.com\/Lila-Games-Github\/frogpile\/actions\/runs\/\d+\/job\/(\d+)$/.exec(check.details_url ?? "");
    if (!match) return { ...check, steps: null };
    const job = await api(`actions/jobs/${match[1]}`, "{name,conclusion,status,steps:[.steps[]|{name,conclusion}]} ");
    if (job.name !== check.name || job.conclusion !== check.conclusion) return { ...check, steps: null };
    return { ...check, steps: job.steps.filter((step) => step.conclusion === "failure").map((step) => step.name) };
  }));
  const staleQueued = result.checks.filter((check) => check.status === "queued" && Number.isFinite(Date.parse(check.started_at)) && Date.now() - Date.parse(check.started_at) > 30 * 60_000);
  return { total: result.total_count, complete: result.checks.every((check) => check.status === "completed" && check.conclusion), failures: withSteps, staleQueued };
}

async function laneCall(name, payload) {
  const { stdout } = await exec(process.execPath, ["--no-warnings", LANES, "call", name, JSON.stringify(payload)], {
    timeout: 15000, maxBuffer: 100_000,
    env: { ...process.env, PLAYBOT_LANES_CONTROLLER_ROOT: HOME },
  });
  const response = JSON.parse(stdout);
  assert(response.structuredContent && !response.isError, `${name} returned no confirmed result`);
  return response.structuredContent;
}

async function launch(project, workspace, number, branch, head) {
  const result = await laneCall("launch_fix_checks", { project, workspace, pullRequestNumber: number, expectedBranch: branch, expectedHead: head });
  assert(result.mechanism === "git-actions:launch" && result.thread?.id, "lane controller did not confirm Playbot quick action");
  return result.thread.id;
}

async function poll(dryRun) {
  const workspaceRows = workspaces();
  const pulls = await api("pulls?state=open&per_page=100", "[.[]|{number,url:.html_url,title,branch:.head.ref,head:.head.sha,base:.base.ref}]");
  assert(pulls.length < 100, "open PR page was full; pagination is required");
  const byNumber = new Map(pulls.map((pr) => [pr.number, pr]));
  const db = dryRun ? null : stateDb();
  const report = { source: { openPullRequests: pulls.length, boundWorkspaces: workspaceRows.length, checkRuns: 0 }, observed: { matched: 0, adoptionCandidates: 0, adopted: 0, checkRuns: 0, failedChecks: 0, ownCode: 0, infrastructure: 0, ready: 0, conflicts: 0, launched: 0 } };
  try {
    for (const [number, candidates] of Map.groupBy(workspaceRows, (row) => row.number)) {
      // First-time adoption runs Firstmate's backlog and PR registration
      // helpers. Bound that setup work so the watcher never kills a batch
      // halfway through an unbounded fleet of new PRs.
      const pr = byNumber.get(number);
      if (!pr || pr.base !== "development") continue;
      assert(validPrUrl(pr.number, pr.url) && validSha(pr.head), `invalid PR identity for ${number}`);
      const matches = candidates.filter((row) => row.branch === pr.branch);
      if (matches.length !== 1) { alert(db, number, pr.head, "workspace", "ambiguous or missing Playbot workspace binding", dryRun); continue; }
      const ws = matches[0];
      report.observed.matched += 1;
      const tickets = [...new Set([...String(pr.title ?? "").matchAll(/\bET-[0-9]+\b/g)].map((match) => match[0]))];
      if (tickets.length !== 1) { alert(db, number, pr.head, "ticket-unreadable", "PR title has no unambiguous ET ticket id for adoption", dryRun); continue; }
      const ticket = tickets[0];
      report.observed.adoptionCandidates += 1;
      const adoptionDeferred = !dryRun && report.observed.adopted >= 1
        && !fs.existsSync(path.join(STATE, `frogpile-playbot-pr-${number}.meta`));
      if (!dryRun && !adoptionDeferred) {
        try {
          const adopted = await laneCall("adopt_pr", { project: ws.project_id, workspace: ws.workspace_id, pullRequestNumber: number, url: pr.url, ticketId: ticket, expectedBranch: pr.branch, expectedHead: pr.head });
          if (adopted.adopted) report.observed.adopted += 1;
        } catch (error) { alert(db, number, pr.head, "adoption", `Firstmate PR adoption failed: ${error.message}`, false); continue; }
      }
      let detail;
      try { detail = await api(`pulls/${number}`, "{number,mergeable,mergeable_state,draft,base:.base.ref,head:.head.sha}"); }
      catch (error) { alert(db, number, pr.head, "pr-detail", `PR mergeability unreadable: ${error.message}`, dryRun); continue; }
      if (detail.head !== pr.head || detail.base !== "development") { alert(db, number, pr.head, "pr-drift", "PR changed during poll; retry on next poll", dryRun); continue; }
      if (detail.mergeable === false || detail.mergeable_state === "dirty") {
        report.observed.conflicts += 1;
        alert(db, number, pr.head, "merge-conflict", "merge conflict with development; Firstmate action needed", dryRun);
      }
      let result;
      try { result = await checks(pr.head); }
      catch (error) { alert(db, number, pr.head, "checks-unreadable", `check evidence unreadable: ${error.message}`, dryRun); continue; }
      report.source.checkRuns += result.total;
      report.observed.checkRuns += result.total;
      if (result.staleQueued.length) alert(db, number, pr.head, "queued-forever", `infrastructure: check queued over 30 minutes: ${result.staleQueued.map((check) => check.name).join(", ")}`, dryRun);
      report.observed.failedChecks += result.failures.length;
      if (!result.failures.length) {
        if (!adoptionDeferred && result.total > 0 && result.complete && detail.mergeable === true && !detail.draft) {
          try {
            const statuses = await api(`commits/${pr.head}/status`, "{state,statuses:[.statuses[]|{context,state}]}");
            if (statuses.statuses.length === 0 || statuses.state === "success") {
              report.observed.ready += 1;
              alert(db, number, pr.head, "ready", "ready-to-merge: all current-head checks green; Firstmate can merge through fm-pr-merge.sh", dryRun);
            }
          } catch (error) { alert(db, number, pr.head, "statuses-unreadable", `commit status evidence unreadable: ${error.message}`, dryRun); }
        }
        continue;
      }
      const classification = classify(result.failures);
      if (classification !== "own-code") {
        report.observed.infrastructure += 1;
        alert(db, number, pr.head, "infrastructure", `infrastructure or unknown CI failure: ${result.failures.map((x) => `${x.name} > ${(x.steps ?? []).join(", ") || "unknown step"}`).join("; ")}`, dryRun);
        continue;
      }
      report.observed.ownCode += 1;
      if (adoptionDeferred) continue;
      const threads = threadsForWorkspace(ws.workspace_id);
      if (dryRun) continue;
      const attempts = db.prepare("SELECT head,chat_id,status FROM attempts WHERE number = ? ORDER BY created_at, rowid").all(number);
      for (const prior of attempts) {
        if (prior.status !== "launched") continue;
        const chat = threads.find((row) => row.id === prior.chat_id);
        if (terminal(chat)) db.prepare("UPDATE attempts SET status = 'failed' WHERE number = ? AND head = ? AND status = 'launched'").run(number, prior.head);
      }
      const current = db.prepare("SELECT status FROM attempts WHERE number = ? AND head = ?").get(number, pr.head);
      const failedRounds = db.prepare("SELECT COUNT(*) AS count FROM attempts WHERE number = ? AND status = 'failed'").get(number).count;
      if (failedRounds >= 2) { alert(db, number, pr.head, "two-round-stop", `two failed Fix CI checks rounds with gpt-6.2-sol medium; inspect chat ids ${attempts.map((row) => row.chat_id).filter(Boolean).join(", ")} for actual token cost before another attempt`, false); continue; }
      if (current) {
        if (current.status === "reserved") alert(db, number, pr.head, "uncertain-dispatch", "prior dispatch outcome is uncertain; inspect Playbot before retrying", false);
        continue;
      }
      if (fixRunning(threads)) continue;
      // A local workspace behind the PR is unsafe to instruct. The lane action
      // repeats this check immediately before invoking Playbot.
      const local = spawnSync("git", ["-C", ws.path, "rev-parse", "HEAD"], { encoding: "utf8", timeout: 1500 });
      if (local.status !== 0 || local.stdout.trim() !== pr.head) { alert(db, number, pr.head, "head-mismatch", "Playbot workspace head differs from failing PR head", false); continue; }
      db.prepare("INSERT INTO attempts VALUES (?,?,?,?,?,?)").run(number, pr.head, ws.workspace_id, null, "reserved", new Date().toISOString());
      try {
        const chatId = await launch(ws.project_id, ws.workspace_id, number, pr.branch, pr.head);
        db.prepare("UPDATE attempts SET chat_id = ?, status = 'launched' WHERE number = ? AND head = ? AND status = 'reserved'").run(chatId, number, pr.head);
        report.observed.launched += 1;
      } catch (error) {
        alert(db, number, pr.head, "uncertain-dispatch", `Fix CI checks dispatch outcome uncertain: ${error.message}`, false);
      }
    }
  } finally { db?.close(); }
  console.error(JSON.stringify(report));
}

function arm() {
  assert(fs.existsSync(STATE) && fs.statSync(STATE).isDirectory(), `state directory missing: ${STATE}`);
  const check = path.join(STATE, "playbot-ci-autofix.check.sh");
  const quoted = (value) => `'${value.replaceAll("'", "'\\''")}'`;
  const content = `#!/usr/bin/env bash\nexec ${quoted(process.execPath)} --no-warnings ${quoted(SCRIPT)} poll\n`;
  const tmp = path.join(STATE, `.playbot-ci-autofix.${process.pid}.tmp`);
  fs.writeFileSync(tmp, content, { mode: 0o700, flag: "wx" });
  fs.renameSync(tmp, check);
  const registered = spawnSync(path.join(path.dirname(SCRIPT), "fm-check-register.sh"), ["playbot-ci-autofix"], { encoding: "utf8", env: { ...process.env, FM_HOME: HOME, FM_STATE_OVERRIDE: STATE } });
  assert(registered.status === 0, `check registration failed: ${registered.stderr}`);
  console.log(registered.stdout.trim());
}

const [command, flag] = process.argv.slice(2);
try {
  if (command === "poll" && (flag === undefined || flag === "--dry-run")) await poll(flag === "--dry-run");
  else if (command === "arm" && flag === undefined) arm();
  else fail("usage: fm-playbot-ci-autofix.mjs poll [--dry-run] | arm");
} catch (error) {
  if (command === "poll" && flag !== "--dry-run") console.log(`playbot-ci-autofix: poll failed: ${error.message}`);
  console.error(`playbot-ci-autofix error: ${error.message}`);
  process.exitCode = 1;
}
