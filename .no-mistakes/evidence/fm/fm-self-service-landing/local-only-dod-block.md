# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/demo-task`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto your recorded landing branch - the `landing_branch=` firstmate recorded for this task in `'/tmp/demo-home/state/demo-task.meta'` (contract: bin/fm-spawn.sh's header), falling back to the default branch only when none is recorded.
Use the queue's current assigned target below when rebasing.
When it is implemented and committed, follow the self-service landing train below through landing.
The configured merge authority approves the ready branch, then firstmate merges it into that same recorded landing branch, or the default branch when none is recorded, through the guarded fast-forward path.

## Self-service landing train
Use the queue tool for your place, rebase target, and final receipt; do not wait for a firstmate message assigning or updating them.
The tool's header and `--help` own the protocol.
You may update this task's shared queue and receipt state through this tool, including when its home is outside your worktree.
Define this helper in your worker shell:
```sh
landing_queue() {
  local action=$1
  shift
  FM_HOME='/tmp/demo-home' FM_STATE_OVERRIDE='/tmp/demo-home/state' FM_DATA_OVERRIDE='/tmp/demo-home/data' '/var/home/sanchith/.no-mistakes/worktrees/f62841b885f5/01M5QQBPKA9WYZZZ60APAHHP6Y/bin/fm-landing-queue.sh' "$action" 'demo-task' --project . --landing-branch 'proto/dev' "$@"
}
```
1. Once implementation is committed, join with `landing_queue ready --branch "$(git branch --show-current)" --head "$(git rev-parse HEAD)"`.
2. Run `landing_queue status` before rebasing, before the exact-head full suite, after the suite, and whenever you resume waiting.
   Read its `place`, `target_ref`, `target_sha`, and `rebase_from`; these replace any earlier target, even if another car failed or landed.
   When the base changes, rebase your own commits with `git rebase --onto <target_sha> <rebase_from>`, then acknowledge the prepared head with `landing_queue ready --branch "$(git branch --show-current)" --head "$(git rev-parse HEAD)" --target <target_sha>`.
   Resolve rebase conflicts yourself; do not merge or keep commits from a failed lower car.
3. At `needs-final`, run the task's full suite on exactly that committed head and create its receipt using the format owned by `/var/home/sanchith/.no-mistakes/worktrees/f62841b885f5/01M5QQBPKA9WYZZZ60APAHHP6Y/bin/fm-landing-health-lib.sh`.
   Submit with `landing_queue receipt --head <tested-full-sha> --target <tested-target-sha> --receipt <file>`.
   A changed head or target refuses the receipt: read status, prepare the new target, and rerun the suite on the new head.
   If your car fails, record `landing_queue fail --reason <failure>` before reporting `failed:` and stopping.
   At `red-receipt`, do not rerun the suite on the same head: fix the failures its `reason` names in a new commit and finalize again, or record the failure as above.
   At `failed`, report `failed:` with the status `reason` and stop.
4. At `waiting-to-land`, `ready-to-land`, or `needs-baseline`, keep checking status every 30 seconds and read your steering inbox at those checkpoints.
   The tool emits the readiness or baseline wake only for the bottom car with a valid receipt; do not add a ready `done:` or ask firstmate to coordinate the queue.
   Firstmate handles those wakes under the existing merge authority; `/var/home/sanchith/.no-mistakes/worktrees/f62841b885f5/01M5QQBPKA9WYZZZ60APAHHP6Y/.agents/skills/landing-queue/SKILL.md` owns that procedure.
   A changed target returns you to preparation; at `landed`, append `done: landed {branch} at {head}` and stop.
