# Test service

`bin/fm-test-service.py` runs submitted tests after the submitting worker exits.
It keeps its SQLite request database, independent Git copies, logs, result records, and `status.json` under `~/.local/state/firstmate-test-service/`.
`FM_TEST_SERVICE_STATE` can select a different persistent directory for a separate instance or a test.
The status file contains queue order, the running request, per-request and per-step state, wait time, run time, tested SHA, and failure summary for the crew board.

Install the user unit from the checked-out code root with `bin/fm-test-service.py install-unit`, then run `systemctl --user daemon-reload` and `systemctl --user enable --now fm-test-service.service`.
The generated unit runs `serve`, restarts it after a failure, and stops its process group on shutdown.
A request marked running at service startup returns to the queue and reruns from a fresh detached copy.
The service keeps a private copy of each submitted commit so removing a worker's checkout does not change the test target.

Put one JSON file per project at `FM_HOME/config/test-service/PROJECT.json`.
The file names the suite and device executable argv arrays relative to the tested checkout, the ordered phone serials, named scenario argument arrays, and the landing branch.
Retests read the submitting worktree's common Git storage by default, so a disposable linked worktree can disappear after submission.
An optional `landing_repo` absolute path, with `{fm_home}` expansion, selects a different durable local clone.
Use `{serial}` in the device argv where the chosen serial belongs.
The configured commands must be the project's existing shared queue entry points when it has them.
The service invokes FrogPile's suite and phone scripts, which own their shared tickets and locks; it does not take a competing lock or stop the adb server.
The service starts a request's suite and phone steps concurrently, then runs any committed harness scripts from that request.

For FrogPile, copy [the example](examples/fm-test-service-frogpile.json) into `FM_HOME/config/test-service/frogpile.json`.
`any_device` delegates an `any` request to the project queue entry point after preparing each serial in `any_phones`, ordered with the S22 first.
The M31 remains explicitly addressable for performance requests.
The example is configuration, not a second copy of the suite or phone queue.

A worker can submit the exact committed head, wait for its result, and hand the success record to `fm-merge-local.sh --receipt`:

```sh
sha=$(git rev-parse HEAD)
request=$(bin/fm-test-service.py submit frogpile "$PWD" "$sha" --suite --device-gate R5CT32HRVNM --receipt "$PWD/full-suite.receipt")
bin/fm-test-service.py wait "$request"
```

`submit` refuses a short SHA, an unavailable commit, a harness that is not committed in that commit, an unknown scenario, or a phone outside the project configuration.
`status --json` prints the same JSON published at the status path; `cancel ID` cancels a queued request, asks the runner to stop a running one, or stops future retests of a completed one.
A request with `--suite` writes a success receipt with exactly the three lines accepted by `fm-merge-local.sh`; a failed run writes `results/ID/SHA.failure.json` with its first failing step and message.
Per-step logs stay under the service state directory.

`--retest-on-move` watches the configured landing branch after the first run.
When it changes, the service rebases the original commit onto the new tip in a scratch copy and queues the resulting SHA for a fresh run.
A rebase conflict becomes a `conflict` result and is never guessed through.
The updated tested SHA and receipt appear in status and results.
The original commit copy remains available for later branch moves.

Before every phone run, the service wakes the selected phone, sets `stay_on_while_plugged_in` to `2` if needed, and checks the keyguard.
If locked, it reads `~/.config/firstmate/test-device-pins` only when the file is a regular non-symlink file with no group or other permissions.
The file uses one `SERIAL=PIN` line per phone; use `chmod 600` and keep it outside repositories.
The service sends the PIN to an adb shell through stdin and suppresses shell output.
A phone without a PIN line is treated as unlocked unless the keyguard is showing; then the service fails with `phone-locked` and names the serial and file to update.
It checks the keyguard again and fails with `phone-locked` if unlock did not work.
No PIN belongs in a request, status, receipt, log, brief, or PR.
