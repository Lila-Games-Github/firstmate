# Test service

`bin/fm-test-service.py` runs submitted tests after the submitting worker exits.
It keeps its SQLite request database, independent Git copies, logs, result records, and `status.json` under `~/.local/state/firstmate-test-service/`.
`FM_TEST_SERVICE_STATE` can select a different persistent directory for a separate instance or a test.
The status file contains queue order, `running_requests` and `waiting_requests` arrays with task, SHA, state, start time, and elapsed times, plus per-request and per-step detail for the crew board.
Its `alerts` array exposes requests that have no connected eligible phone.

Install the user unit from the checked-out code root with `bin/fm-test-service.py install-unit`, then run `systemctl --user daemon-reload` and `systemctl --user enable --now fm-test-service.service`.
The generated unit runs `serve`, restarts it after a failure, and stops its process group on shutdown.
A request marked running at service startup returns to the queue and reruns from a fresh detached copy.
The service keeps a private copy of each submitted commit so removing a worker's checkout does not change the test target.

Put one JSON file per project at `FM_HOME/config/test-service/PROJECT.json`.
`FM_TEST_SERVICE_CONFIG_ROOT` can point an isolated service instance at a different configuration directory while keeping `FM_HOME` for task completion delivery.
The file names `suite` and `device` executable argv arrays for the full pre-queue run and `quick_suite` and `quick_device` arrays for the front check, all relative to the tested checkout.
The quick suite receives the touched file paths, computed from the front target to the tested head, as trailing arguments; it maps those paths to related tests.
The quick device command performs the short phone check.
The file also names the ordered phone serials, named scenario argument arrays, and landing branch.
Optional `landing_gates` names checks the worker must record for the exact pre-queue head and tip before `ready` accepts the car.
FrogPile's example requires `real-phone`, which the worker records after the real-phone end-to-end check passes.
`max_concurrent` limits active suite requests for that project; it defaults to one and may be set from one to sixteen.
An optional `repos` list names the Firstmate repository names that use this project's configuration; a repository whose name matches the file name needs no entry.
A ship brief for a repository that matches exactly one configuration names that project in its test-service gate.
Each suite command must use its project's shared queue entry point, so other callers and service requests share the same capacity and arrival order.
An optional `prepare` argv runs once in the clean detached copy before either suite or phone step; it must leave the tracked tree clean.
Retests read the submitting worktree's common Git storage by default, so a disposable linked worktree can disappear after submission.
An optional `landing_repo` absolute path, with `{fm_home}` expansion, selects a different durable local clone.
Use `{serial}` in the device argv where the chosen serial belongs.
The phone command must use the project's shared phone queue entry point when it has one.
FrogPile's suite configuration calls `prototype-game/tests/run_suite.sh`, whose four-place queue owns suite admission, worktree isolation, the no-output watchdog, and script-error verdicts for service and direct callers alike.
The example caps FrogPile at four active suite requests through `max_concurrent`; these suite slots include phone and preparation time.
Requests without a suite start without consuming a suite slot, so a phone-only performance harness can use its free phone while suites wait for another phone.
The service takes no separate suite or phone lock and does not stop the adb server.
The service starts a request's suite and phone steps concurrently after preparation, then runs any committed harness scripts from that request.
Queued front checks start before ordinary queued requests; each class keeps submission order, and a request already running is never interrupted.

## Performance plans

Use `submit PROJECT WORKTREE SHA --perf-plan PATH` to run an ordered performance audit on one configured phone.
`PATH` names a JSON file committed in the tested project SHA, or `@service/PATH` for a file committed in the running Firstmate code checkout.
The service validates the pinned file before accepting the request and stores its parsed content in the durable request.
`--perf-plan` cannot be combined with `--suite`, `--device-gate`, `--scenario`, `--harness`, or `--retest-on-move`; submit the suite as its own request.
The [FrogPile plan](examples/fm-performance-frogpile-2026-11-02.json) selects pond, Harvesting List and Crew, and FTUE Missions from the 2026-11-02 audit.

