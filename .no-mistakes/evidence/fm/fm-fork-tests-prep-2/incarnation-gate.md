# Fork-only teardown fixtures now name an incarnation

base 592d4bc0d4db5201a828da315f75c904599a67f4 -> change 0be7799f9d7da241707829307a05178f95bfba75
branch fm/fm-fork-tests-prep-2

## 1. What the six records look like to the code that reads them

`bin/fm-pr-lib.sh::fm_task_spawn_gen_capture` is the in-tree reader for a task
record's incarnation, and it already implements exactly the predicate the
upstream teardown gate is described as applying: zero `spawn_gen=` lines ->
`legacy` (no incarnation named), exactly one -> `value:<incarnation>`, more
than one -> non-zero exit.

The five fm-playbot-lanes records below were copied off disk WHILE the suite
ran, straight out of the live fixture state directory, so they are the bytes
the product's teardown and lane-publication code actually opened. The base
column is the same record with the one added line removed - the diff is six
pure insertions and zero deletions, so that reconstruction is exact.

fm-autoarm-retired-remote
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-fm-autoarm-retired-remote  post-sync teardown: ACCEPT (incarnation unambiguous)
fm-autoarm-retired-remote-pr
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-fm-autoarm-retired-remote-pr post-sync teardown: ACCEPT (incarnation unambiguous)
fm-autoarm-retired-remote-receipt
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-fm-autoarm-retired-remote-receipt post-sync teardown: ACCEPT (incarnation unambiguous)
fm-autoarm-retired-local-pr
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-fm-autoarm-retired-local-pr post-sync teardown: ACCEPT (incarnation unambiguous)
fm-autoarm-partial-remote
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-fm-autoarm-partial-remote  post-sync teardown: ACCEPT (incarnation unambiguous)
cleanup-source
  base   592d4bc  capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)
  change 0be7799  capture=value:fixture-cleanup-source             post-sync teardown: ACCEPT (incarnation unambiguous)

Reproduce: ./incarnation-gate.sh <repo> ./fixture-records <base-shape-records>
Records:   ./fixture-records/*.meta

## 2. The behaviour each record exists to prove still holds on this branch

The constraint is that the result passes on the CURRENT default branch, where
the gate requiring the field does not exist yet. Both changed suites were run
in full on the change commit. These are the cases whose records gained a line:

ok - fm-playbot-lanes: remote teardown retires identity before a blocked task publisher can publish
ok - fm-playbot-lanes: remote teardown blocks prepared PR poll republication
ok - fm-playbot-lanes: blocked publishers reject replacement task incarnations
ok - fm-playbot-lanes: remote teardown blocks retirement receipt republication
ok - fm-playbot-lanes: failed retirement receipt validation rolls publication back
ok - fm-playbot-lanes: local teardown blocks prepared PR poll republication
ok - fm-playbot-lanes: route-absent remote metadata cannot republish after partial teardown
ok - task cleanup survival skipped because tasks-axi is unavailable

Whole-suite result (exit status 0 for both):

  tests/fm-playbot-lanes.test.sh       178 ok lines, exit 0
  tests/fm-learning-candidate.test.sh  29 ok lines, exit 0

Full transcripts: ./fm-playbot-lanes.run.log, ./fm-learning-candidate.run.log

## 3. Scope: fixture lines only, no assertion touched

  1	0	tests/fm-learning-candidate.test.sh
  5	0	tests/fm-playbot-lanes.test.sh

  added lines, all of them:
    +    "spawn_gen=fixture-$id" \
    +spawn_gen=fixture-$retired_task_id
    +spawn_gen=fixture-$retired_pr_task_id
    +spawn_gen=fixture-$retired_receipt_task_id
    +spawn_gen=fixture-$local_race_task_id
    +spawn_gen=fixture-$partial_task_id

## 4. One gap, stated plainly

`tests/fm-learning-candidate.test.sh`'s cleanup-source case guards on
`command -v tasks-axi` and that tool is not installed on this machine, so the
case reports "skipped" rather than running. Its record in section 1 was
therefore built by calling the suite's own `tests/lib.sh::fm_write_meta` with
the exact field list the fixture passes, instead of being captured from a live
run. The incarnation reading is real; the surrounding teardown behaviour for
that one case was not exercised locally and is left to CI.
