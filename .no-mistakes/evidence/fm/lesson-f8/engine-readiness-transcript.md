### 0.117.0 (verified list) get_engine_readiness: verdict + ipc + project bridge/graphicalCapture
{
  "verdict": "ready",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "reachable",
      "detail": "Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "version-verified",
      "observedVersion": "0.117.0",
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "Playbot 0.117.0 is a verified version and engine:listWorkspaceProjects returned the contract this tool reads."
    }
  },
  "bridge": {
    "status": "connected",
    "projectPath": "<fixture>/game",
    "sessionId": "session",
    "sessionType": "headless",
    "lifecycleStatus": "connected",
    "startupActivity": null,
    "detail": "The routed engine session reports a completed handshake for this exact project path."
  },
  "graphicalCapture": {
    "status": "unavailable",
    "reason": "headless-display-driver",
    "detail": "The routed engine session is a headless engine, whose display driver cannot supply rendered editor screenshots."
  }
}

### non-headless session graphicalCapture
{
  "status": "unproven",
  "reason": "capture-not-attempted",
  "detail": "The routed engine session is not headless (type \"editor\"), but this read-only diagnostic attempts no capture and so cannot prove one succeeds."
}

### dispatch {"requiresGraphicalCapture":true} -> exit 1 stderr
Graphical capture is unavailable in workspace ws: <fixture>/game (headless-display-driver). A headless engine's display driver cannot supply rendered editor screenshots, so a task that requires them cannot be completed here. Dispatch it to an ordinary worker that can render and capture the editor, or drop requiresGraphicalCapture if the task's completion needs no rendered editor evidence. {"bridge":{"channel":"app:metadata","status":"reachable","detail":"Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."},"contract":{"channel":"engine:listWorkspaceProjects","status":"version-verified","observedVersion":"0.117.0","veri

### dispatch {"engineDependent":true,"requiresGraphicalCapture":true} -> exit 1 stderr
Graphical capture is unavailable in workspace ws: <fixture>/game (headless-display-driver). A headless engine's display driver cannot supply rendered editor screenshots, so a task that requires them cannot be completed here. Dispatch it to an ordinary worker that can render and capture the editor, or drop requiresGraphicalCapture if the task's completion needs no rendered editor evidence. {"bridge":{"channel":"app:metadata","status":"reachable","detail":"Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."},"contract":{"channel":"engine:listWorkspaceProjects","status":"version-verified","observedVersion":"0.117.0","veri

### stalled engine call
{
  "verdict": "unconfirmed",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "reachable",
      "detail": "Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "call-failed",
      "observedVersion": "0.117.0",
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "engine:listWorkspaceProjects did not answer for <fixture>/game (Playbot Runtime.evaluate read timed out), so its contract could not be classified."
    }
  }
}

### unlisted 0.118.0 (no allowlist)
{
  "verdict": "ready",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "reachable",
      "detail": "Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "capability-verified",
      "observedVersion": "0.118.0",
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "Playbot 0.118.0 is not on the verified list (0.117.0, 0.124.0, and 0.129.0), but engine:listWorkspaceProjects returned the contract this tool reads, so the engine snapshot IPC is compatible on capability evidence alone. Re-verify this version and add it to the verified list once a focused read confirms the whole engine surface."
    }
  }
}

### channel no longer registered
{
  "verdict": "unconfirmed",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "reachable",
      "detail": "Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "channel-missing",
      "observedVersion": "0.117.0",
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "Playbot does not register engine:listWorkspaceProjects, so the engine snapshot contract this tool reads is gone."
    }
  }
}

### channel returned changed shape
{
  "verdict": "unconfirmed",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "reachable",
      "detail": "Playbot answered app:metadata over its own DevTools bridge, so live Playbot state can be read."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "shape-changed",
      "observedVersion": "0.117.0",
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "engine:listWorkspaceProjects answered for <fixture>/game with a shape this tool cannot read, so the engine snapshot contract changed."
    }
  }
}

### Playbot bridge unreachable
{
  "verdict": "unconfirmed",
  "ipc": {
    "bridge": {
      "channel": "app:metadata",
      "status": "unreachable",
      "detail": "Playbot's own DevTools bridge could not be reached (No Playbot project renderer exposes electronAPI.invoke), so the engine IPC contract was never classified."
    },
    "contract": {
      "channel": "engine:listWorkspaceProjects",
      "status": "unprobed",
      "observedVersion": null,
      "verifiedVersions": "0.117.0, 0.124.0, and 0.129.0",
      "detail": "No engine IPC call completed, so the contract this Playbot exposes was not classified."
    }
  }
}

