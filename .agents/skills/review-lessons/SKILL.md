---
name: review-lessons
description: >-
  Curate recurring review waste and escaped-defect patterns during the daily lessons check.
user-invocable: false
metadata:
  internal: true
---

# Review lessons

Load during every `lessons-daily` check after the ordinary learning-candidate batch.
Run this pass on the existing cheap routine-check lane.
The curator must be distinct from the task where an incident originated.

## Input

Run `bin/fm-review-lessons.py extract` against the local no-mistakes `state.sqlite` and this home's `state/learning-candidates` directory.
For the first pass, omit `--since` so every recorded run and escaped defect is considered.
Later passes use `--since` with the last successful pass date and revisit retained patterns against the new evidence.
Include a current export of Rocketboard BUG cards traced to landed changes through `--bug-cards` when the card source is available.
Do not infer a review escape from a card without a landed change reference.
If the card source is unavailable, state that coverage gap in the report and leave the card pass pending.
The extractor reads its sources without mutation and writes JSON Lines to the named output path.
It records per-run review invocations, rounds, tokens, findings, selected fixes, and likely same-issue re-raises.
Treat a likely re-raise as a lead for source inspection, not a confirmed duplicate.
Selection for a fix is not proof that the fix succeeded; compare subsequent rounds and landed behavior before stating that a finding was fixed.
The no-mistakes ledger has no price data; use an explicitly dated price source or report tokens without a dollar figure.

## Curation

Keep the private `data/review-playbook.json` as a short curated list and rewrite it on each daily pass, pruning entries whose evidence or prevention no longer holds.
For recurring review waste, compare re-raised findings across rounds, dismissed findings, complete-diff re-reviews, and repeated low-value nits across projects.
For each escaped-defect candidate and landed BUG card, answer how the defect passed review, why the relevant behavior was not checked, and what general check would have caught it.
Cluster by missing check or wasted review behavior, not by feature, file, task, project, or bug ID.
Require at least two distinct source records for a retained recurring pattern and keep those source IDs in `evidence`.
Every entry has `kind` (`waste` or `miss`), `pattern`, `prevention`, `owner`, and `evidence`.
Route a prevention to exactly one owner: `reviewer-guidance`, `firstmate-brief`, `project-agents`, or `no-mistakes-follow-up`.
Reviewer guidance is passed to the review pipeline through its supported configuration; project instructions use that project's normal delivery path; a no-mistakes tool change is a named follow-up, never an edit from this pass.
Run `bin/fm-review-lessons.py validate data/review-playbook.json` before reporting the playbook.
The validator rejects obvious instance-only entries, but the curator must reject semantic one-offs that evade its syntax check.
Report pattern additions, revisions, prunes, owner routing, and input coverage in the ordinary daily lessons report.
