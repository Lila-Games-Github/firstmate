# Playbot lane freshness: reviewer digest

Built from the end-user CLI transcript in `freshness-cli-transcript.md` (real Git fixture, landing branch `proto/godot/frog-pile`, remote also carries a `main` that must never be assumed).

## get_workspace_freshness per lane worktree

| workspace   | relation | ahead | behind | current | cleanFastForward | unlanded subjects                               |
|-------------|----------|-------|--------|---------|------------------|-------------------------------------------------|
| ws-clean    | equal    | 0     | 0      | true    | true             | (none)                                          |
| ws-ahead    | ahead    | 2     | 0      | true    | true             | "tune pile physics", "add frog hop animation"   |
| ws-behind   | behind   | 0     | 1      | false   | false            | (none)                                          |
| ws-diverged | diverged | 1     | 1      | false   | false            | "diverged lane work"                            |
| ws-partial (partial clone, tip absent locally) | behind-or-diverged | null | null | false | false | null (distanceKnown=false, presentLocally=false; tip still absent after the call => no lazy fetch) |

## Fail-closed errors observed (verbatim)

- landingBranch omitted: `get_workspace_freshness requires an explicit landingBranch` (CLI exit 1)
- workspace omitted: `get_workspace_freshness requires an explicit workspace selector by id, path, or name`
- worktree missing on disk: `freshness is unreadable for workspace ws-missing root root-frogpile: workspace root is missing: ...`
- `origin/main` remote-prefix ambiguity: `landing branch origin/main is ambiguous because origin is a configured remote; use refs/remotes/origin/main ...`
- malformed `PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS=abc`: `configuration error: PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS must be a positive integer` (not a landing-branch failure)
- list_parked_threads with landingBranch but no project: `landingBranch is only valid with an explicit project; use landingBranches for global scope`
- dispatch with landingBranch but no newWorkspace: `dispatch landingBranch is only valid together with newWorkspace; ...`
- dispatch newWorkspace with blank landingBranch: `dispatch requires an explicit landingBranch`

## Folded-in surfaces

- get_thread_status on "Hop animation": status pending_input, freshness.current=true, relation ahead, 2 unlanded subjects.
- list_parked_threads global scope with `landingBranches: {FrogPile: proto/godot/frog-pile}`: FrogPile candidate carries freshness; the uncovered partial-clone candidate has no freshness field at all.
- list_retirable_workspaces rows:

| workspace        | kind     | retirable | freshness.current | blockers                          |
|------------------|----------|-----------|-------------------|-----------------------------------|
| ws-frogpile-main | local    | false     | true              | local-workspace                   |
| ws-clean         | worktree | true      | true              |                                   |
| ws-behind        | worktree | true      | false             |                                   |
| ws-ahead         | worktree | false     | true              | active-threads, unlanded-commits  |
| ws-diverged      | worktree | false     | false             | unlanded-commits                  |
| ws-missing       | worktree | false     | null              | missing-root                      |

## Schema and zero-writes

- tools/list over MCP: all 21 tool inputSchemas have `type: object` and no root oneOf/anyOf/allOf/not; list_parked_threads states its rules in property descriptions.
- Repository `.git` content hash, ref hash and object counts were identical before and after every call above: the freshness surface wrote nothing to the workspace repository.
