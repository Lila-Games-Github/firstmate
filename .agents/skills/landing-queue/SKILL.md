---
name: landing-queue
description: >-
  Agent-only procedure for firstmate's side of the worker-owned local landing train.
  Use on any `landing-queue ready-to-land`, `landing-queue needs-baseline`, or `landing-queue failed` check wake.
  Owns the status recheck, the landing and baseline decisions under the existing merge authority, and the no-steering rule.
user-invocable: false
metadata:
  internal: true
---

# landing-queue

Load this on any `check: landing-queue <status> task=<id> ...` wake.
`bin/fm-landing-queue.sh`'s header and `--help` own the queue protocol, statuses, and receipt format; this skill owns only what firstmate does with its wakes.
Workers own admission, rebasing, suite runs, and receipts, so never message a worker about its place, target, rebase, or suite timing, and never edit queue files by hand.

## Recheck

A wake is an event, not current state.
Before acting, run `FM_HOME=<this home> bin/fm-landing-queue.sh status <id> --project <project> --landing-branch <landing>` with the wake's fields.
Act only on the status it prints now; if it changed, take no queue action, because the tool wakes again for the next actionable transition.

## ready-to-land

Apply the existing merge authority for a local-only landing, exactly as for any other local-only task.
With authority, run `bin/fm-merge-local.sh <id> --receipt <receipt>` using the `receipt` path from the recheck, then push only when the project's delivery path authorizes it.
The worker and the next car observe `landed` and the new target from the queue themselves.

## needs-baseline

The landing tip named by the recheck's `tip` is red and has no recorded landing-health baseline, so the car's red receipt cannot yet be judged.
Obtain a full-suite receipt for exactly that tip commit, never for the car.
When the tip receipt's failing set covers every failure in the car's receipt, land as for `ready-to-land`, adding `--base-receipt <tip receipt>`.
Otherwise the car introduced the extra failures: run `bin/fm-landing-queue.sh fail <id> --reason <those failures>` with the same environment and options, and the worker reports `failed:` from its own status.

## failed

The tool has already removed the car, and its successors retarget themselves from status.
Handle the worker's `failed:` status line as an ordinary failed task; send no queue coordination to the remaining cars.
