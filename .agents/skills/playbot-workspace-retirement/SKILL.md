---
name: playbot-workspace-retirement
description: >-
  Agent-only guarded procedure for inspecting and retiring landed Playbot workspaces through the Playbot lane MCP.
  Use before deciding whether a Playbot workspace is safe to retire or deleting one.
metadata:
  internal: true
---

# Playbot workspace retirement

Use the `playbot_lanes` MCP for the entire retirement workflow.

1. Call `list_retirable_workspaces` for one exact project with the branch that the work was required to land on as explicit `landingBranch`.
   Derive that branch from the task's accepted delivery contract and never substitute a repository default.
   Pass `registryProject` with the project's exact name in `data/projects.md`; a registered `local-only` posture makes the main clone's local landing branch the landing evidence when that clone is a root of the selected Playbot project, because such projects never push their landing branch.
2. Read the returned evidence for every candidate.
   A retirable verdict includes current landing commit evidence, exact head and ahead-commit subjects, every unarchived thread state, no live firstmate task record naming the workspace, tracked paths classified against the tool's exact churn allowlist, and distinct exact-path evidence for every untracked or ignored path.
   Ignored build output and Playbot's native addon tree are reported as discardable and never block; an orphaned root whose directory is gone is registration cleanup and does not block, unless a Git registration still records a HEAD that is not proven landed.
   Otherwise stop on any blocker or unreadable evidence and preserve the workspace, including when an unarchived thread state is missing or unrecognized.
   A `live-task-record` blocker names the firstmate record still pointing at the workspace; resolve that task or poll through its own owner, never by deleting the record.
3. Select one exact workspace id from that fresh result.
   Retirement is destructive, so set `confirm: true` only when deletion of that specific workspace is already authorized and the immediately preceding evidence still supports it.
4. Call `retire_workspace` for that one id with the same explicit `landingBranch`, the same `registryProject`, and `confirm: true`.
   The tool re-runs the complete safety inspection immediately before invoking Playbot.
   When the captain has explicitly authorized discarding that workspace's local changes, and its `discard.possible` evidence is true, pass `discardLocalChanges` with the captain's words verbatim as `authorization`, only the blocker codes the captain's words cover in `allow`, and, for `unlanded-commits`, every exact commit id from the fresh evidence in `commits`.
   Never invent or broaden that authorization; the audit records it verbatim with every discarded path and commit.
5. Require `deleted: true`, `verification.complete: true`, `postActionComplete: true`, and an appended audit record before calling the retirement shipshape.
   If Playbot accepted the IPC but `deleted: false` or `verification.complete: false`, report the partial action from the returned removed, added, remaining, and uncertain reconciliation evidence, preserve the retry warning, and never retry blindly.
   If `deleted: true` arrives with lane cleanup or audit problems, report that deletion was verified but post-action work is incomplete and never retry the destructive call as though nothing happened.
   If Playbot rejects the deletion, read the returned reconciliation and audit evidence for every database row, directory, and Git registration, including exact root-row deltas, report any partial removal exactly, and never retry blindly.

Never replace either tool with raw CDP or IPC code, manual worktree-folder deletion, direct Playbot database edits, or `git worktree remove`; the tool itself removes an inventoried orphaned directory that Playbot cannot.
Never add a bulk deletion loop or confirm more than one workspace per call.
