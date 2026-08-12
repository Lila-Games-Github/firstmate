---
name: ahoy-playbot
description: Ensure Firstmate's Playbot project-chat lane MCP is ready without restarting Playbot or creating or activating chats. Use when the captain says the exact phrase "Ahoy Playbot!", invokes $ahoy-playbot, or asks to initialize, reconnect, repair, or check Playbot lane control.
metadata:
  internal: true
---

# Ahoy Playbot

Ensure the existing Playbot lane control plane is ready without starting a worker session.

1. From the Firstmate code root, run `node --no-warnings bin/fm-playbot-lanes.mjs setup`.
2. Treat `ready: true` as the only successful outcome.
   The setup command checks the live integration first and makes no changes when it is already healthy.
   When it is not ready, the command idempotently installs the MCP definition and global hooks, asks the running Playbot process to reload its MCP servers, and checks readiness again.
3. Never restart Playbot as part of this workflow.
4. Do not create, select, message, dispatch to, close, or archive any Playbot chat during setup.
   Do not call a `playbot_lanes` chat tool merely to prove the MCP is ready.
5. If setup is ready, tell the captain whether setup was already healthy or repaired and confirm that no chat was started.
6. If setup is not ready, report the failed checks and precise local blocker.
   Do not compensate by creating a startup chat, focusing another chat, or starting an agent session.
