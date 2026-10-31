---
name: landing-queue
description: >-
  Agent-only procedure for firstmate's side of the worker-owned local landing train.
  Use on any `landing-queue ready-to-land`, `landing-queue needs-baseline`, or `landing-queue failed` check wake.
  Owns the status recheck, baseline recording, the landing decision under the existing merge authority, and the no-steering rule.
user-invocable: false
metadata:
  internal: true
---

# landing-queue

Load this on any `check: landing-queue <status> task=<id> ...` wake.
`bin/fm-landing-queue.sh`'s header and `--help` own the queue protocol, statuses, and receipt format; this skill owns only what firstmate does with its wakes.
Workers own admission, rebasing, suite runs, and receipts, so never message a worker about its place, target, rebase, or suite timing, and never edit queue files by hand; the queue tool alone sends the front steer.
Workers also record configured landing-gate passes through the queue tool; a missing gate remains their work and emits no readiness wake.

## Recheck

A wake is an event, not current state.
Before acting, run `FM_HOME=<this home> bin/fm-landing-queue.sh status <id> --project <project> --landing-branch <landing>` with the wake's fields.
Act only on the status it prints now; if it changed, take no queue action, because the tool wakes again for the next actionable transition.

## ready-to-land

Apply the existing merge authority for a local-only landing, exactly as for any other local-only task.
With authority, run `bin/fm-merge-local.sh <id> --receipt <receipt>` using the `receipt` path from the recheck, then push only when the project's delivery path authorizes it.
`fm-merge-local.sh` reconciles the queue after landing, which steers a waiting next car to the front once; the worker and that car read `landed` and the new target from the queue themselves.

## needs-baseline

The landing tip named by the recheck's `tip` is red and has no recorded landing-health baseline, so the car's red receipt cannot yet be judged.
Obtain a full-suite receipt for exactly that tip commit, never for the car.
Record it with `bin/fm-landing-queue.sh baseline <id> --receipt <tip receipt>` using the same environment and options; this records the baseline only and lands nothing.
That output's status is now `ready-to-land`, which wakes again and is handled as above, or `needs-gate` or `red-receipt`, which leave the missing gate or the extra failures to the car's own worker under the same task id.
Reserve `fail` for a car that genuinely cannot continue.

## failed

The tool has already removed the car, and its successors retarget themselves from status.
Handle the worker's `failed:` status line as an ordinary failed task; send no queue coordination to the remaining cars.
