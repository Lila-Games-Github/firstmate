# Playbot lanes

Playbot lanes let a normal terminal or one Playbot chat control chats in Playbot projects without selecting those chats in the UI.
A Playbot-chat controller can register durable worker routes and receive background completion notifications.
A normal-terminal controller has no Playbot chat to wake, so `dispatch` arms that worker's firstmate watcher poll for it and it supervises through bounded status and conversation reads.

`bin/fm-playbot-lanes.mjs` is the single owner of the tool schemas, private state format, install command, hook behavior, and exact failure rules.
Run its `doctor` command for bounded local diagnostics and its `install` command to register the server and hooks in Playbot's managed Codex home.
Run its `setup` command to ensure the complete integration is ready in one fail-closed operation.
A normal terminal can invoke any lane tool through `node --no-warnings bin/fm-playbot-lanes.mjs call <tool> '<arguments-json>'`; the command returns the same result object as the MCP `tools/call` path.
Passing `-` instead of inline JSON reads the arguments object from standard input.

## Captain startup trigger

The exact captain phrase `Ahoy Playbot!` loads the internal `ahoy-playbot` skill and runs the `setup` command.
Setup checks readiness first and makes no changes when the integration is already healthy.
When readiness fails, it installs the MCP definition and hooks, asks the running Playbot process to reload its MCP servers, and checks again without restarting Playbot.
This initialization never creates, selects, messages, closes, or archives a chat, and it never starts an agent session.
It reports ready only when Playbot DevTools is reachable, exactly one owned PreToolUse hook and Stop hook are installed, and Playbot reports the enabled MCP with no error and the expected tool count.
The configured controller root is diagnostic identity for Playbot-chat callers and does not need to be open as a Playbot project for normal-terminal control.

## Identity and project routing

The MCP lists projects globally rather than inheriting Playbot's current-project filter.
Project ids and root paths are stable selectors.
A project name is accepted only when it identifies exactly one project, so two projects named `prototype-game` are never silently conflated.

The global PreToolUse hook records the Codex `session_id` immediately before a `playbot_lanes` tool call made by a Playbot chat.
The MCP maps that session id through Playbot's persisted `workspace_threads.session_id` field to identify that controller chat.
It never treats the visibly selected or most recently active chat as sufficient identity evidence.
If concurrent calls make the marker ambiguous, the tool refuses and asks for a retry instead of choosing a chat.
When no fresh Playbot marker exists, the caller is an external normal terminal and no Playbot project identity is required.
When a marker does exist, every cross-project MCP operation verifies that the Playbot chat belongs to the configured controller project, so worker chats cannot use the globally installed server as an unrestricted control plane.

A `thread` selector identifies one chat on its own, so the workspace it lives in is derived from the match rather than guessed.
Supplying `workspace` narrows the search and still fails closed when the chat is not in it, and omitting `workspace` searches the whole project's active workspaces.
An archived workspace is out of that default scope, exactly as it is out of an explicit `workspace` selector's, so its chats are neither addressable by default nor able to collide with an active chat's title.
An ambiguous exact title or duplicate id is reported rather than resolved, and the not-found message names the scope that was searched.

`list_threads` returns a `workspaces` array containing every active workspace in the requested project, including active workspaces with no chats.
Each workspace retains its `selected` field and owns its own `threads` array, so UI selection remains visible without narrowing fleet supervision.
The optional `workspace` selector deliberately narrows the result to one active workspace; omitting it remains the project-wide MCP call.
Archived workspaces are always excluded, while `includeArchived` controls archived chats inside the active workspaces that remain in scope.
Workspace and thread ordering is deterministic for identical persisted state.

## Chat-creation API detection

