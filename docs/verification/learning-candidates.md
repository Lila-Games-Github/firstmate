# Learning-candidate pipeline verification

This page records active maintainer evidence for the durable learning-candidate lifecycle.
The executable contract remains in [`fm-learning-candidate.sh`](../../bin/fm-learning-candidate.sh), and the semantic procedure remains in the internal [`learning-candidate-lifecycle` skill](../../.agents/skills/learning-candidate-lifecycle/SKILL.md).

## Verified environment

Verification was run on 2026-08-28 with these exact commands:

```sh
bash --version | head -1
jq --version
uname -s
```

The relevant output was:

```text
GNU bash, version 5.3.15(1)-release (x86_64-pc-linux-gnu)
jq-1.8.1
Linux
```

## Behavioral evidence

The review-fixed pipeline under test was commit `974dcb2741aeb24a7deb50f9765ab7daed71c7de`.

The focused public-interface and startup integration run used:

```sh
bin/fm-test-run.sh tests/fm-learning-candidate.test.sh tests/fm-brief.test.sh tests/fm-session-start.test.sh
```

The result was:

```text
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=157561
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=17351 failed=0
FM_TEST_SUMMARY_FAMILY family=session-bootstrap count=1 duration_ms=140119 failed=0
```

That run covers required-field and stored-record validation, deterministic repeat capture, every routing class, incompatible route rejection, separate curator identity, complete no-one-off-skill evidence, every requested disposition, and explicit deduplication with interruption recovery, authoritative duplicate state, exact retry repair, and conflicting-retry refusal.
It also covers store-independent summary reads, bounded list and summary output, interrupted and concurrent summary-transaction recovery, bounded session-start visibility, and generated ship and scout capture commands that bind the originating home and tracked executable.
The conditional reminder remains limited to ship and scout briefs, routine success still requires no audit or state creation, and the originating lane is not assigned asynchronous curation.
The ordinary non-forced task-cleanup survival case reported `skip` because `tasks-axi` was unavailable in this environment; the other focused assertions and all three scripts passed.

The relevant broader contract family and portable-lane coverage check used:

```sh
bin/fm-test-run.sh --check-coverage
bin/fm-test-run.sh --family pure-contract-unit
```

The results were:

```text
FM_TEST_COVERAGE ok total=153 parallel=24 serial=117 serial_shards=4 herdr=12
FM_TEST_SUMMARY total=33 failed=0 skipped_gate=2 duration_ms=321108
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=33 duration_ms=320006 failed=0
```

The two gate skips were pre-existing optional local Pi tool checks, while every executed contract test passed.

Documentation, shell, workflow, and patch hygiene used:

```sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
git diff --check
```

The commands returned zero, with `git diff --check` silent, and reported:

```text
fm-doc-audience-check: ok surfaces=73 local_links=264
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

## Harness and backend applicability review

The supported harness launch templates and their common brief substitution were reviewed with:

```sh
sed -n '1138,1212p' bin/fm-spawn.sh
sed -n '2740,2810p' bin/fm-spawn.sh
```

Claude, Codex, OpenCode, Pi, `pi-signed`, Grok, Cursor, and Muse all receive the same generated ship or scout brief content through their existing launch path.
Kimi receives the same brief by its existing absolute brief pointer after readiness.
The reminder is therefore harness-independent, and no harness adapter, prompt transport, hook, trust behavior, or live harness check changes.
Secondmate charter generation is not an originating implementation-worker surface; a running secondmate receives the same always-loaded `AGENTS.md` skill trigger after normal Firstmate update propagation.

The runtime adapter surfaces were reviewed with:

```sh
rg -n "learning-candidate|fm-learning-candidate" bin/fm-harness.sh bin/fm-backend.sh bin/backends || true
```

The command produced no matches.
The lifecycle reads and atomically writes only the selected home's private state, so tmux, Herdr, Zellij, Orca, and cmux endpoint creation, transport, liveness, and cleanup mechanics are not applicable.
The cleanup regression targets the shared task-cleanup entrypoint, but its teardown assertions remain pending CI coverage because `tasks-axi` was unavailable in the recorded run; backend-specific teardown branches do not own the home-level candidate directory.

No live harness or real backend smoke was required because no verdict depends on vendor output, process shape, rendered UI, endpoint transport, or backend lifecycle behavior.
