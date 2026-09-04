# Evidence: dispatch settles a created workspace's roots instead of orphaning it

Branch `fm/fm-lane-dispatch-freshness-race`, target `766589c`, base `86e402c`, Node v26.7.0, Linux.

Every transcript below is the real `bin/fm-playbot-lanes.mjs` MCP server answering a real
`tools/call` for `dispatch`/`get_workspace_freshness` over stdio, against the suite's
fake Playbot DevTools endpoint and its SQLite state. The endpoint withholds a
just-created workspace's `workspace_roots` rows (for N ms, or permanently) and can
withdraw the `workspaces` row mid-wait, so the incident race is reproduced rather than
asserted.

## Files

- `dispatch-settle-transcript-base-86e402c.txt` - BEFORE. Base code, roots withheld 600ms.
  Dispatch refuses on its single read with the exact incident wording
  (`missing project root id(s): root-worker`), never sends, and leaves the workspace row
  and chat row behind with zero roots. Re-reading the same workspace 1.5s later shows the
  root present on the right branch - the "listed it seconds later and it was there" half of
  the 2026-09-04 report.
- `dispatch-settle-transcript-fixed.txt` - AFTER. The seven cases on this branch:
  1. roots registered late: dispatch waits 604ms across 5 reads, sends the task
     (`threads:send` present), and reports `workspaceSettle {waitedMs, reads, timeoutMs: 5000,
     outcome: "registered", note}`.
  2. roots never registered inside a 900ms budget: refusal names both created ids, says
     "still unregistered after 7 reads over 907ms", and states the `send_message` recovery;
     no `threads:send`, no `workspace:delete`, and both rows still persisted.
  3. the wait ends in a read that cannot resolve at all: refusal keeps the wait clause
     ("re-read it over 1059ms across 7 completed read(s)") and the recovery sentence.
  4. unresolvable landing branch: immediate refusal in 134ms with none of the retry wording.
  5. caller-supplied existing workspace with incomplete coverage and a 60s budget
     configured: unchanged message, answered in 49ms, so it was never waited on.
  6. roots already registered: 160ms, no `workspaceSettle` key, result shape unchanged.
  7. malformed budget: `configuration error: ...` in 51ms with no IPC at all, so nothing
     was created first.
- `fm-playbot-lanes-suite-174-checks.txt` - `bash tests/fm-playbot-lanes.test.sh` at target
  `766589c`: 174 ok, 0 not ok, 4m11s.

## How the transcripts were produced

`tests/fm-playbot-lanes.test.sh` was copied read-only to a scratch directory outside the
worktree, with the pretty-printed JSON-RPC response, the elapsed wall clock, the Playbot IPC
channels invoked, and the persisted workspace/thread/root rows dumped around each of the
seven settle checks, and an early exit after them. No file in the worktree was changed. The
BEFORE run is the same harness against a scratch copy of `bin/` whose
`fm-playbot-lanes.mjs` is `git show 86e402c:bin/fm-playbot-lanes.mjs`.