Playbot 0.94.0 removed the standalone `threads:openThread` and `workspace:create` IPC handlers and folded chat and workspace creation into one strict `threads:launch` call whose destination either targets an existing workspace or creates a new one.
The server detects which API the running Playbot exposes with a side-effect-free `threads:launch` probe whose payload every known Playbot schema rejects before any handler code can run.
A missing-handler rejection selects the pre-0.94 channels, any other rejection selects `threads:launch`, and an accepted probe is an explicit error rather than a guess, so 0.93.x installs keep working without silent assumptions.
Every launch passes `activate: false`, so chat and workspace creation never select a workspace or change UI focus on 0.94.0; the Playbot-side thread id is generated by Playbot and read back from the launch result.
The `doctor` command reports the detected API as `chatCreation`.

## Workspaces

Every workspace root's current `branch` is visible in `list_projects`, so a caller can see which branch each workspace is on before targeting it.

`create_workspace` creates a new workspace in one project using Playbot's project strategy so every project root gets a worktree.
`baseBranch` chooses the branch each worktree is taken from, `branch` names the new working branch, and `name` labels the workspace; Playbot generates a branch name and display name when they are omitted.
On 0.94.0 and newer, workspace creation only exists inside chat launch, so `create_workspace` launches one setup chat with the new workspace and immediately archives that chat; no agent session ever starts in it.
The tool waits for Playbot to persist the workspace, then returns the created workspace's id, name, and per-root paths and branches read back from the application state.
On 0.93.x, Playbot's own `workspace:create` handler marks the new workspace selected within its project, so creating one inside the project the captain is actively viewing changes which workspace that project shows; on 0.94.0 the non-activating launch leaves the selection untouched.

`create_chat` and `dispatch` accept an optional `newWorkspace` object with the same `name`, `baseBranch`, and `branch` fields.
When present, the workspace and the chat are created together in one launch on 0.94.0, or sequentially through the legacy channels on 0.93.x, which isolates dispatched work on its own branch in one call.
`newWorkspace` is mutually exclusive with `workspace`, and `dispatch` additionally rejects combining it with `thread`, because a just-created workspace has no existing chats.
When `newWorkspace` is absent, existing workspace selection behavior is unchanged.

### Workspace freshness

`get_workspace_freshness` requires an explicit active workspace selector by id, root path, or unique name plus an explicit `landingBranch`.
The landing branch is always explicit because a repository's default branch may not be where lane work lands.
Callers must pass the real landing target, such as `proto/godot/frog-pile`; the tool never substitutes `main`, a repository default, or the workspace's base branch.
When a branch's first path component is also a configured remote name, the short form is ambiguous and rejected; use `refs/remotes/<remote>/<branch>` to name the remote branch explicitly.
Each root reports `worktreePath`, the exact `head` commit and subject, the current remote-backed `landingBranchTip`, `relation`, `distanceKnown`, `commitsAhead`, `commitsBehind`, `current`, `headIsCleanFastForwardOfLandingTip`, and `unlandedCommits` with each commit's exact subject.
When `landingBranchTip.presentLocally` is true, `distanceKnown` is true, `relation` is `equal`, `ahead`, `behind`, or `diverged`, and the commit counts and unlanded commit records are exact.
When the remotely observed tip is not present locally, `landingBranchTip.presentLocally` and `distanceKnown` are false, `relation` is `behind-or-diverged`, both commit counts and `unlandedCommits` are null, and both current fields are false rather than guessed.
`current` and `headIsCleanFastForwardOfLandingTip` are true when the landing tip is an ancestor of the workspace head, including when the workspace has legitimate commits ahead.
They are false when the workspace is behind or diverged.
The aggregate workspace `current` is true only when every root is current.
Workspace root rows must cover every project root exactly once; missing, extra, or duplicate project-root IDs, paths that do not name an exact Git worktree, repositories whose common Git directory does not match the persisted project root, shallow or unreadable repositories, ambiguous remotes, missing landing branches, and inconsistent Git results are explicit errors rather than false or guessed readings.
Freshness reads the remote tip with bounded `git ls-remote` and performs zero writes to the workspace repository, including when that tip is absent locally.
Lazy object fetching is disabled on every freshness Git call, so a partial clone reports a missing landing tip as not present locally rather than downloading it on demand.
The remote bound defaults to 15 seconds and is overridable through `PLAYBOT_LANES_REMOTE_GIT_TIMEOUT_MS`, a positive integer of milliseconds up to 300000; a malformed value is validated once and reported as an explicit configuration error rather than a landing-branch failure.

