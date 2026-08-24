---
name: ahoy-playbot
description: Ensure Firstmate's Playbot lane MCP is ready from a normal terminal or Playbot chat without restarting Playbot or creating or activating chats. Use when the captain says the exact phrase "Ahoy Playbot!", invokes $ahoy-playbot, or asks to initialize, reconnect, repair, or check Playbot lane control.
metadata:
  internal: true
---

# Ahoy Playbot

Ensure the existing Playbot lane control plane is ready without starting a worker session.

1. From the Firstmate code root, run `node --no-warnings bin/fm-playbot-lanes.mjs setup`.
2. Treat `ready: true` as the only successful outcome.
   The setup command checks the live integration first and makes no changes when it is already healthy.
   When it is not ready, the command idempotently installs the MCP definition and global hooks, asks the running Playbot process to reload its MCP servers, and checks readiness again.
   A Playbot project rooted at the Firstmate repo is not required and `checks.controllerPresent` is informational only.
   Do not ask the captain to open or add the Firstmate repo in Playbot.
3. Never restart Playbot as part of this workflow.
4. Do not create, select, message, dispatch to, close, or archive any Playbot chat during setup.
   Do not call a `playbot_lanes` chat tool merely to prove the MCP is ready.
5. If setup is ready, tell the captain whether setup was already healthy or repaired and confirm that no chat was started.
   From a normal terminal, lane tools may list projects, create workspaces, dispatch, send, read, and manage chats directly.
   A terminal dispatch has no Playbot controller chat to wake, so supervise it with `get_thread_status`, `read_thread`, and `get_thread_card`; routed Stop-hook wakes remain available when the caller is a configured Playbot controller chat.
   Never treat a `send_message` or `dispatch` result as delivered without reading its `delivery.state`, and never resend on a `queued` or `unknown` verdict; [docs/playbot-lanes.md](../../../docs/playbot-lanes.md) owns what each verdict means and how a held message is cleared.
6. If setup is not ready, report the failed checks and precise local blocker.
   Do not compensate by creating a startup chat, focusing another chat, or starting an agent session.
