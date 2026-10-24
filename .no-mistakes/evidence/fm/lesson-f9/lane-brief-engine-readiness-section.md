## Generated no-mistakes lane brief: engine-readiness pointer (bin/fm-brief.sh --lane)
$ FM_HOME=<tmp> bin/fm-brief.sh lesson-f9-demo some-proj --mode no-mistakes --lane --landing-branch main
173:For engine readiness and bounded engine-call handling, follow `docs/playbot-lanes.md`'s Engine readiness contract in the Firstmate code root.

## Section the lane brief points to: docs/playbot-lanes.md ### Engine readiness (lines 270-309 at 876b470)
### Engine readiness

Before engine-dependent dispatch, `get_engine_readiness` reads one exact project's workspace without activating a project, resuming a chat, or starting an engine session.
It reports app and bundled addon versions, Playbot's detected Godot projects, workspace addon versions and every required file's byte identity against that bundle (including native files), stored and canonical project paths, and the executable selected by an existing headless session.
On Linux, a connected headless session can confirm its selected native binary from Playbot's reported PID when the bounded launch log has expired; the live process must be named Godot, have `--headless`, and have a `--path` resolving to that exact project.
`PLAYBOT_LANES_APP_RESOURCES` can identify the packaged app's resources directory when running-process discovery is unavailable; the script header owns its discovery and version-binding mechanics.
An editor preference or PATH candidate is insufficient selection evidence because Playbot checks executable compatibility before choosing it.
Unreadable evidence remains `unconfirmed`; the tool never runs the candidate executable to fill that gap.
The engine snapshot reader is verified for Playbot 0.117.0, 0.124.0, and 0.129.0; other app versions return `unconfirmed` without calling unverified engine IPC.
For Playbot 0.124.0 on a symlinked home, use `get_worktree_root` to inspect the effective storage path and `canonicalize_worktree_root` to select its canonical spelling through Playbot's own settings IPC before creating a workspace.
That setting changes the path Playbot records for future workspaces, while existing workspaces retain their recorded paths.
After creating a Godot workspace, `prepare_engine_workspace` uses Playbot's engine IPC to install missing bundled native addon files in that exact idle workspace and verifies complete byte identity before engine validation.
The tool refuses a stored project path alias and addon drift beyond missing native files.
Playbot 0.124.0's system instruction prohibits an agent from running Godot through its shell even in a `full-access` chat; a direct `!` shell command sent by the user/controller runs through Playbot's `thread/shellCommand` route and can run the project's native automation.
The agent can use `execute_engine_code` for engine state; a GDScript runner must return its result because `print()` alone leaves the tool's returned text empty.
The diagnostic distinguishes `addon-drift`, `missing-addon-files`, `startup-pending`, `identity-admission-risk`, an observed `identity-admission-rejected`, generic `engine-failure`, and `unconfirmed`, retaining all reasons when several apply.
A Flatpak or other observed namespace launcher and differing stored/canonical paths are admission risks, while `connectionBlocked` alone does not prove a PID rejection.
Readiness requires an existing routed connected session reporting the current loaded addon, complete matching disk bytes, and a readable native launch executable with no reported failure or identity risk.

`dispatch` requires confirmed readiness by default and re-reads the destination immediately before sending.
Set `engineDependent: false` only for work whose completion needs no engine execution, capture, or validation; omission and `true` both enforce the guard, and non-booleans are rejected.
Existing workspaces are checked before chat creation and re-read before sending.
Engine-dependent `newWorkspace` dispatch is refused before anything is created, because a freshly created workspace has no connected engine session; file-only `newWorkspace` dispatch retains the root-settle/freshness guard.
Do not bypass a readiness refusal through `send_message`; use that tool for engine work only after a fresh readiness verdict is confirmed.
Choose `newWorkspace` for isolation, and verify capability separately: it provides no shell-permission or engine-policy workaround.
When readiness fails or remains unconfirmed, dispatch engine-dependent validation to an ordinary worker whose instructions permit the project's pinned native validation route, recording the exact commit and workspace validated and the engine assertions still unverified.
File-only work can proceed under its explicit declaration.
This diagnostic does not authorize changing Playbot settings, executable selection, or PID records.

When an engine call yields `Script running`, poll that existing call within the chosen execution budget and preserve its final underlying result.
The yield means the call is pending; it is not an engine error or proof of an engine timeout.
If the budget ends and the call is terminated, report cancellation and the elapsed budget, preserving any observed diagnostic without inventing a final failure.
Avoid repeated engine calls while readiness is already known to fail, and keep bridge repair and capture-pipeline repair in separate work records.

A confirmed readiness verdict certifies engine execution, not a full-suite verdict.
A project's full suite is a shell-launched runner that reports its own result, so the suite is certified by a shell-capable worker running that project's pinned suite runner and recording the exact commit with the runner's own verdict.
The engine bridge is not a full-suite entry point: an expected negative-path `push_error` diagnostic a test deliberately triggers can pause a bridge-driven run, and that pause is the bridge stopping at a diagnostic rather than the runner reporting a failure, so a Playbot-executed run must never be reported as the suite's verdict.
An engine run still supplies engine-state and authoring evidence on the separate terms above, so keep the two apart instead of asking one to certify the other.
When a lane's validation is defined by its suite runner's verdict, route that suite to the shell-capable worker that can run it and record the engine assertions left unverified, exactly as an unconfirmed readiness verdict is routed; the routing reason names the suite runner, not a readiness failure.