`get_thread_status` requires the same explicit `landingBranch` and returns this reading as `freshness` beside the persisted thread and lane state.
`list_parked_threads` accepts either an exact `project` with its required `landingBranch`, or global scope with both fields omitted.
Global scope accepts an optional `landingBranches` map from project id, root path, or unique name to that project's explicit landing branch.
These rules are stated in the tool's schema descriptions and enforced when the tool is called; the schema root is a plain object without combinators so every MCP client can load it.
It places `freshness` only on candidates whose owning project has an explicit target, and uncovered projects are returned without freshness rather than compared against another project's branch.
The parked-chat detection remains a persisted, non-resuming read, while freshness consults Git and current remote branch evidence.

### Workspace retirement

`list_retirable_workspaces` inspects every active workspace in one exact project against a required `landingBranch`.
It resolves that caller-named branch to current remote evidence rather than reading or guessing a repository default; a configured upstream can identify the remote but never replace the caller's branch name.
It reports the shared `freshness` reading, the verified landing commit when locally readable, each workspace root's exact head, every known ahead commit and subject including an empty or non-UTF-8-encoded subject, every unarchived thread state, and all tracked, untracked, and ignored paths.
Every readable row uses the full workspace-level freshness shape with `workspace`, `landingBranch`, `current`, and `roots`, including rows whose retirement inspection found a blocker.
A row whose freshness could not be read for every root reports `freshness` as `null` beside the blocker recording the cause, never a partial reading with null root entries: `landing-branch-unresolvable` names a remote landing-branch resolution failure, while `freshness-unreadable` names a local repository failure such as a shallow repository, graft or replacement-ref ancestry overrides, an unreadable Git object, or unreadable ahead/behind counts.
Local workspaces receive the shared zero-write freshness reading but skip root retirement inspection, Git status, and submodule publication checks because they are never retirable.
Local workspaces, missing roots, unreadable Git state, an unresolvable landing branch, a `working` or `pending_input` chat, any missing or unrecognized unarchived chat state, an ahead commit, a tracked modification outside Playbot's exact churn allowlist, a POSIX executable-mode change hidden by `core.fileMode=false`, assume-unchanged or skip-worktree index flags, replacement refs, and an in-progress merge, rebase, cherry-pick, revert, or sequencer are blocking evidence rather than a bare false verdict.
Tracked-content inspection compares each index object with the actual regular file, symlink target, or populated submodule head using Git's clean filters, so stat-cache shortcuts cannot produce a clean verdict.
Git evidence clears inherited repository, worktree, index, object-store, namespace, shallow-file, replacement-base, and command-line configuration overrides before inspecting the caller-selected root.
Initialized submodules receive the same recursive tracked, untracked, ignored, index-flag, and operation-state inspection, and persisted per-worktree submodule Git directories are inspected even after the submodule is deinitialized or removed from the index.
A populated submodule that cannot be inspected blocks retirement, as does a persisted submodule stash, staged index change, index flag, in-progress Git operation, or ref-, reflog-, or repository-pseudoref-reachable object not proven reachable from a stable fresh snapshot of the configured remotes.
Repository pseudoref discovery enumerates every top-level hash-only object record plus every structured `FETCH_HEAD` row, so irregular commit and tree state such as `MERGE_AUTOSTASH` and `AUTO_MERGE` cannot disappear behind a fixed name list.
Recognized head, autostash, and automatic-merge pseudorefs must parse completely; malformed mixed evidence makes the persisted repository unreadable and blocks retirement.
Every ordinary local submodule ref outside the reconstructible `refs/remotes/` cache must also match the same ref name and object identity in at least one fresh remote snapshot, while every local symbolic ref blocks because a matching resolved object cannot prove its target metadata was published.
Revision evidence disables replacement objects, and any `refs/replace/*` or repository graft metadata blocks inspection instead of being allowed to rewrite the ancestry used for a deletion verdict.
Untracked and ignored files also block retirement and are returned in distinct exact-path fields and blockers, including every file beneath an explicitly ignored directory, because the tracked-churn allowlist never classifies them.
The allowlist is eight literal repository-relative paths returned as `trackedChurnAllowlist`: seven files under `prototype-game/addons/playbot/` plus `prototype-game/project.godot` that Playbot's editor integration rewrites across unrelated worktrees.
No directory, extension, basename, or broader pattern is treated as churn.
Path matching preserves Git pathname identity, so a literal backslash in a POSIX filename cannot alias a slash in an allowlisted path.