The plan schema is `fm-performance-plan.v1` with a configured `device`, nonempty ordered `states`, and optional `compare_to` request ID.
Each state has a unique `name`, adapter `target`, distinct `measurements`, integer `repeats` from 1 to 20, and a `thresholds` map.
Each threshold names a numeric metric and gives `min`, `max`, or both, inclusive.
The service applies each threshold to every repeat, preserving all rows and verdicts even when a threshold fails.

The project's `performance` configuration declares the isolated `package`, `isolated_package_prefixes`, and argv arrays for `queue`, `build`, `install`, `drive`, `capture`, `pull`, and `uninstall`.
The executable in each array must be in the tested checkout; `@service/NAME` selects an executable shipped beside `fm-test-service.py` instead.
Placeholders are `{worktree}`, `{bundle}`, `{device}`, `{state}`, `{kind}`, `{repeat}`, and `{output}`.
`build` runs before the phone ticket; the queue command receives `--` and the service child command, and holds one lease while the child wakes the phone, clears a previous isolated app from the foreground, installs, drives each state, confirms app focus, captures, pulls, force-stops, and uninstalls.
The adapter's capture command writes a numeric JSON metric map to `{output}`; its pull command can also place `.pftrace` files under `{bundle}`.
Adapter executables are project-owned and committed in the tested checkout; Firstmate ships no project-specific adapter, so the [FrogPile configuration](examples/fm-test-service-frogpile.json) has no `performance` block until ProjectWhite commits its adapter.
The `frame` measurement kind is the first supported capture; Perfetto, SurfaceFlinger, simpleperf, Arm Streamline, and malioc kinds can use the same capture and pull hooks once their project harnesses land.
Metric names must be unique across a state's measurement kinds; a repeated name fails the request instead of overwriting the earlier value.
Each run recreates its bundle, so a requeued request never mixes rows or traces from an interrupted attempt.
Cancellation and service stop are reported as `cancelled` and `interrupted`, and a run that changes the tracked test copy fails like any other request.

