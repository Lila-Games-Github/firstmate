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
2. Read the returned evidence for every candidate.
   A retirable verdict includes current remote landing commit evidence, exact head and ahead-commit subjects, every unarchived thread state, tracked paths classified against the tool's exact churn allowlist, and every untracked path.
   Stop on any blocker or unreadable evidence and preserve the workspace.
3. Select one exact workspace id from that fresh result.
   Retirement is destructive, so set `confirm: true` only when deletion of that specific workspace is already authorized and the immediately preceding evidence still supports it.
4. Call `retire_workspace` for that one id with the same explicit `landingBranch` and `confirm: true`.
   The tool re-runs the complete safety inspection immediately before invoking Playbot.
5. Require `deleted: true`, `verification.complete: true`, `postActionComplete: true`, and an appended audit record before calling the retirement shipshape.
   If `deleted: true` arrives with verification, lane cleanup, or audit problems, report that deletion happened but post-action work is incomplete and never retry the destructive call as though nothing happened.

Never replace either tool with raw CDP or IPC code, manual worktree-folder deletion, direct Playbot database edits, or `git worktree remove`.
Never add a bulk deletion loop or confirm more than one workspace per call.