`retire_workspace` accepts only one exact active workspace id returned by inspection, the same explicit `landingBranch`, and `confirm: true`.
There is no bulk destructive form.
It repeats the complete inspection immediately before action and calls Playbot's own `workspace:delete` IPC with `preserveWorktrees: false`; it never deletes a folder or changes Playbot's database itself.
A failed immediate recheck returns that complete structured inspection, including the blocking chat states and tracked, untracked, and ignored paths, without calling the destructive IPC.
After Playbot reports success, the tool verifies that the `workspaces` row, every `workspace_roots` row, worktree directory, and Git worktree registration are gone, then deactivates every durable lane route naming the workspace and serializes a complete mode-0600 private audit record under the lane state directory.
The audit append rolls back an incomplete trailing record, rejects an unreadable completed record, syncs the file, and syncs its directory entry on first creation before reporting success.
Each root resolves remote evidence independently so worktree-specific Git configuration cannot borrow another root's remote or commit.
The immediate inspection captures whether each Git worktree registration existed, and post-action reconciliation reports a registration as removed only when that captured registration changed from present to absent.
Retirement enumerates every route file strictly and validates its version, filename-bound id, active flag, endpoint identities, workspace identities, and timestamps, so malformed or unreadable route state makes post-action cleanup incomplete instead of disappearing from the result and audit.
Durable route mutations share one cross-process lock whose complete owner record is atomically published with acquisition and includes a timezone- and locale-independent process start identity.
Its acquisition, dead-owner recovery, and ownership-checked release run through a transactional shared gate, so concurrent reapers cannot unlink a replacement generation, release cannot race a contender's observation, and short owner-record writes cannot publish an unreadable lock.
The serialized mutation preserves a concurrent retirement deactivation and re-reads every matching route as inactive before post-action cleanup can be complete.
That record names the time, project, workspace, workspace paths, exact root heads, explicit landing branch and remotely verified landing commits, affected lane routes, IPC outcome, and removal verification.
If the IPC succeeds but database, directory, or Git-registration verification is incomplete, the tool returns `deleted: false`, `partialAction: true`, `postActionComplete: false`, the full reconciliation, and a warning against blind retry.
That incomplete outcome preserves matching active routes because the workspace still exists or its removal is uncertain.
If removal verification is complete but route cleanup or audit append fails, the tool returns `deleted: true` with `postActionComplete: false` and exact problems because the workspace deletion is verified even though post-action work remains incomplete.
If Playbot rejects the deletion after removing anything, the tool compares every exact database root row with its pre-action baseline, reconciles every directory and NUL-parsed Git worktree registration, appends a partial-action audit, returns the exact removed, added, remaining, and uncertain evidence with the error, and warns against a blind retry.

## Lane lifecycle

`dispatch` resolves an existing worker chat or creates an empty one and sends the task through Playbot's own `threads:send` IPC, whose payload is unchanged across 0.93.x through 0.95.x.
With `newWorkspace`, it requires an explicit `landingBranch`, creates the isolated workspace and worker chat, reads the workspace's `freshness`, and returns that evidence with the dispatch result.
`landingBranch` is valid only together with `newWorkspace`; passing it when dispatching into an existing workspace or thread is rejected before any chat is created or message sent, because freshness for an existing workspace is read with `get_workspace_freshness` or `get_thread_status`.
The landing branch is validated before any workspace is created, and an unreadable post-creation workspace stops dispatch before the task is sent with an error naming the workspace and chat that were already created.
The message can enter a non-selected project and does not require changing UI focus.
For a Playbot-chat caller, `dispatch` also records a durable worker-to-controller route.

