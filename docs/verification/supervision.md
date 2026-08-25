# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
| Claude | 2.1.222 (Claude Code) | `source=startup`, token quoted back in both `-p` and the TUI | `/clear` reports `source=clear` and `/compact` reports `source=compact`; both re-injected a fresh token that the model quoted back | `claude --continue` reports `source=resume` |
| Codex | codex-cli 0.146.0 | `source=startup` under `codex exec`, token quoted back | Not reachable from a tracked project registration; see the limit below | `codex exec resume --last` reports `source=resume` |
| Pi | 0.82.0 | `source=startup`, token quoted back in both `-p` and the TUI | `/new` raises `session_start` reason `new`, which the extension maps to `clear`; `/compact` raises `session_compact`, and both freshly injected source-stamped tokens were quoted back | `pi -c` reports reason `startup`, not `resume` |

Two harness-specific consequences are load-bearing rather than incidental.

Codex's interactive TUI fired no project `SessionStart` hook at all in the same lab where `codex exec` fired it reliably, which matches the earlier 2026-07-28 finding for 0.145.0.
Codex's run tier is therefore verified only for `codex exec` startup and context-preserving resume.
The interactive TUI is a known uncovered gap: Firstmate has no tracked session-open, compaction, or re-emit channel there, ships no global hook, and does not claim instruction-refresh delivery for that surface.

Pi compaction was verified on 2026-08-05 with Pi 0.82.0 in the same throwaway lab after setting `.pi/settings.json` `compaction.keepRecentTokens` to 200 and completing one substantial assistant-prose turn before issuing `/compact`.
Pi reported `Compacted from 7,697 tokens`, the recorder observed `session_compact`, and the model quoted the freshly injected `source=compact` token back.
Both preconditions are load-bearing: the stock 20,000-token keep window exceeds a small lab session, and `AgentSession.compact()` aborts an in-flight turn before measuring compactable history, which otherwise discards that turn and reports `Nothing to compact (session too small)`.
Tool output alone does not grow compactable context; the completed assistant prose does.

Observed compaction output and recorder source:

```text
Compacted from 7,697 tokens
compact
```

Pi disagrees with Claude and Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

Session start composes its digest from local reads and runs every external-network call in a worker detached by the hook (`bin/fm-startup-network.sh`), so a harness that reaped the hook's process tree would silently stop running the sweeps rather than merely delaying them.
Verified on 2026-08-06 with Claude Code 2.1.222 in a throwaway lab whose `bin/fm-bootstrap.sh` sleeps 6s before writing a marker, so the marker can exist only if the worker outlived the hook and the whole `claude -p` process.

```text
$ claude -p --permission-mode bypassPermissions '<quote the session-start token>'
FMHOOKTOKEN-startup-1-abc123
--- claude exited at 13:38:40; polling for the detached worker's marker ---
MARKER at +4s: detached worker survived the hook
state=done
started=1786048716
finished=1786048723
```

The worker started before the harness exited and published 6s after it was gone.

The latency this buys was re-measured on 2026-08-06 against default-branch tip `8398d31`, in a throwaway home holding one remote secondmate whose host hangs 25s per SSH connection (an `FM_SSH_BIN`-shaped stub; no real host was contacted).
Both runs used the same fixture and the same `bin/fm-session-start.sh` invocation, differing only in which checkout supplied the script:

```text
before (8398d31)   real 1m21.15s   3 blocking SSH attempts inside the digest
after              real 0m3.36s    digest prints IN PROGRESS; the same 3 SSH attempts
                                   run in the detached worker and finish at +77s
```

The remaining seconds are entirely local subprocess work; the `NETWORK CHECKS` section named GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh as not yet confirmed.

Deferring the sweeps changed only when they run, not what they conclude.
The deferred worker's published report was byte-identical to the three sweep lines the blocking baseline printed, on the same fixture:

```text
SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown; route preserved on remote-mac
SECONDMATE_SYNC: secondmate ios: skipped: remote tracked-file sync failed on remote-mac:
SECONDMATE_SYNC: secondmate ios: skipped: remote inheritance failed on remote-mac:
```

The unreachable route was preserved rather than relaunched in both runs, and the result surfaced durably as a queued `check: startup-network` wake once the worker finished.

