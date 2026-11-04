# Test service

Firstmate calls [testfarm](https://github.com/Lila-Games-Github/lila-test-farm/blob/main/docs/CONTRACT.md) through `bin/fm-test-service.py`.
The compatibility entry point forwards its arguments to the installed `testfarm` checkout, or to `TESTFARM_CHECKOUT` when set.
The testfarm contract owns project declarations, submission commands, request state, result files, phone queues, performance plans, and PIN management.

## Firstmate integration

`bin/fm-brief.sh` selects a registered project with `project-for-repo` and tells the worker where to write its full-suite receipt.
`bin/fm-landing-queue.sh` reads `landing-gates-for-repo` and submits its required checks through the same entry point.
`bin/fm-landing-health-lib.sh` validates the three-line `fm-full-suite.v1` receipt for the exact tested SHA.
The crew board reads testfarm's `status.json` through the existing `~/.local/state/firstmate-test-service` link; the `fm-test-service.v1` status schema remains supported.

A worker submits its committed SHA with `--task`, then ends the turn until testfarm delivers the completion message to its steering inbox.
For a full-suite gate, use the receipt path printed in the task brief.

```sh
task_id=frogpile-example
sha=$(git rev-parse HEAD)
request=$(FM_HOME="$FM_HOME" bin/fm-test-service.py submit frogpile "$PWD" "$sha" --task "$task_id" --suite --device-gate any --receipt "$FM_HOME/data/$task_id/suite.receipt")
printf 'paused: test-service request=%s\n' "$request" >> "$FM_HOME/state/$task_id.status"
```

The compatibility entry point needs an installed `testfarm` or `TESTFARM_CHECKOUT` pointing at a farm checkout.
Its project configuration source is testfarm's registration; `FM_HOME/config/test-service` remains a temporary compatibility source during migration.
CI runs the brief, landing queue, merge handoff, crew board queue, and stock macOS Bash compatibility checks when `TESTFARM_READ_TOKEN` can check out the private farm; without that secret it reports their farm-dependent cases as skipped and runs the remaining tests in each job.
The [migration guide](https://github.com/Lila-Games-Github/lila-test-farm/blob/main/docs/MIGRATION.md) owns the cutover and cleanup sequence.