A normal-terminal caller has no chat to wake, so polling is the only supervision available to it, and `dispatch` arms that poll itself rather than naming tools and leaving the caller to remember.
It writes `state/<taskId>.check.sh` under the configured controller root, binds it through `bin/fm-check-register.sh`, and reports the outcome in the result's `supervision` block: `mode`, the `taskId` and whether it came from the argument or the workspace, the `check` path, and `armed`.
The armed poll reads persisted Playbot state only, so it contacts Playbot not at all and resumes nothing.
It stays silent while the worker is `working` and prints one line when the worker parks on a card, stops without one, becomes unreadable, or cannot be read at all, which is why a poll that failed reports the failure instead of passing as silence.
A persisted `pending_input` is a candidate on exactly the terms `list_parked_threads` describes, so the wake line says so and names `get_thread_card` as the confirming read.
Every branch that can print fires on a difference from the last observation and never on a condition merely still being true, with one deliberate exception: a parked worker keeps firing each check interval, because answering the card is what resolves it and a worker that is still parked still needs its supervisor.
A delivered worker that stopped or became unreadable is news exactly once, so that is reported on the change into it and the poll then retires itself, removing the check, its trust binding, and its private `state/<taskId>.lane-poll` record of what it last saw.
If executable-check removal succeeds but trust or sidecar cleanup fails, the wake reports those files as orphaned artifacts instead of claiming the removed check remains armed.
An idle worker whose dispatched task Playbot is still holding has not stopped, it has not started, so it is reported as that once and the poll stays armed and then quiet until the persisted observation changes.
A queue that cannot be read counts the same way, because unreadable is not proof of delivery, and retirement is irreversible while an extra wake is not.
That record holds the observed status and `updated_at`, Playbot's task-specific delivery verdict, worker and message identities, and a task acceptance boundary initialized from a fresh post-send `last_user_activity_at` and advanced by exact-message acceptance evidence.
If that post-send refresh is unreadable, no earlier timestamp is trusted as the new task's boundary, so delivery remains unconfirmed and the poll stays armed.
A terminal observation must fall after that acceptance boundary, so an earlier turn reaching `ready` cannot retire the new task while a fast accepted turn that finishes before the first poll remains visible.
A queued, sending, or recall-pending verdict advances only when that worker session's persisted rollout records the exact client message id after the task acceptance boundary.
A ledger turn binding, same-worker `not-recallable` outcome, or failed recall without that exact timestamp leaves supervision armed and promotable by a later poll, while bare queue disappearance remains armed because Playbot's UI may have recalled the message.
A worker that genuinely never began leaves its row untouched, so the pair holds the poll silent and armed for it while still reporting the one that finished.
If that record is missing the poll reports the observation state as unreadable and remains armed, because it cannot prove that the executing snapshot still owns the live check generation or that the task was delivered.
Firstmate's task teardown removes the record with the rest of the task's state, so a task torn down while its worker was still working leaves nothing behind.

`taskId` is optional and the workspace id is used when it is absent, so `dispatch` still attempts to arm the poll; a workspace-keyed poll is not retired by firstmate's task teardown and the result says so.
A `taskId` that is not a string is treated as absent and takes that same fallback, because coercing one would key the poll on a name no teardown matches.
`state/<taskId>.check.sh` is a name firstmate's merged-PR poll owns too, so neither owner may overwrite the other and both refuse by name instead.
Arming only ever replaces a check this server generated, so a merged-PR poll or any other check already armed for that task id is left untouched and the arming is refused instead.
In the other direction `bin/fm-pr-check.sh` refuses to arm over a lane supervision poll, naming both owners and the task id and exiting with the status it reserves for that one refusal, rather than silently destroying the only supervision a dispatched worker has.
That collision remains until proven delivery lets the lane poll retire on a terminal state or a matching task teardown removes it; failed, recalled, or unconfirmed delivery deliberately remains armed.
That refusal costs merge detection and nothing else, because `bin/fm-pr-merge.sh` continues past that reserved status alone and every other `bin/fm-pr-check.sh` failure still aborts the merge exactly as before.
Keying on the status rather than on the recorded `pr=` is what keeps that true on a re-run, where an earlier successful run has already left `pr=` in the task metadata and it proves nothing about this one.
A supervision poll never blocks a merge, because losing detection is a degradation firstmate recovers from by hand while a blocked merge stops real work.
A failed arming never turns a delivered task into an error: the result carries the delivery verdict beside `armed: false`, the reason, and a warning that nothing is polling the worker.
A Playbot-chat caller is reported as `mode: "routed-wake"` and arms nothing, because its lane already delivers.
`create_chat` arms nothing either: it starts no agent turn, so there is no worker to supervise until a `dispatch` sends one a task.

