# Evidence: a Playbot lane brief that needs zero dispatch-time overrides

The user-facing product here is a **generated brief** (what a lane worker reads) and a
**CLI check** (what that worker runs as its first action). The artifacts below are the
real outputs of both, produced by running the shipped scripts — not test assertions.

| File | What it shows |
|---|---|
| `lane-brief-direct-PR.md` | A real `--lane --landing-branch proto/godot/frog-pile --mode direct-PR` brief. All four crewmate `fm/<task-id>` sites are gone; the setup preamble no longer claims a detached HEAD; the DOD names `--base proto/godot/frog-pile`. |
| `lane-brief-no-mistakes.md` | Same, `--mode no-mistakes`: base check invoked with `--publishes`, DOD states plainly that it can neither set nor read the PR base. |
| `lane-brief-local-only-named-branch.md` | Same, `--mode local-only` with an explicit `--lane-branch`: the branch is named at every site, and the base check is invoked **without** `--publishes`. |
| `lane-base-check-e2e-transcript.txt` | A lane worker in a real Playbot topology (bare remote → primary checkout → worktree cut from the *remote* tip) executing the brief's setup step 1b verbatim through all three exit-code arms, plus every blocked state and the remedy each prescribes — each remedy actually run, reaching a different verdict. |
| `lane-scaffold-refusals-transcript.txt` | Every scaffold-time refusal, including the `$(id)` / `` `id` `` injection path into the `git reset --hard` the brief tells the worker to run. Nothing is written for any refusal. |
| `lane-delivery-contract-and-fixtures.txt` | `bin/fm-spawn.sh`'s reader applied to each lane brief, and the live regeneration of all three non-lane briefs compared byte-for-byte with the committed golden fixtures. |

The acceptance test from the intent — "a dispatch message reduces to *read the brief at
`<path>` and follow it exactly* plus a one-line task summary" — is met by the brief files:
each carries its own branch instruction, base verification, delivery contract and
definition of done, so nothing has to be countermanded at dispatch.
