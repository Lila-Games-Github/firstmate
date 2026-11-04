---
name: landing-queue
description: >-
  Agent-only procedure for firstmate's side of the worker-owned local landing train.
  Use on any `landing-queue ready-to-land`, `landing-queue needs-baseline`, `landing-queue failed`, `landing-queue testfarm-unreachable`, or `landing-queue sweep` check wake.
  Owns the status recheck, baseline recording, the landing decision under the existing merge authority, and the no-steering rule.
user-invocable: false
metadata:
  internal: true
---

# landing-queue

Load this on any `check: landing-queue <status> task=<id> ...` wake.
`bin/fm-landing-queue.sh`'s header and `--help` own the queue protocol, statuses, and receipt format; this skill owns only what firstmate does with its wakes.
Workers own admission, rebasing, suite runs, and receipts, so never message a worker about its place, target, rebase, or suite timing, and never edit queue files by hand; the queue tool alone steers paused workers when their car leaves parking.
Workers also record configured landing-gate passes through the queue tool; a missing gate remains their work and emits no readiness wake.

## Move a waiting car

When the captain requests a queue reorder, use `bin/fm-landing-queue.sh move <id> --project <project> --landing-branch <landing> --place <number>` with this home's `FM_HOME`.
The script header owns the place numbering and refusal rules.
Use `status` afterward to report the resulting places; the queue tool handles any due worker steer.

## Recheck

A wake is an event, not current state.
Before acting, run `FM_HOME=<this home> bin/fm-landing-queue.sh status <id> --project <project> --landing-branch <landing>` with the wake's fields.
Act only on the status it prints now; if it changed, take no queue action, because the tool wakes again for the next actionable transition.

## ready-to-land

Apply the existing merge authority for a local-only landing, exactly as for any other local-only task.
With authority, run `bin/fm-merge-local.sh <id> --receipt <receipt>` using the `receipt` path from the recheck, then push only when the project's delivery path authorizes it.
`fm-merge-local.sh` reconciles the queue after landing, which steers the landed car's worker and a waiting next car once each; they read `landed` and the new target from the queue themselves.

## needs-baseline

The landing tip named by the recheck's `tip` is red and has no recorded landing-health baseline, so the car's red receipt cannot yet be judged.
Obtain a full-suite receipt for exactly that tip commit, never for the car.
Record it with `bin/fm-landing-queue.sh baseline <id> --receipt <tip receipt>` using the same environment and options; this records the baseline only, lands nothing, and steers the paused worker with its resolved status.
That output's status is now `ready-to-land`, which wakes again and is handled as above, or `needs-gate` or `red-receipt`, which leave the missing gate or the extra failures to the car's own worker under the same task id.
Reserve `fail` for a car that genuinely cannot continue.

## sweep and testfarm-unreachable

The watcher's sweep settles each front quick check from the test farm itself, so a car never waits on its worker to report; the queue tool's header owns that `resolve` contract.
A `landing-queue sweep: front-check` wake only announces the durable row queued beside it: `front-check passed` pairs with a `ready-to-land` row, handled as above, and `front-check unreachable` with a `testfarm-unreachable` row.
A `landing-queue testfarm-unreachable` wake means the front car is unchanged because the farm's status could not be read, and the sweep retries on its own.
Check the farm with `testfarm doctor` and restore its runner if it is down; escalate to the captain only when it cannot be restored, and send no queue coordination to the worker.
A `landing-queue sweep failed:` wake means the sweep itself could not run, so no train is being settled; repair the named cause in this home, and the next successful sweep clears it.

## failed

The tool has already removed the car, and its successors retarget themselves from status.
Handle the worker's `failed:` status line as an ordinary failed task; send no queue coordination to the remaining cars.