Playbot accepts a message it cannot deliver yet and holds it in a queue the sender is never told about, so `send_message` and `dispatch` report a `delivery` verdict taken from the thread snapshot Playbot returns.
`delivered` means the agent's turn accepted the message, `sending` means it is in flight, `queued` means Playbot is holding it and the worker has not seen it, `steering` means Playbot marked that exact message for the active turn, `failed` carries Playbot's own reason, and `unknown` means Playbot returned no usable confirmation.
For the initial send verdict, `unknown` covers only a Playbot that returns no snapshot at all; an initial snapshot returned without the queued or outbound projection is refused by name, like every other changed shape, rather than passing as an old Playbot.
Only `delivered`, `sending`, and `steering` mean the message is on its way.
A `queued` verdict is cured by answering the chat's card, dropping the held message, or deliberately promoting that exact message with `force=true`, never by an ordinary resend, because a resend adds to the pile and a later drain replays superseded instructions in order.
Every chat view also carries `queuedCount` from the persisted queue, so a pile is visible without asking for it.
`queuedCount` is `null`, never `0`, when that persisted ledger is present but not in a shape these tools can read, so an unreadable queue can never be mistaken for an empty one.

`send_message` accepts `force=true` as an explicit opt-in for a message that Playbot's first send response reports as queued.
The MCP then addresses that exact thread and exact returned message id through Playbot 0.95.x's `threads:steerMessage`, which calls Codex `turn/steer` for the current turn rather than stopping it.
The active turn continues, and the result reports `delivery.state: steering` plus `force.state: applied` only when Playbot's own response snapshot marks that exact message `steering: true`.
If the post-steer snapshot retains that exact message id without marking it as steering, the MCP reports the message as queued, sending, or failed from Playbot's evidence without claiming force was applied.
If a readable post-steer snapshot omits that exact message id or substitutes a different id, the MCP reports `delivery.state: unknown` and `force.state: not-applied` rather than treating absence as delivery evidence.
If the steering response is missing or unreadable, both immediate steering and delivery remain `unknown`, because the original send already reached Playbot but its post-action state cannot be proved safely.
`dispatch` exposes the same flag because its existing-thread path is the same steering surface; a newly created or idle chat normally reports force as not needed.
Force never selects or focuses a chat or workspace, never calls `threads:stop`, and never creates or archives anything beyond the normal `dispatch` request itself.

The global Stop hook is inert for every chat that has no active route.
For a routed worker, it reads the completed Codex turn id and final message from the persisted rollout, ignores an already delivered turn, and sends one marked follow-up to the controller chat.
Playbot queues that follow-up when the controller is busy, so the controller receives another turn without a fixed polling interval.
The wake reads the same delivery verdict as every other send, and a `failed` verdict does not record the turn as notified, so a wake Playbot rejected stays eligible for the next hook run and is written to `last-hook-error.json` instead of disappearing silently.
A `queued` verdict is recorded as notified, because Playbot does deliver it once the controller's turn frees up.
A send Playbot accepted whose verdict could not be read is recorded as notified on that same rule - Playbot has the message - with the unreadable verdict kept on the route and in `last-hook-error.json`.
Only a send that never reached Playbot stays eligible for retry, because resending a wake Playbot already holds would grow the very queue this surface exists to expose.
An `unknown` verdict is classified by the chat-creation API this Playbot exposes: a pre-0.94 Playbot returns nothing from `threads:send`, so `unknown` carries no information there and the wake is recorded, while a Playbot whose send path can report a verdict returning no snapshot is a real anomaly, so that wake is recorded in `last-hook-error.json` and stays eligible for retry rather than being lost silently.