Codex and Pi were not installed as run-tier labs in this measurement, so their evidence for this fact is NOT refreshed; `tests/fm-sessionstart-hook-live-e2e.test.sh` asserts it for each installed Claude, Codex exec, and Pi adapter and is the command that refreshes their record.
Cursor's separate primary live guard covers its source-free session-open transport but does not claim this detached-worker measurement.
A harness that did reap the worker degrades loudly rather than silently: the leftover record reads as an abandoned run needing a rerun, and the next session start re-derives every finding, because these sweeps are idempotent detectors.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Claude, Codex exec, and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when none of those three adapters was installed.
Cursor's refresh command is `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh`, recorded under [Cursor primary park](#cursor-primary-park-2026-08-13).

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across six harnesses on 2026-07-08 through 2026-08-13, with Claude's replacement Stop-owned path revalidated on 2026-07-24 and Cursor's stop-hook park validated on 2026-08-13.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |
| Cursor | 2026.08.11-e8db854 | Awaited `stop` hook park returning one `followup_message` | Exit 2 ended the turn normally, proving it cannot block; a returned follow-up ran a genuine second turn; a sleeping hook held the boundary open and the wake landed after it; `loop_limit` stopped the hook being invoked at its ceiling. |

### Cursor primary park, 2026-08-13

Cursor was validated as a primary on 2026-08-13 against the installed CLI on macOS 26.5.2 arm64 with tmux 3.6a, in a throwaway firstmate home on a private tmux socket, never against a live home and never with a user-scope hook.

Mechanism facts established first, in a separate throwaway workspace:

| Question | Method | Result |
| --- | --- | --- |
| Can `stop` block? | hook exits 2 | No. The turn ended normally; Cursor's blocked-response mapper returns `{}` for the `stop` step. |
| Can `stop` force one turn? | hook returns `{"followup_message":...}` | Yes. A genuine second turn ran and answered. |
| Can `stop` park? | hook sleeps, then returns a follow-up | Yes. It is awaited; a 20s sleep held the boundary and the follow-up landed after it. |
| What is `loop_count`? | four consecutive follow-ups, then a real user message | `0,1,2,3`, then `0` again. It counts follow-up-driven stops since the last real user message. |
| Does `loop_limit` bind? | `loop_limit: 2` with an always-follow-up hook | Yes. The hook was invoked at `loop_count` 0 and 1 and never at 2. |
| Does a captain message terminate an existing park? | captain message typed during a 600s park | No. Cursor leaves the park running, and without a baton an older park can still deliver after the captain turn's next `stop` has started another park. |
| Does Cursor load `.claude/settings.json`? | Claude-shaped `SessionStart`, `PreToolUse`, `Stop` in the same workspace | `SessionStart` and `PreToolUse` fired with a CURSOR-shaped payload carrying `cursor_version`; `Stop` did not fire. |

The integration itself is exercised by the opt-in guard:

```sh
FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh
```

Observed output:

```text
harness: cursor-agent 2026.08.11-e8db854
ok - cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself
ok - cursor primary: the run-tier session start completes every stage
ok - cursor primary: sessionStart additional_context reaches model context before the first turn
ok - cursor primary: the stop-hook park delivers a real watcher wake as one follow-up
ok - cursor primary: the park owns exactly one arm cycle with a live watcher beacon
ok - cursor primary: the captain keeps control and the older park stands down after the next stop claim
ok - cursor primary: an away-mode escalation is delivered, confirmed, and processed
```

The live run proved that session start acquires the fleet lock through Cursor's structural process identity in `bin/fm-cursor-lib.sh`; `tests/fm-session-lock-ancestry.test.sh` pins the same ancestry path portably.
It also proved that Cursor's `autoarm` supervision model lets the mid-turn pull guard accept a fresh beacon after the between-turn watcher closes; `tests/fm-guard-stale-banner.test.sh` pins that model-aware verdict.
The baton is claimed only by the next `stop`, so an actionable close before that claim can still produce one real follow-up from the sole existing park; durable wake handling is idempotent, and any older park still running after the claim stands down.
Cursor's `beforeSubmitPrompt` step could close that exact window because it fires once on a real captain message and not on hook-driven follow-ups, but registering it is deliberately deferred alongside `preCompact`.

