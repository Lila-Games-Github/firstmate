# Playbot lanes

Playbot lanes let one Playbot chat supervise chats in other Playbot projects without selecting those chats in the UI.
The integration is intentionally close to Firstmate's Herdr supervision shape: one controller, durable worker routes, background delivery, and a completion notification only when a routed worker has new actionable output.

`bin/fm-playbot-lanes.mjs` is the single owner of the tool schemas, private state format, install command, hook behavior, and exact failure rules.
Run its `doctor` command for bounded local diagnostics and its `install` command to register the server and hooks in Playbot's managed Codex home.
Run its `setup` command to ensure the complete integration is ready in one fail-closed operation.

## Captain startup trigger

The exact captain phrase `Ahoy Playbot!` loads the internal `ahoy-playbot` skill and runs the `setup` command.
Setup checks readiness first and makes no changes when the integration is already healthy.
When readiness fails, it installs the MCP definition and hooks, asks the running Playbot process to reload its MCP servers, and checks again without restarting Playbot.
This initialization never creates, selects, messages, closes, or archives a chat, and it never starts an agent session.
It reports ready only when Playbot DevTools is reachable, the configured controller project exists, exactly one owned PreToolUse hook and Stop hook are installed, and Playbot reports the enabled MCP with no error and the expected tool count.

## Identity and project routing

The MCP lists projects globally rather than inheriting Playbot's current-project filter.
Project ids and root paths are stable selectors.
A project name is accepted only when it identifies exactly one project, so two projects named `prototype-game` are never silently conflated.

The global PreToolUse hook records the Codex `session_id` immediately before a `playbot_lanes` tool call.
The MCP maps that session id through Playbot's persisted `workspace_threads.session_id` field to identify the calling controller chat.
It never treats the visibly selected or most recently active chat as sufficient identity evidence.
If concurrent calls make the marker ambiguous, the tool refuses and asks for a retry instead of choosing a chat.
Every cross-project MCP operation also verifies that the caller belongs to the configured controller project, so worker chats cannot use the globally installed server as an unrestricted control plane.

## Lane lifecycle

`dispatch` performs the normal end-to-end path.
It identifies the controller, resolves an existing worker chat or creates an empty one, records a durable worker-to-controller route, and sends the task through Playbot's own `threads:send` IPC.
The message can enter a non-selected project and does not require changing UI focus.

The global Stop hook is inert for every chat that has no active route.
For a routed worker, it reads the completed Codex turn id and final message from the persisted rollout, ignores an already delivered turn, and sends one marked follow-up to the controller chat.
Playbot queues that follow-up when the controller is busy, so the controller receives another turn without a fixed polling interval.

`close_lane` disables notification without archiving either chat.
`archive_chat` is a separate explicit action and requires `confirm=true`.

## State and compatibility

Private route and hook state defaults to `~/.playbot/mcp/project-chat`.
The integration reads Playbot's application and Codex SQLite databases but never writes them directly.
Chat creation, message delivery, and archive operations go through Playbot's Electron IPC handlers over the local DevTools socket.

The current adapter targets Playbot 0.80.0 and Node.js 22.5 or newer.
Playbot's private IPC is not a published compatibility surface, so a Playbot update requires rerunning `doctor` and the focused test before relying on cross-project delivery.
Current empirical evidence is recorded in [verification/supervision.md](verification/supervision.md#playbot-lanes).