`close_lane` disables notification without archiving either chat.
`archive_chat` is a separate explicit action and requires `confirm=true`.

## Question cards and held messages

A Playbot worker that asks a question parks until someone chooses an option, and an ordinary text send does not reach it while it waits.
Forced steering can attach an instruction to that active turn, but it does not answer or dismiss the card, so the worker remains parked until the card is resolved through the dedicated answer surface.
`list_parked_threads` is the optionally project-scoped detector: it reads persisted status, resumes nothing, and contacts Playbot not at all, while explicit project targets can add workspace freshness from Git.
Its results are candidates rather than findings, because Playbot reports a merely rehydrated chat as `pending_input` whether or not it is actually parked.
It shares one scope with the thread resolution described above and takes no parameter that widens it, because the confirming read has none to match, so every candidate it offers is resolvable by the `get_thread_card` pointer it hands back; an archived chat, and any chat in an archived workspace, is offered by neither.

`get_thread_card` is the confirming live read for one named chat, returning each pending question's exact text and option labels alongside the chat's held messages.
Reading a live snapshot resumes a chat that has not been resumed since Playbot started, exactly as opening that chat in the Playbot window does, and starts no agent turn.
Keeping the detector persisted and the confirmation live is what keeps that resume off a fleet-wide poll.

`answer_thread_card` answers one question card, which is the same call Playbot makes when a human clicks an option.
Playbot resolves a request id against a single process-wide registry, so a valid id paired with the wrong chat would answer a different worker's card; the tool therefore re-reads the named chat's live cards and sends only an id that read found on that chat.
An answer is the option label passed through byte for byte as it was read, untrimmed and unrewritten, because Playbot's own renderer uses each option's label as its answer value and an altered label no longer matches the option.
Skipping a card is an explicit `skip` rather than an empty answer set, so an empty object cannot skip by accident.
Answering only some questions on a multi-question card is allowed, because Playbot's own renderer allows it, and the result reports `partial` with the question ids that received no answer so a partial response can never read as a complete one.
A response Playbot already had in flight for that request is reported rather than refused: the underlying call refuses a second response to an already-resolved request on its own, and refusing here would also block a legitimate retry after a response that stalled.
Approval and MCP cards are reported for context but are not answerable through this tool.

`list_queued_messages` and `drop_queued_message` make the held queue visible and withdraw a superseded instruction instead of resending it.
A message that has already been delivered reports `not-recallable`, which is an outcome rather than an error.

## State and compatibility

Private route and hook state defaults to `~/.playbot/mcp/project-chat`.
The integration reads Playbot's application and Codex SQLite databases but never writes them directly.
Chat creation, message delivery, archive, and guarded workspace retirement operations go through Playbot's Electron IPC handlers over the local DevTools socket.

The current adapter targets Playbot 0.94.0 and Node.js 22.5 or newer, with a detected fallback to the pre-0.94 channels that were verified against Playbot 0.93.1 on Linux.
The card, snapshot, queue, and forced-steering channels are verified against Playbot 0.95.x, and every version-sensitive result names the verified range or the exact internal mechanism, so a mismatch is visible rather than inferred.
A channel Playbot no longer registers, or a snapshot missing a field these tools read, is refused with the missing channel or field and the observed version named; nothing falls back to driving the visible window.
`doctor` reports the same observed version as `playbotApp`.
Playbot's private IPC is not a published compatibility surface, so a Playbot update requires rerunning `doctor` and the focused test before relying on cross-project delivery.
Current empirical evidence is recorded in [verification/supervision.md](verification/supervision.md#playbot-lanes).
