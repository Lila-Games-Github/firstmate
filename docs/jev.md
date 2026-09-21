# Jev decision observers

Firstmate can ask TypeSafe AI's Jev model for bounded typed decisions at four existing workflow boundaries.
Every use is active by default, and the established deterministic or human path remains the fallback.
Jev cannot produce free text, prove correctness, recover missing product intent, or replace lifecycle and merge authority.

## Enable and disable

Put `TYPESAFE_API_KEY=` in the effective home's gitignored `.env` to enable the built-in active configuration.
That key is the only opt-in, and it is the same key `bin/fm-dispatch-resolve.sh` already uses for typed dispatch resolution.
A home that already has it therefore turns all four observers active on its next `bin/fm-wake-drain.sh`, with no further configuration step, and begins transmitting the material listed under [Uses](#uses) to TypeSafe AI:

| Use | What each consultation transmits |
| --- | --- |
| Acceptance check | The acceptance criteria extracted from `data/<id>/brief.md` and the text of the worker's `data/<id>/report.md`. |
| Supervision triage | Each presented status line, wake row, or captured Lavish review element, truncated to 1500 characters per item. |
| Commit lint | Each branch-only commit's subject, body, and diff, or its `git show --stat` plus leading hunks when the diff exceeds the per-call budget. |
| Open questions | Each question line and the text of every page those lines reference, each page once per request rather than once per question, shortened when it exceeds the per-call budget. |

Shadow and `off` remain the manual opt-outs; neither is selected for you.
Create the gitignored `config/jev.json` described in [configuration.md](configuration.md#jev-decision-observers-configjevjson) to change budgets or select another mode per use.
Shadow mode sends the request and records the answer, but the existing path still decides.
Active mode uses a confidence-qualified answer only for the adapter effects listed below, with the existing path as the deterministic fallback.
Active triage still presents every input; its classification is evidence and never a suppression rule because a mistaken routine verdict must not silently lose a wake.

Set `kill_switch` to `true`, set an individual use to `off`, or remove `TYPESAFE_API_KEY` to return affected paths to their behavior without Jev.
The adapters you run by name - `bin/fm-jev-accept-check.sh`, `bin/fm-jev-commit-lint.sh`, and `bin/fm-jev-open-questions.sh` - then print one `<use>: off (<reason>)` line on stderr and exit zero, naming the absent key, the off mode, the kill switch, or the unreadable configuration.
The triage hooks inside `bin/fm-wake-drain.sh` and `bin/fm-procevent-lavish.sh read` stay silent, because they run on the presentation path where a per-drain diagnostic would be noise.
`bin/fm-jev-report.sh` opens with the effective mode of each use and whether a key is present.
A malformed config, missing key, exhausted cap, timeout, HTTP error, or malformed response also falls back without blocking the caller.
So does a ledger whose current day cannot be parsed: the day's spend is then unknown, so consultations are refused with `ledger-unreadable` until `bin/fm-jev.sh validate-ledger` is run and the named file repaired.
The system never changes a use's configured mode or disables Jev because of a disagreement; disagreements remain visible for evaluation.

## Uses

| Use | Command or hook | Shadow behavior | Active behavior |
| --- | --- | --- | --- |
| Acceptance check | `bin/fm-jev-accept-check.sh <task-id>` | Writes `data/<id>/acceptance.json` from one Noul per extracted acceptance criterion. | Also records `unmet_criteria` and an `advisory` string in that same file, but never accepts, rejects, blocks, or closes the task. |
| Supervision triage | `bin/fm-wake-drain.sh` and `bin/fm-procevent-lavish.sh read` | Records routine or actionable for each presented item and ruling, question, or instruction for captured review answers, batching one drain or one read into a single request. | Marks each confidence-qualified classification in the batch as the Jev decision for that item in the ledger, while presentation remains unchanged so no input can be silently lost. |
| Commit lint | `bin/fm-jev-commit-lint.sh <worktree>` | Reviews each branch commit in its own request for message and diff agreement, persistence changes, weakened tests, debug output, and credentials, and writes `data/<id>/commit-lint.json`. | Also records an `advisory` string in that same file, but never blocks or authorizes landing. |
| Open questions | `bin/fm-jev-open-questions.sh <questions-file> <pages-dir>` | Writes `<stem>-jev-review.md` with still open, settled, or cannot tell against each question's named page, carrying each referenced page once as shared context; a question Jev did not answer is listed as unclassified with the reason rather than given a classification. | Writes the same proposal and never edits the question register or referenced pages. |

Each adapter builds its requests from material that code has already narrowed.
The question wording is reviewable under `bin/jev-questions/`.
No adapter writes a task's status file: a `note:` line there is a status event that would supersede a worker's terminal `done:` line and change how supervision classifies an idle, finished pane, so every advisory lives in the use's own evidence file and in the report instead.
A whole drain or a whole Lavish read is batched into one triage request, and each commit is one commit-lint request; a commit whose diff exceeds the per-call budget is sent as `git show --stat` plus as many leading hunk bytes as fit, with `truncated=true` on its ledger row, rather than cancelling the branch's lint.
`bin/fm-jev.sh` enforces the per-call budget for every adapter, so no adapter can make an oversized request disappear. An over-budget envelope is split into one request per question, each carrying only the shared context its own question names. Splitting is taken only when it buys something: whatever a part carries that its own question does not own counts as shared, and what the split duplicates is the sum of those per-part shares less the distinct material the parts cover between them. A split is refused unless that duplication is smaller than the per-question material it accompanies and still fits one per-call budget - an oversized worker report shared by five acceptance criteria, or one 20 KB page cited by ten questions, would otherwise cost five or ten near-identical requests, when one shortened request carries every question and essentially the same text - and it is refused again when the whole split would not fit the day's remaining calls and spend for that use. Ten questions citing ten different pages duplicate nothing and still split. Every refusal sends one request instead. If one request of a split fails anyway, an aggregate verdict such as the acceptance check refuses the whole consultation rather than answer from the criteria that happened to succeed, while a per-question sweep keeps the answers it has and names the rest unclassified. A request that still does not fit has its longest state string shortened and records `truncated=true`, and a question that cannot fit even alone is refused with `per-call-token-cap` written to the ledger. Every budget refusal is recorded the same way, so `bin/fm-jev-report.sh` names under `refusals:` why a use did nothing today.
The client requests `jev-1.13.0`, accepts any returned model id in the `jev-` family, records the returned id as `response_model` on every row, sends text-only state, and allows no SDK or free-form output path.
A well-formed answer from a model outside that family is recorded with the distinct `response-model-mismatch` reason and the returned id, so an endpoint or routing change is diagnosable from the ledger rather than looking like a schema failure.
Both shadow and active modes transmit that narrowed text to TypeSafe AI, including report excerpts, supervision items, commit messages and diffs, or referenced page text.
Do not enable a use for material that policy forbids sending to that service; in particular, the credential lint can identify a credential only after the diff has been transmitted.

## Evaluate the result

Every network attempt, and every budget refusal, is appended to `state/jev-ledger.jsonl` without the API key or full request content.
The ledger rotates monthly into `state/jev-ledger/YYYY-MM.jsonl`; the report and `finalize` read the running file and every archive, so nothing is lost and a consultation never pays for retained history.
Run `bin/fm-jev-report.sh` to print per-use and overall agreement with final decisions, consultations still waiting for one, false positives, false negatives, spend, estimated tokens avoided, and active-row counts.
It then names every budget refusal under `refusals:`, which is where a day lost to an exhausted cap, a zero budget share, or an oversized request becomes visible.
The report then lists every Jev-versus-baseline disagreement with the two decisions, both rationales, Jev's typed probabilities, and the recorded outcome with the path that observed it, and closes with the advisories the active adapters recorded.
A batched per-item consultation is listed as the items that actually diverged, each with its Jev choice, its probabilities, and the baseline choice, rather than as the whole batch object, because finding routine items is what triage is for and one of them must not read as a total disagreement.
Pass an alternate JSONL file as the first argument when evaluating a saved fixture or export.

Jev returns typed answers and probabilities, not prose reasoning.
`jev_rationale` is therefore a deterministic explanation rendered by the client from the returned typed probabilities, the configured aggregation rule, and the confidence floor; `jev_answers` retains the raw typed answer object.
`baseline_rationale` is the fixed reviewable explanation supplied by the adapter for the established path.

Agreement is quality evidence only after the owning path has recorded a final decision.
Acceptance rows begin without that label, and teardown records the outcome it actually reached: `accepted` for an ordinary teardown that passed the landed-work check or a scout that passed the captain-call completion gate, and `discarded` for a `--force` teardown, which is the captain's explicit OK to discard unlanded or dirty work.
A teardown that refuses records nothing, so the row keeps waiting for a real label rather than collecting a false one.
Every recorded label names the teardown path that observed it in `label_source`, and the report shows it beside each disagreement.
`accepted` is the positive class and `discarded` is a negative one, so a Jev rejection of work that was then discarded counts as agreement rather than as a false negative, and an acceptance of discarded work is the false positive it is.
Consultations with no label yet are counted in the report's `unlabelled` column instead of being folded into either class.
The report's token count is an estimate based on the bounded material each adapter supplied.
Acceptance estimates the report and criterion text, triage estimates the presented items, commit lint estimates the commit-and-diff JSON, and open-question review estimates the questions and named page text; each uses the conventional four-characters-per-token approximation because these paths do not otherwise record big-model token use.
The client applies that same four-bytes-per-token rule to its own preflight, so an adapter sizing bounded material against `bin/fm-jev.sh request-budget <use>` and the cap the client enforces are one arithmetic.
A batched consultation is credited the share of its estimate whose own items cleared the floor, because each item of a batch is judged on the confidence Jev returned for that item rather than on the batch minimum.
For shadow rows the value is only a counterfactual estimate of what active mode could avoid.
Active rows make operational comparison possible, but the value remains an estimate rather than a billing measurement, and advisory-only effects may not eliminate every baseline token.
Compare both agreement and error direction before promoting a use because a low average error rate can still hide a damaging false negative.

## Revert

The fastest global rollback is `"kill_switch": true` in `config/jev.json`.
Deleting the key from `.env` is equivalent for the four observers.
To keep the key for typed dispatch while disabling only these observers, set every use in `config/jev.json` to `off`.
No ledger archive under `state/jev-ledger/` needs deleting either; rotation only moves evidence, it never discards it.
Removing `config/jev.json` restores the built-in active configuration, so it is not a rollback.
No ledger or generated review artifact must be deleted for rollback, and retaining them preserves the evaluation evidence.