The result is `results/REQUEST/SHA/performance/summary.json`, alongside each raw measurement, command log, and trace.
`summary.json` contains one row per state and repeat, pass status, and metric deltas against `compare_to` when supplied.
When traces are present, the service calls `trace_processor query` (or the adapter's `trace_processor` executable), stores every Perfetto slice in `traces.sqlite3`, and computes per-name wallclock totals in its `wallclock` table.
`bin/fm-test-service.py perf-query BUNDLE 'SELECT * FROM wallclock ORDER BY total_ms DESC LIMIT 20'` prints agent-queryable CSV; the same command can query `slices` directly.
Function rows are identified by `::` or `GDScript` names and other slices are labeled zones; the raw name, category, timestamps, and durations remain in the index for deeper queries.
`compare_to` must name one completed bundle in the same service state directory.

For the historical M31 reproduction, copy the FrogPile configuration into `FM_HOME/config/test-service/frogpile.json`, add a `performance` block pointing at ProjectWhite's committed adapter, then submit its audit-only commit with:

```sh
bin/fm-test-service.py submit frogpile /path/to/ProjectWhite e90ef2869c8bc8a2c9e441a69fbecec45f6be355 --perf-plan @service/docs/examples/fm-performance-frogpile-2026-11-02.json
```

For FrogPile, copy [the example](examples/fm-test-service-frogpile.json) into `FM_HOME/config/test-service/frogpile.json` and add the project's touched-file suite and short phone commands as `quick_suite` and `quick_device` before using the landing queue.
An `any` request enters the project's shared phone queue, which chooses the first eligible free phone from `any_phones` and gives waiting named-phone tickets priority.
While every eligible phone is busy, the project queue waits for one to become free.
An `any` device gate passes the any-phone sentinel to the project's `any_device` command when configured, or to its normal device command otherwise; a quick check uses `quick_device`.
When a named phone is disconnected or busy, `equivalent_phones` supplies other functional phones to try before waiting.
For named requests, the service monitors the selected phone during the test and retries on another equivalent if it disconnects.
When none of the named request's candidates is connected, the request fails with a `device-unavailable` alert instead of leaving an offline ticket waiting forever.
Submit a new request after a phone reconnects.
The FrogPile preparation starts Godot's editor import so class discovery works in a fresh checkout.
The M31 is eligible for any-phone functional requests when it has no waiting named-phone ticket, and remains explicitly addressable for performance requests.
The example is configuration, not a second copy of the suite or phone queue.

A worker submits the exact committed head and resumes on the completion message in its steering inbox.
Before joining a landing train, rebase onto the current tip and submit the full suite and phone play-through on that exact head, with the applicable benchmark as a landing gate.
The queue requires a green full-suite receipt and every configured gate receipt with the `ready` command.
At the front, rebase once and submit a quick check; if the new tip changed files this task touches or the quick check failed, queue status requires the full suite, phone play-through, and applicable benchmark again.
The front success receipt is accepted by `fm-merge-local.sh --receipt`.
For a dispatched ship task in a configured project, use the exact `data/<task-id>/suite.receipt` path printed in its brief; the service creates that receipt on success.

```sh
task_id=frogpile-example
sha=$(git rev-parse HEAD)
request=$(FM_HOME="$FM_HOME" bin/fm-test-service.py submit frogpile "$PWD" "$sha" --task "$task_id" --suite --device-gate any --receipt "$FM_HOME/data/$task_id/suite.receipt")
printf 'paused: test-service request=%s\n' "$request" >> "$FM_HOME/state/$task_id.status"
# End the worker turn here; resume when the completion message arrives.
```

Workers do not poll status or keep a `wait` session open for service requests.
For requests carrying `--task`, the service delivers one durable completion message through `fm-send.sh`, with the request id, terminal state, tested SHA, receipt path when written, and first failure line.
Delivery survives service restart and retries failed sends without duplicating the inbox message, including after the worker acknowledges it.
A retired task is skipped and logged; a failed send is logged and retried independently of test execution, with backoff growing to five minutes, and after 12 attempts publishes one firstmate `check:` wake naming the task and request id, then is marked failed.
Completions recorded before a store first gained its notification outbox are settled as skipped, so an upgrade never replays history.
The standalone `wait ID` command remains available for interactive operators and scripts.

`submit` refuses a short SHA, an unavailable commit, a harness that is not committed in that commit, an unknown scenario, or a functional phone outside `any_phones` when that list is configured.
`status --json` prints the same JSON published at the status path; `cancel ID` cancels a queued request, asks the runner to stop a running one, or stops future retests of a completed one.
A full request with `--suite` writes a three-line `fm-full-suite.v1` success receipt; a failed run writes `results/ID/SHA.failure.json` with its first failing step and message.
For a front check, submit `--suite --check quick --target <front-target-sha> --device-gate any --receipt <path>`.
The service requires both quick commands in the project configuration and writes `schema=fm-quick-check.v1`, `sha=<tested-full-sha>`, and `target=<front-target-sha>` after the touched-file suite and short phone check pass.
Quick requests cannot use `--retest-on-move`.
Per-step logs stay under the service state directory.
Once a request finishes, the service deletes its test checkout and scratch copy, and deletes its pinned commit copy unless the request still retests on landing-branch moves.

`--retest-on-move` watches the configured landing branch after the first run.
When it changes, the service rebases the original commit onto the new tip in a scratch copy and queues the resulting SHA for a fresh run.
A rebase conflict becomes a `conflict` result and is never guessed through.
The updated tested SHA and its receipt appear in status and under `results/ID/`.
A retest of a rebased SHA never writes the `--receipt` path, so that receipt always names the submitted commit.
The original commit copy remains available for later branch moves.
When the landing branch already contains the submitted commit, or its change rebases to nothing new, retests stop and the copy is deleted.

Before every phone run, the service wakes the selected phone, sets `stay_on_while_plugged_in` to `2` if needed, and checks the keyguard.
If locked, it reads `~/.config/firstmate/test-device-pins` only when the file is a regular non-symlink file with no group or other permissions.
The file uses one `SERIAL=PIN` line per phone; use `chmod 600` and keep it outside repositories.
The service sends one digit key event at a time to an adb shell through stdin and suppresses shell output.
A phone without a PIN line is treated as unlocked unless the keyguard is showing; then the service fails with `phone-locked` and names the serial and file to update.
It checks the keyguard again and fails with `phone-locked` if unlock did not work.
No PIN belongs in a request, status, receipt, log, brief, or PR.
