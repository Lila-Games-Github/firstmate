# Learning-candidate pipeline verification

This page records active maintainer evidence for the durable learning-candidate lifecycle.
The executable contract remains in [`fm-learning-candidate.sh`](../../bin/fm-learning-candidate.sh), and the semantic procedure remains in the internal [`learning-candidate-lifecycle` skill](../../.agents/skills/learning-candidate-lifecycle/SKILL.md).

## Verified environment

Verification was run on 2026-08-29 with these exact commands:

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

The focused public-interface and startup integration run used:

```sh
bin/fm-test-run.sh tests/fm-learning-candidate.test.sh tests/fm-brief.test.sh tests/fm-session-start.test.sh
```

The result was:

```text
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=142299
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=2 duration_ms=9343 failed=0
FM_TEST_SUMMARY_FAMILY family=session-bootstrap count=1 duration_ms=132847 failed=0
```

Those runs cover required-field and stored-record validation, deterministic repeat capture, every routing class, incompatible route rejection, separate curator identity, substantive no-one-off-skill evidence, idempotent retries, every requested disposition, explicit deduplication, bounded list and summary output, session-start visibility, and survival through ordinary non-forced task cleanup.
The brief regression executes the absolute shell-quoted capture command from a foreign working directory with conflicting ambient home, state, and code-root values, and confirms ship and scout records land only in the intended private home.
The same runs confirm routine success still requires no audit or state creation, the originating lane never waits for curator-held state, and the originating lane is not assigned asynchronous curation.

The canonical path-boundary regression was refreshed on 2026-08-30 with:

```sh
bash tests/fm-learning-candidate.test.sh && bash tests/fm-session-start.test.sh
```

The relevant unchanged path-boundary output was:

```text
ok - state aliases normalize before public lifecycle path validation
ok - canonical path boundary rejects unsafe state, store, record, capture, and mutation forms
ok - public read commands reject a dangling candidate store
ok - session start reports a dangling candidate store as unavailable
```

The exercised forms are a real state path with a trailing slash, a real state path with trailing slash-dot, both aliases on a symlinked state path, a dangling lifecycle sibling, a candidate symlink to a directory, a candidate symlink to a regular file outside the store, a candidate-store symlink to a directory, a dangling candidate-store symlink, a directory in a record slot, and a regular file in the store slot.
Capture, get, list, batch, summary, session startup, and lifecycle disposition exercise those forms through their public interfaces, including the deterministic capture sibling and lifecycle destination paths.
All named path forms are applicable and exercised; none are marked non-applicable.
The 2026-09-02 focused run below refreshes the changed summary and session-start behavior for unsafe exact entries.

The relevant broader contract family and portable-lane coverage check used:

```sh
bin/fm-test-run.sh --check-coverage
bin/fm-test-run.sh --family pure-contract-unit
```

The results were:

```text
FM_TEST_COVERAGE ok total=153 parallel=24 serial=117 serial_shards=4 herdr=12
FM_TEST_SUMMARY total=33 failed=0 skipped_gate=2 duration_ms=314170
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=33 duration_ms=313116 failed=0
```

The two gate skips were pre-existing optional local Pi tool checks, while every executed contract test passed.

## Malformed-name resilience refresh

The enumeration and session-start regressions were refreshed on 2026-09-02 with GNU Bash 5.3.15, jq 1.8.1, and Linux.
The focused run used:

```sh
bin/fm-test-run.sh tests/fm-learning-candidate.test.sh tests/fm-session-start.test.sh
```

The result was:

```text
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=149485
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=15377 failed=0
FM_TEST_SUMMARY_FAMILY family=session-bootstrap count=1 duration_ms=134024 failed=0
```

The public-interface fixtures cover lifecycle-less and invalid lifecycle hints, content-preserving name correction, strict candidate-id lookup, read-only directory-listing stability, all enumeration surfaces, schema-invalid record isolation, regular-file enforcement, and session-start reporting.
[jq advisory GHSA-cfh2-vwfq-qfmm](https://github.com/jqlang/jq/security/advisories/GHSA-cfh2-vwfq-qfmm) affects jq through 1.8.1 when `--rawfile` reads 2,147,483,649 bytes: 2,147,483,648 bytes reaches `String too long` and ends cleanly, while one additional byte causes the next 4,096-byte read-loop iteration to append to invalid state, aborting assertion builds or causing a heap-buffer overflow in assertion-disabled builds.
The candidate reader accepts at most 1,048,576 bytes and supplies at most 1,048,577 bytes to `--rawfile` while classifying an oversize entry, so this store cannot reach the advisory trigger; this containment does not claim that the jq advisory itself is resolved.
The lint run used:

```sh
bash bin/fm-lint.sh
git diff --check
```

The result was:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

Documentation, shell, workflow, and patch hygiene used:

```sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
git diff --check
```

The commands returned zero, with `git diff --check` silent, and reported:

```text
fm-doc-audience-check: ok surfaces=74 local_links=266
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

On stock macOS Bash 3.2, the PID exposed by the process substitution previously used for NUL-delimited enumeration is not a waitable child, so `wait` reports `pid ... is not a child of this shell`.
The fix writes the byte-safe NUL-delimited enumeration to an ephemeral private spool and opens it only after successful production, keeping enumeration status explicit.

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
The cleanup regression exercises the shared task-cleanup entrypoint and proves its task-scoped removal leaves the home-level candidate directory intact; backend-specific teardown branches do not own that directory.

No live harness or real backend smoke was required because no verdict depends on vendor output, process shape, rendered UI, endpoint transport, or backend lifecycle behavior.
