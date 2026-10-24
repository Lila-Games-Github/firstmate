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
The file names the suite and device executable argv arrays relative to the tested checkout, the ordered phone serials, named scenario argument arrays, and the landing branch.
`max_concurrent` limits active requests for that project; it defaults to one and may be set from one to sixteen.
An optional `repos` list names the Firstmate repository names that use this project's configuration; a repository whose name matches the file name needs no entry.
A ship brief for a repository that matches exactly one configuration names that project in its test-service gate.
Each suite command must use its project's shared queue entry point, so other callers and service requests share the same capacity and arrival order.
An optional `prepare` argv runs once in the clean detached copy before either suite or phone step; it must leave the tracked tree clean.
Retests read the submitting worktree's common Git storage by default, so a disposable linked worktree can disappear after submission.
An optional `landing_repo` absolute path, with `{fm_home}` expansion, selects a different durable local clone.
Use `{serial}` in the device argv where the chosen serial belongs.
The phone command must use the project's shared phone queue entry point when it has one.
FrogPile's suite configuration calls `prototype-game/tests/run_suite.sh`, whose four-place queue owns suite admission, worktree isolation, the no-output watchdog, and script-error verdicts for service and direct callers alike.
The example caps FrogPile at four active requests through `max_concurrent`; these request slots include phone and preparation time.
The service takes no separate suite or phone lock and does not stop the adb server.
The service starts a request's suite and phone steps concurrently after preparation, then runs any committed harness scripts from that request.

For FrogPile, copy [the example](examples/fm-test-service-frogpile.json) into `FM_HOME/config/test-service/frogpile.json`.
An `any` request chooses the first connected phone in `any_phones`, ordered with the S22 first, and enters the project's shared queue for that phone.
The older `any_device` command remains accepted in existing configuration files but is ignored so a project queue cannot select a phone outside `any_phones`.
When a named phone is disconnected, `equivalent_phones` selects the first connected alternative and the project queue waits until that phone is idle.
The service monitors the selected phone during the test and retries on another equivalent if it disconnects.
When none is connected, the request fails with a `device-unavailable` alert instead of leaving an offline ticket waiting forever.
Submit a new request after a phone reconnects.
The FrogPile preparation starts Godot's editor import so class discovery works in a fresh checkout.
The M31 remains explicitly addressable for performance requests and is excluded from the functional phone alternatives.
The example is configuration, not a second copy of the suite or phone queue.

A worker can submit the exact committed head, wait for its result, and hand the success record to `fm-merge-local.sh --receipt`:
For a dispatched ship task in a configured project, use the exact `data/<task-id>/suite.receipt` path printed in its brief; the service creates that receipt on success.

```sh
task_id=frogpile-example
sha=$(git rev-parse HEAD)
request=$(bin/fm-test-service.py submit frogpile "$PWD" "$sha" --task "$task_id" --suite --device-gate any --receipt "$FM_HOME/data/$task_id/suite.receipt")
bin/fm-test-service.py wait "$request"
```

`submit` refuses a short SHA, an unavailable commit, a harness that is not committed in that commit, an unknown scenario, or a phone outside the project configuration.
`status --json` prints the same JSON published at the status path; `cancel ID` cancels a queued request, asks the runner to stop a running one, or stops future retests of a completed one.
A request with `--suite` writes a success receipt with exactly the three lines accepted by `fm-merge-local.sh`; a failed run writes `results/ID/SHA.failure.json` with its first failing step and message.
Per-step logs stay under the service state directory.

`--retest-on-move` watches the configured landing branch after the first run.
When it changes, the service rebases the original commit onto the new tip in a scratch copy and queues the resulting SHA for a fresh run.
A rebase conflict becomes a `conflict` result and is never guessed through.
The updated tested SHA and its receipt appear in status and under `results/ID/`.
A retest of a rebased SHA never writes the `--receipt` path, so that receipt always names the submitted commit.
The original commit copy remains available for later branch moves.

Before every phone run, the service wakes the selected phone, sets `stay_on_while_plugged_in` to `2` if needed, and checks the keyguard.
If locked, it reads `~/.config/firstmate/test-device-pins` only when the file is a regular non-symlink file with no group or other permissions.
The file uses one `SERIAL=PIN` line per phone; use `chmod 600` and keep it outside repositories.
The service sends one digit key event at a time to an adb shell through stdin and suppresses shell output.
A phone without a PIN line is treated as unlocked unless the keyguard is showing; then the service fails with `phone-locked` and names the serial and file to update.
It checks the keyguard again and fails with `phone-locked` if unlock did not work.
No PIN belongs in a request, status, receipt, log, brief, or PR.
