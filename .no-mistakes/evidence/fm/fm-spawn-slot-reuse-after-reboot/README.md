# Evidence: treehouse slot reuse after a host reboot

`reboot-slot-reuse-demo.sh` rebuilds the 2026-09-21 incident and drives it through the
real Firstmate scripts of whichever tree it is pointed at (every external tool - tmux,
treehouse, gh, tasks-axi - is a stub on PATH, so nothing outside its scratch directory
is touched). It was run twice, unchanged:

| transcript | tree |
| --- | --- |
| `cli-transcript-before-fix.txt` | base `5570612` |
| `cli-transcript-after-fix.txt`  | change `23ffc72` |

The world both runs build: a Treehouse pool with one slot, task `frogpile-ui-pipeline`
live and recording that slot as its worktree, and a host that has just rebooted - so the
lease process is gone and `treehouse status --json` reports the slot `available` while
the record naming it is untouched.

## ACT 1 - `bin/fm-spawn.sh frogpile-jev-usecases-research` is handed that slot

before
```
spawned frogpile-jev-usecases-research ... worktree=/tmp/fm-demo-base/pool/1/repo
exit=0
$ cat pool/1/.fm-slot-owner
task=frogpile-jev-usecases-research      <- the live task's claim, overwritten
$ ls state/
frogpile-jev-usecases-research.meta
frogpile-ui-pipeline.meta                <- two records, one slot
```

after
```
error: Treehouse handed task frogpile-jev-usecases-research pool slot /tmp/fm-demo-target/pool/1/repo,
but task frogpile-ui-pipeline still records it as its worktree (...frogpile-ui-pipeline.meta);
preparing it would replace that task's copy, so nothing was launched.
exit=1
$ cat pool/1/.fm-slot-owner
task=frogpile-ui-pipeline                <- claim intact
$ git -C <slot> status -sb
## fm/frogpile-ui-pipeline               <- branch checkout intact, HEAD unchanged
$ ls state/
frogpile-ui-pipeline.meta                <- no record published
```

## ACT 2 - `bin/fm-bootstrap.sh` (session start) on that home

before: silent.

after:
```
SLOT_RECONCILE: task frogpile-ui-pipeline's local copy /tmp/.../pool/1/repo reads free to
Treehouse while its record still claims it - a restart drops the hold on a copy but not the
record, so the next dispatch can be handed the same copy; confirm the task with
bin/fm-crew-state.sh frogpile-ui-pipeline and clear whichever record is wrong ...
```
Silent again when treehouse reports the slot `in-use`, and the other drift direction (a
durable lease stranded under another holder) prints its own line with a
`treehouse return --if-lease-holder ...` remedy carrying the spelling treehouse itself
recorded.

## ACT 3 - the two stuck records

Both trees refuse the ordinary teardown from either side and refuse `--force`. Only the
change offers a way out:

before
```
$ bin/fm-teardown.sh frogpile-ui-pipeline --reconcile-slot
error: invalid teardown request
exit=2
... both records still present, slot still deadlocked
```

after
```
$ bin/fm-teardown.sh frogpile-ui-pipeline --reconcile-slot
teardown: reconciling task frogpile-ui-pipeline's record against pool slot .../pool/1/repo,
which task frogpile-jev-usecases-research now holds (branch fm/frogpile-ui-pipeline is landed);
the slot, its processes, its copy, and its claim are left untouched.
exit=0
$ cat pool/1/.fm-slot-owner        -> still task=frogpile-jev-usecases-research
$ ls <slot>                        -> unchanged
$ git branch --list 'fm/*'         -> fm/frogpile-ui-pipeline still there (nothing discarded)
$ cat runtime.log                  -> no treehouse call: the slot was never returned here

$ bin/fm-teardown.sh frogpile-jev-usecases-research      # the survivor, ordinary command
teardown frogpile-jev-usecases-research complete (... worktree .../pool/1/repo)
$ cat runtime.log
treehouse <return> <--force> </tmp/fm-demo-target/pool/1/repo>   <- slot back in the pool
```

## ACT 4 - `bin/fm-control.sh <id> relaunch` into a copy another record owns

This is the head commit's fix: the refusal has to land before relaunch stops the agent.

before
```
$ bin/fm-control.sh rl-pipeline relaunch --note 'carry this forward'
relaunched rl-pipeline ... worktree=/tmp/fm-demo-base/control/pool/1/repo
exit=0
$ cat fake/literal
/exit                              <- the running agent was stopped
... claude --dangerously-skip-permissions ...   <- and a second agent started in
                                                  the copy rl-scout's record owns
$ tail -3 data/rl-pipeline/brief.md
carry this forward                 <- the brief was annotated
```

after
```
$ bin/fm-control.sh rl-pipeline relaunch --note 'carry this forward'
error: task rl-pipeline records pool slot .../control/pool/1/repo, but task rl-scout records it
as its worktree (...rl-scout.meta) too; relaunching would start a second agent in a copy another
live record owns, so nothing was launched and nothing was changed.
exit=1
$ cat fake/literal                 -> empty: nothing was typed into the pane
$ tmux display-message -p '#{pane_current_command}'
claude                             -> the worker is still running
$ tail -3 data/rl-pipeline/brief.md
Replace the agent process, never the task.   -> the note was not appended
$ ls state/                        -> both records intact, no relaunch journal

# and once the other record is reconciled, the same command goes through:
$ rm state/rl-scout.meta
$ bin/fm-control.sh rl-pipeline relaunch --note 'carry this forward'
relaunched rl-pipeline harness=claude ... exit=0
```

## Reproducing

```
TASKS_AXI_BIN=<dir with tasks-axi> ./reboot-slot-reuse-demo.sh <firstmate-tree> <scratch-dir>
```
`TASKS_AXI_BIN` is only needed for ACT 3 step 5 (the scout's captain-call inventory).