Away-mode delivery needed no daemon change once the composer reader was correct for Cursor; [`runtime-backends.md`](runtime-backends.md#composer) owns that evidence.

Cursor compaction instruction refresh is DEFERRED and not shipped, so a Cursor primary does not re-emit its digest after a compaction.
Two static facts decided that: `PreCompactRequestResponse` carries only `user_message`, and `preCompact` is absent from the `additional_context` step set (`index.js` @ 4814884), so the step cannot inject a digest and any delivery has to be routed through a later boundary.
A staged-then-delivered design is rejected because carrying a digest across two concurrently running `stop` hooks can deliver it twice or strand it indefinitely, while closing those races enlarges a critical section inside a hook Cursor awaits at the turn boundary.
Native `preCompact` firing was not observed because a real compaction could not be forced in the isolated session, so the surface has no empirical basis yet.
It is therefore recorded as uncovered in the same sense as the Codex interactive TUI, and `tests/fm-cursor-primary.test.sh` asserts `preCompact` stays unregistered so it cannot return unnoticed without its own design and evidence.

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.
That inertness result is scoped to the builds it exercised: it did not establish that `GROK_AGENT` reaches a Grok HOOK process, and on grok 1.0.0 it does not, so the marker set was widened to `GROK_HOOK_EVENT` as well (docs/turnend-guard.md "Harness integrations").
`tests/fm-turnend-guard.test.sh` now pins every tracked `.claude/settings.json` hook entry against a real grok 1.0.0 hook environment so the inertness contract is covered deterministically rather than only by the opt-in live matrix.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs real watcher and arm cycles against durable on-disk state to verify that a delivered reason survives until post-handling acknowledgement and stops replaying after acknowledgement, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.
The same suite ingests a keyed remote-secondmate parent reply through the real adapter, establishes the incremental OPEN DECISIONS cursor, interrupts supervision, and proves re-arm replays every unacknowledged queue row plus the still-open decision through the ordinary drain path.
It also covers decision-only recovery, interrupted handling, handling-window generation reuse, non-fatal moved-generation acknowledgement with sequence-bounded consumption, and a persistent successor remaining live after recovery is acknowledged.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The model-aware pull-guard predicate correction (`bin/fm-guard.sh` no longer reports a false watcher-down mid-turn under the Claude Stop auto-arm model, where the watcher runs only between turns) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The Pi extension-model pull-guard correction (`bin/fm-guard.sh` no longer reports a false watcher-down on a Pi primary during the extension's own watcher hand-off) was verified on 2026-08-13 with the installed ShellCheck 0.11.0 and isolated behavior suites.
The guard verdict itself reads only state files and process liveness, so the portable suites are the enforcing evidence; `bin/fm-harness.sh`'s Pi marker detection, which selects the model, is exercised in the same suite through `PI_CODING_AGENT`.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-session-start.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-watch-arm.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=243
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=280160
```

The same correction was verified against a live Pi primary's own supervision evidence on 2026-08-13.
The hand-off was captured live at beacon age 63s, then the home's `state/.lock`, `state/.last-watcher-beat`, both `state/.pi-*-extension-loaded` markers, and both `.pi/extensions/*.ts` builds were copied into an isolated fixture with no watcher lock.
The fixture's copied beacon was fresh at 0s in the output below; the deterministic stale-beacon case separately verifies the grace boundary.

```sh
FM_SUPERVISION_MODEL=persistent FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_SUPERVISION_MODEL=extension FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
```

Observed output, before and after the model correction, then with the recorded Pi session pid replaced by a dead one:

```text
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
(silent)
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-wake-queue.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
## Playbot lanes

On 2026-07-29, Playbot 0.80.0 on Windows was verified to expose `threads:openThread`, `threads:send`, `threads:archiveThread`, and `codex:mcpServers:reload` through its Electron IPC bridge.
The installed application persisted the Playbot chat id and Codex session id together in `workspace_threads`, while the Codex rollout recorded a stable completed turn id and final agent message before the Stop hook returned.

The focused verification command was:

```text
"C:\Program Files\Git\bin\bash.exe" tests/fm-playbot-lanes.test.sh
```

The exact result was:

```text
ok - fm-playbot-lanes: node syntax is valid
ok - fm-playbot-lanes: global project discovery is project-id and path aware
ok - fm-playbot-lanes: duplicate project names fail closed
ok - fm-playbot-lanes: caller identity comes from the exact Codex session marker
ok - fm-playbot-lanes: cross-project tools are restricted to the configured controller project
ok - fm-playbot-lanes: thread reads are bounded and non-resuming
ok - fm-playbot-lanes: Stop wake delivery is routed, durable, and turn-deduplicated
ok - fm-playbot-lanes: installer merges one MCP server and one hook of each kind
ok - fm-playbot-lanes: hook readiness requires one owned hook of each kind
ok - fm-playbot-lanes: setup repairs only when needed and never creates a startup chat
```

On 2026-07-30, the live `setup` command returned `ready: true` and `changed: false`, proving that an already healthy integration is left untouched.
The same result reported a reachable renderer, one owned hook of each kind, an enabled error-free MCP, and all 12 expected tools.

On 2026-08-18, Playbot 0.93.1 on Linux was verified to expose `workspace:create` and `workspace:delete` through the same Electron IPC bridge.
The `workspace:create` payload was confirmed from the running app's extracted `.vite/build/main.js` as a strict zod discriminated union on `strategy`, whose `project` strategy accepts `projectId` plus optional trimmed non-empty `branch`, `name`, `baseBranch`, and `rootOverrides`, awaits worktree provisioning, and returns the created workspace record.
A live `create_workspace` tool call with `baseBranch: "godot-base"` on a consented test project created workspace `ws_ae669f5ed8e7` whose worktree HEAD `00766f08e985` exactly equaled the `godot-base` tip, proving base-branch selection; `workspace:delete` then removed the workspace row, its `workspace_roots` row, and the worktree directory, and restored the project's prior selected workspace.
Playbot's delete preserved the created git branch, which was removed separately; expect that residue when cleaning up test workspaces.
Playbot's own create handler marks the new workspace selected within its project, so workspace creation on a project the captain is actively viewing changes what they see; the lane tools themselves never invoke `workspace:select`.

The focused regression command `tests/fm-playbot-lanes.test.sh` passed all 16 checks on the same date, including six added for workspace support:

```text
ok - fm-playbot-lanes: workspace root branches are visible in the global topology
ok - fm-playbot-lanes: create_workspace sends the verified workspace:create payload and returns the created roots
ok - fm-playbot-lanes: create_workspace omits blank optional fields so Playbot's strict schema accepts the payload
ok - fm-playbot-lanes: dispatch creates a workspace, creates the worker chat inside it, and delivers the task
ok - fm-playbot-lanes: ambiguous workspace targeting fails closed
ok - fm-playbot-lanes: existing-workspace selection is unchanged
```

Those checks run against a hermetic fake DevTools endpoint inside the test whose `window.electronAPI.invoke` stub records every IPC call, so payload construction is enforced without a live Playbot.

On 2026-08-24, Playbot 0.95.0 on Linux was verified to expose the question-card, snapshot, and pending-queue channels the card tools use, and to have kept the composer mounted while a card is displayed.
`app:metadata` returned `{name: "Playbot", version: "0.95.0"}`, matching the extracted `resources/app.asar` `/package.json` and the crashpad `--annotation=_version=0.95.0`.
The channel names and payload shapes were confirmed from the running app's extracted `.vite/build/main.js`, where `threads:respondToUserInput` takes `{threadId, requestId, response, composerContext?}` and resolves the pending Codex `item/tool/requestUserInput` request, `threads:getSnapshot` takes `{threadId}` and returns `userInputRequests`, `pendingMessages`, and `outboundMessages` among its fields, `threads:recallMessage` takes `{threadId, messageId}` and returns `{outcome, message?, snapshot}`, and `threads:send` returns that same thread snapshot.

`threads:respondToUserInput`'s RETURN shape is live-verified, not only read from the bundle, because several tools depend on it: `cardsRemaining`, `statusAfter`, `phaseAfter`, and the post-action unreadable-projection warning all assume it resolves with a thread snapshot rather than void.
Answering five live cards on 2026-08-24 against Playbot 0.95.0 - `chat-7975fcb9` request ids 10, 14, 15, 16, and 17, and `chat-3bbd9805` request ids 12 and 13 - resolved a full thread snapshot object each time, with `agentStatus` plus array-valued `userInputRequests`, `respondingRequestIds`, and `pendingMessages` observed on the resolved value.
Immediately after answering, `respondingRequestIds` contained the answered id and `agentStatus` had moved off `pending_input` by the following read.
Answering an already-resolved id returns `No pending user input request with id N` rather than double-resolving, so the call is idempotency-safe by construction.
The payload sent was `{threadId, requestId, response: {answers: {<questionId>: {answers: [<string>]}}}}`.
Both this channel's return shape and `threads:send`'s are observed behaviour of one version at one moment rather than a published contract, the same caveat that governs every internal-IPC surface this adapter reaches.
The only precondition on the answer path is that the chat's workspace is not archived; nothing on it inspects the selected workspace or the visible chat.

Live evidence against the running Playbot 0.95.0 on the same date, taken with a real worker parked on a real card:

- `get_thread_card` on a chat in a NON-selected workspace returned that chat's own card, with `requestId: 10`, question id `gate_ruling`, and option labels `Proceed (Recommended)` and `Keep current commit`.
- `answer_thread_card` with a request id that was not pending on the named chat was refused without any IPC write, and the card was still pending with `responding: false` afterwards.
- `answer_thread_card` with request id `10`, which was genuinely pending on a DIFFERENT chat, was refused when paired with the wrong chat rather than answering that other worker's card. This is the property that makes a process-wide request-id registry safe to use.
- The card was later answered by a human in the Playbot window, and the Codex rollout recorded the resulting tool output as `{"answers":{"gate_ruling":{"answers":["Proceed (Recommended)"]}}}`, byte-identical to the payload `answer_thread_card` constructs from an option label.
- `send_message` to a chat whose turn was running reported `state: "queued"` with `queuedTotal: 1` and a message id, `list_queued_messages` showed that exact held message, and `drop_queued_message` returned `outcome: "recalled"` and left the queue empty. The worker never saw the message, which is the held-and-invisible behavior the delivery verdict exists to report.
- Playbot's queued projection carries no `createdAtMs`, unlike the outbound one, so the delivery verdict matches the most recent message by list order rather than by timestamp.
- All six snapshot projections came back as real arrays on both Frogpile chats: `userInputRequests`, `pendingMessages`, `outboundMessages`, `approvalRequests`, `mcpElicitationRequests`, and `respondingRequestIds`, each `array(0)` on `chat-7975fcb9` and `chat-3bbd9805`. This is why the shape guard requires a list rather than mere presence and refuses a non-array by name. It is one version observed at one moment, not a contract.
- `threadRows()` selects `t.pending_queue_json` unconditionally, and that one query backs every tool and both hooks, so the column's presence across the supported range was settled by evidence rather than by a defensive probe. Parsing `resources/app.asar` and reading every `/migrations/*/migration.sql` shows `workspace_threads` is created already carrying `pending_queue_json` by migration `20260414225126_medical_lilandra`, dated 2026-04-14, and that this is the only migration among the 33 in the 0.95.0 bundle that creates that table. Playbot 0.93.1, the oldest version this adapter's detected fallback targets, shipped around 2026-08-18, four months later, and Playbot runs its migrations forward on app start. No Playbot in the supported 0.93.1-to-0.95.0 range can therefore present a `workspace_threads` without that column. This says nothing about versions outside that range.

The dispatch-armed poll's own checks were still being written after that live run, so the suite is dated separately: on 2026-08-25, `bash tests/fm-playbot-lanes.test.sh` with node v26.7.0 passed all 76 checks, including twenty-eight added for the thread-resolution scope, the card and queue surfaces, the delivery verdict, and the lane-wake delivery rules, and twenty for the dispatch-armed supervision poll recorded below:

```text
ok - fm-playbot-lanes: a named thread resolves project-wide, and an explicit workspace still narrows it
ok - fm-playbot-lanes: list_parked_threads detects candidates from persisted state without touching Playbot
ok - fm-playbot-lanes: the parked detector cannot be widened past its confirming read's scope
ok - fm-playbot-lanes: get_thread_card enumerates a named chat's card without focusing it
ok - fm-playbot-lanes: answer_thread_card refuses a borrowed request id, an unknown question, a moved turn, and an implicit skip
ok - fm-playbot-lanes: answer_thread_card answers the card once and reports a second attempt as already answered
ok - fm-playbot-lanes: get_thread_card contradicts a persisted pending_input that holds no live card
ok - fm-playbot-lanes: queued messages are listable and one can be dropped instead of resent
ok - fm-playbot-lanes: a renamed channel or changed snapshot shape refuses and names what is missing
ok - fm-playbot-lanes: send_message reports held, in-flight, and delivered separately
ok - fm-playbot-lanes: dispatch onto a parked worker reports the task as held, not delivered
ok - fm-playbot-lanes: a Playbot that returns no send snapshot leaves delivery explicitly unconfirmed
ok - fm-playbot-lanes: an unconfirmed wake advances only on a Playbot whose send path cannot report a verdict
ok - fm-playbot-lanes: a chat-creation probe that fails after the send does not mislabel the wake as undelivered
ok - fm-playbot-lanes: a worker in a project Playbot no longer marks active still wakes its supervisor
```

Those checks run against the hermetic fake DevTools endpoint described below, extended to serve the card channels, to reject a named channel as unregistered, and to omit a snapshot field, so the loud-refusal paths are enforced without waiting for a real Playbot upgrade.

### Dispatch-armed supervision poll

On 2026-08-24, `dispatch` from an external-terminal caller was verified to arm that worker's firstmate watcher poll itself, because Playbot offers such a caller no push path at all: `identify_current_thread` returns `{"controller":"external-terminal","thread":null}`, and `register_lane` refuses with `register_lane requires a Playbot controller chat`.

The firstmate-side half is enforced end to end in `tests/fm-playbot-lanes.test.sh` against the hermetic endpoint, using the real `bin/fm-check-register.sh` and the real `bin/fm-watch.sh` through `bin/fm-watch-checkpoint.sh`, so the proof is a watcher wake rather than the existence of a file:

```text
ok - fm-playbot-lanes: an external-terminal dispatch arms and registers that worker's watcher poll
ok - fm-playbot-lanes: fast and unsampled completed turns are reported while an untouched worker is not
ok - fm-playbot-lanes: failed check removal leaves the poll armed and registered
ok - fm-playbot-lanes: the armed poll keeps the real watcher silent while the worker is working
ok - fm-playbot-lanes: the armed poll wakes the real watcher when the worker parks, naming the task
ok - fm-playbot-lanes: a fired poll reports held messages and keeps firing while the worker stays parked
ok - fm-playbot-lanes: re-dispatching a task re-arms its poll onto the new worker
ok - fm-playbot-lanes: failed restoration re-registration is loud even for identical check bytes
ok - fm-playbot-lanes: the armed poll reports a stopped worker once and then retires itself
ok - fm-playbot-lanes: queued work can progress, while failed delivery stays armed
ok - fm-playbot-lanes: delivered unreadability retires while restored unknown delivery stays armed
ok - fm-playbot-lanes: a dispatch without a taskId still arms a poll, keyed on the workspace
ok - fm-playbot-lanes: null and non-string taskIds take the workspace fallback
ok - fm-playbot-lanes: an unusable taskId is refused before any worker is created or sent to
ok - fm-playbot-lanes: a dispatch whose arming failed says so instead of looking supervised
ok - fm-playbot-lanes: arming never replaces a check this server did not generate
ok - fm-playbot-lanes: arming a merged-PR poll over a lane poll refuses by name and leaves it intact
ok - fm-playbot-lanes: concurrent owners serialize and dead or PID-reused publication locks recover
ok - fm-playbot-lanes: a Playbot-chat dispatch keeps its routed wake and arms no poll
ok - fm-playbot-lanes: create_chat arms nothing, because it starts no worker
```

The armed poll's own read is the version-coupled half, so it was verified against the running Playbot 0.95.0 on Linux on the same date, with no write to Playbot of any kind.
Run directly against the live application database, `supervision-poll` printed nothing for the genuinely working chat `chat-3789180e-0635-451b-b217-47e0c45749ea`, and one line for the idle `chat-7975fcb9-7add-4c6f-8add-1ddd6428a39d`:

```text
playbot lane fm-live-probe: worker chat-7975fcb9-7add-4c6f-8add-1ddd6428a39d stopped without a card (status ready)
```

A poll for a thread id the database does not hold, and a poll given incomplete arguments, each printed their one loud line and exited 0 rather than failing silently, which matters because `bin/fm-watch.sh` discards a check's stderr and exit code and wakes on stdout alone.
The generated check was then registered into a scratch home with the real `bin/fm-check-register.sh`, retargeted at that live application database, and executed through the watcher's own `fm_custom_check_snapshot_prepare` path: the trust binding validated, the working chat produced no output, and the idle chat produced the single line above.

Not verified against a live Playbot: creating a real throwaway workspace and driving a real worker through it.
Playbot exposes no supported workspace-retirement path on 0.94.0 or newer (see the `workspace:delete` evidence dated 2026-08-18, which was taken on 0.93.1), so a live dispatch would have left a workspace behind that only manual surgery could remove.

A parked worker is a standing condition and a finished one is news exactly once, so the poll keeps firing while the worker is `pending_input` and fires only on the change into a stopped or unreadable state, after which it removes its own check, trust binding, and `state/<id>.lane-poll` record.
An idle worker whose dispatched task is still held in Playbot's queue, or whose queue cannot be read, never retires, because retirement is irreversible and a task that was never delivered still needs its supervisor.
It is reported when it appears and then stays quiet, because every branch that can print fires on a difference from the last observation rather than on a condition still being true, and `pending_input` is the one deliberate exception since answering the card is what resolves it.
That change is decided on the pair of `agent_status` and the row's `updated_at`, which `threadRows()` already selects, because a send does not wait for the turn to start.
A worker dispatched onto an already-idle chat is armed at `ready` and finishes back at `ready`, so a status compared on its own would report that completed worker as no change at all and drop the one wake this surface exists to deliver; the fixture drives exactly that sequence, with the intermediate `working` never observed by the poll, and the suite fails without the pair.
That transition rule, the queued-task rule above it, and the reserved refusal status below were all added on 2026-08-25, after the 2026-08-24 live run, and the transition rule gave the generated check a third argument, `--state`, so the live lines recorded here were produced by the earlier two-argument invocation and every rule added that day is proved against the hermetic fixture rather than live.
The check's bytes are hash-bound by `bin/fm-check-register.sh`, so that record is a separate private file rather than a rewrite of the check, and `bin/fm-teardown.sh` removes it with the rest of a task's state.
`bash tests/fm-pr-check-security.test.sh` covers that removal and passed all 36 checks on 2026-08-25.
`state/<id>.check.sh` is also the name firstmate's merged-PR poll owns, so both directions of that shared boundary refuse rather than overwrite.
The lane arming leaves a foreign check byte-identical, and `bin/fm-pr-check.sh` refuses by name and exits non-zero when it would publish over a lane poll.
The suite proves that second direction by arming a real generated lane poll and then running the real `bin/fm-pr-check.sh` for the same task id, which leaves the lane poll intact and its trust binding valid.
That refusal costs merge detection only, never the merge: it exits with the status `bin/fm-pr-lib.sh` reserves for it, and `bin/fm-pr-merge.sh` continues past that one status while every other failure still aborts the merge.
`bash tests/fm-pr-merge.test.sh` proves both halves with a recording fake forge on PATH, one case binding a marker-bearing lane-poll fixture through the real `bin/fm-check-register.sh` and merging anyway, and one case failing a state-integrity prepass on a re-run whose `pr=` is already recorded and never reaching the forge at all, and passed all 12 checks on 2026-08-25.

On 2026-08-25, forced steering was live-verified against Playbot 0.95.0 on Linux with `playbot_lanes@0.4.0` and Node v26.7.0.
`node --no-warnings bin/fm-playbot-lanes.mjs doctor` reported `renderer: true`, `chatCreation: "launch"`, and `playbotApp: {version: "0.95.0", verifiedVersions: "0.95.x"}`.
The installed 0.95.0 `resources/app.asar` registered `threads:steerMessage` with strict `{threadId, messageId}` input.
Its handler requires the named thread to remain in a prompting phase with an active turn id and the named local message to remain queued, marks that exact message as `steering`, calls Codex `turn/steer` with the expected current turn id, and returns the resulting thread snapshot.
It does not call Codex `turn/interrupt`, which is the evidence that forced steering continues rather than stops the active turn.

A scratch chat in the non-selected `ws_dcea82fc1107` workspace first received a no-file-write instruction that ran `sleep 30`.
While that exact chat was working, the live force call was:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{"project":"project_df995db1b164","workspace":"ws_dcea82fc1107","thread":"chat-a4b01c18-a9f4-42b2-93f3-fa8e84827534","message":"FORCE STEER: after the sleep, reply exactly FORCED-ACK and do nothing else.","force":true}}}' \
  | node --no-warnings bin/fm-playbot-lanes.mjs serve
```

The exact force and delivery fields returned by Playbot's own response snapshot were:

```json
{
  "delivery": {
    "state": "steering",
    "messageId": "0eed118f-bd86-4216-a8d5-09fa3fa92ba5",
    "queuedTotal": 1,
    "queuedAhead": 0
  },
  "force": {
    "requested": true,
    "state": "applied",
    "mechanism": "threads:steerMessage",
    "activeTurn": "continues",
    "evidence": "Playbot's response snapshot marked the exact queued message steering=true"
  }
}
```

The same turn's persisted rollout then recorded the forced text as a user message and completed with final answer `FORCED-ACK`, rather than the initial prompt's `INITIAL-COMPLETE`.
The exact scratch chat was archived after the readback, its queue was empty, its workspace remained non-selected, and no other chat or workspace was selected, stopped, created, or archived by the force call.

The focused behavioral command `bash tests/fm-playbot-lanes.test.sh` with Node v26.7.0 passed all 59 executed checks on 2026-08-25.
The three force-specific checks exercised the executable MCP against its fake DevTools endpoint and verified the public schemas, exact thread and message ids sent to `threads:steerMessage`, the `steering=true` evidence gate, matching `dispatch` behavior for an existing thread, absence of selection and interrupt calls, unchanged default queue behavior, local-refresh independence, and an `unknown` result when Playbot did not confirm the force action.

This suite previously printed `ok - fm-playbot-lanes: skipped (node unavailable)` and exited 0 whenever `node` was absent from `PATH`, which made a green run prove nothing: the same inherited-`PATH` gap that hides `shellcheck` and `actionlint` from a hook or validation-pipeline subprocess also hid the Node runtime, and one review round on this branch reported "there is no Node runtime anywhere on this machine" while `/home/linuxbrew/.linuxbrew/bin/node` was installed and in use.
`fm_test_require_node` in `tests/lib.sh` now resolves a runtime from `FM_TEST_NODE`, then `PATH`, then the known fixed and version-managed install roots, version-sorting each globbed directory so no version is pinned, and it fails the suite when none is usable rather than skipping.
It was verified on 2026-08-25, the date of the suite run recorded above, by running it under `env -i HOME=$HOME PATH=/usr/bin:/bin`, where `command -v node` finds nothing: the suite resolved `/home/linuxbrew/.linuxbrew/bin/node` (26.7.0) and executed all 76 checks, and its first line now names the runtime it used so an executed run is distinguishable from a skipped one at a glance.

On 2026-07-30, Playbot 0.81.0 on Windows exposed one shared Codex app-server process for multiple persisted chat threads.
The Windows session-lock verification proved that Git Bash can recover that host process through PowerShell while `CODEX_THREAD_ID` plus the Playbot database narrows ownership to the exact unarchived Firstmate thread.
The regression command was `"C:\Program Files\Git\bin\bash.exe" tests/fm-playbot-session-lock.test.sh`.
It proved that a second live thread is refused even when both threads share one Codex pid, an archived prior thread is reclaimable, and database uncertainty fails closed.

On 2026-08-19 at 12:25 UTC, `bash tests/fm-playbot-lanes.test.sh` with node v26.7.0 passed all 23 checks against pipeline head `11af79e7` (exported tree), covering the external-terminal guarantees added for callers outside a Playbot controller chat:

```text
ok - fm-playbot-lanes: normal-terminal callers need no Playbot controller project
ok - fm-playbot-lanes: identity stays readable for chats outside the controller project
ok - fm-playbot-lanes: normal-terminal callers can poll thread status
ok - fm-playbot-lanes: normal-terminal callers can read worker conversations
ok - fm-playbot-lanes: normal-terminal register_lane fails closed toward polling supervision
ok - fm-playbot-lanes: setup reloads a stale MCP identity without requiring a controller project
ok - fm-playbot-lanes: normal-terminal dispatch uses explicit polling supervision
```

That run was performed in the author environment because the pipeline environment lacks node, and the suite self-skipped when node was off `PATH` at the time; the 2026-08-24 entry above replaced that skip with a hard failure and is the current owner of the suite's node-resolution behavior.

On 2026-08-20, Playbot 0.94.0 on Linux was verified to have removed the `threads:openThread` and `workspace:create` IPC handlers and folded chat and workspace creation into one strict `threads:launch` call.
The facts were confirmed from the running app's extracted `.vite/build/main.js`: IPC channels are registered as `${module}:${key}` from per-module tables, `threads:launch` takes `{destination: existing-workspace | new-workspace, thread: {title (trim min 1), approvalMode ("default"|"auto-review"|"full-access"), planMode, ...} (strict, no caller-chosen id), message?, activate?}` and returns the persisted `workspace` and `thread`, the new-workspace `workspace` field reuses the exact pre-0.94 `{strategy: "project", projectId, name?, branch?, baseBranch?}` shape, the `workspace` module registers no bare creation channel, and `threads:send` (`{threadId, text, ...}`) plus `threads:archiveThread` (`{threadId, nextActiveThreadId?}`) are unchanged.

Live evidence against the running Playbot 0.94.0 on the same date:

- `doctor` reported `chatCreation: "launch"` from the side-effect-free capability probe, and `setup` returned `ready: true`, `changed: false` without touching the healthy installation.
- An external-terminal `dispatch` with `newWorkspace: {name: "smoke-delete-me"}` into project `project_df995db1b164` created workspace `ws_3ee259e69989` with a provisioned worktree, created chat `chat-d32cc81d-5ac0-4320-a485-d5c505fc0d4a` under Playbot's own generated id, and delivered the task through the unchanged `threads:send`.
- The chat acquired Codex session `01a01ed0-11f7-7863-aa72-add41494c590` and completed turn `01a01ed0-1840-7481-b9cc-e778bf22fd8f` with final answer `ACK`, read back through `read_thread` without resuming the chat.
- The created workspace stayed `selected: false`, proving `activate: false` prevents the selection change Playbot 0.93.x's create handler used to make.
- `archive_chat` archived the smoke chat through the unchanged `threads:archiveThread`; the DevTools HTTP endpoint was transiently unresponsive for roughly three minutes mid-smoke and recovered on its own, so a lane timeout is worth one retry before deeper diagnosis.

The focused regression command `bash tests/fm-playbot-lanes.test.sh` with node v26.7.0 passed all 28 checks on the same date, including six added or reworked for the 0.94.0 surface and the legacy fallback:

```text
ok - fm-playbot-lanes: doctor detects the 0.94.0 threads:launch API from the safe capability probe
ok - fm-playbot-lanes: create_workspace launches the 0.94.0 new-workspace payload and archives its setup chat
ok - fm-playbot-lanes: create_chat launches with the Playbot-generated thread id and no UI activation
ok - fm-playbot-lanes: doctor detects the pre-0.94 chat-creation API on a legacy Playbot
ok - fm-playbot-lanes: create_workspace falls back to workspace:create on a legacy Playbot
ok - fm-playbot-lanes: dispatch falls back to the pre-0.94 channels on a legacy Playbot
```

The fake DevTools endpoint inside the test serves the 0.94.0 `threads:launch` surface by default and the pre-0.94 surface in its legacy mode, so both adapter paths and the missing-handler detection between them are enforced hermetically.
