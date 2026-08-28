---
name: learning-candidate-lifecycle
description: >-
  Agent-only procedure for bounded capture and separate asynchronous curation of meaningful development incidents.
  Load after a qualifying learning signal and before curating the unresolved learning-candidate batch.
user-invocable: false
metadata:
  internal: true
---

# Learning candidate lifecycle

Use this procedure only after one of these signals occurs:

- The captain corrects work that was presented as finished.
- A review rejects the delivered behavior.
- A defect escapes tests that had passed.
- A blocker exposes a reusable workflow gap.
- No-mistakes makes a substantive correction rather than a routine formatting or mechanical cleanup.

A routine successful task, an ordinary chat exchange, a status update, and every other turn do not trigger this procedure.
Do not audit the whole task at completion to search for a candidate.

## Originating lane: bounded capture only

The lane where the signal occurred records one candidate with `bin/fm-learning-candidate.sh capture` before its terminal completion report when practical.
Use the command's help for the exact signal names, required fields, schema, validation, and idempotent retry behavior.
State concrete evidence, the escaped contract, and the counterfactual that explains how the proposed prevention would have caught the original failure.
The proposed owner is a hypothesis for later review, not a routing decision.

Do not classify, deduplicate, promote, document, create follow-up work, or edit a destination from the originating lane.
Do not delay task cleanup when capture is temporarily unavailable or classification is unfinished.
Report a capture failure as task evidence only when losing the incident would be material; otherwise leave the originating delivery path alone.

## Curator lane: separate asynchronous work

Curate from a separate worker or a clearly separate Firstmate curation pass whose curator identity differs from the originating task.
Start with `bin/fm-learning-candidate.sh list` for the concise inbox and use `batch` for a bounded group of complete records.
Compare root cause, escaped contract, affected consumer, and prevention before deduplicating; similar impact alone does not prove duplicate cause or prevention.

Classify each retained candidate to exactly one owner:

- Route feature-specific behavior to that feature's documentation, contract, or tests.
- Route reusable practice spanning task or feature types inside one project to project instructions, shared project tooling, or an eligible project-local skill.
- Route cross-project dispatch, evidence, validation, supervision, or delivery behavior to Firstmate's pipeline.
- Route behavior caused by a named tool to that tool's repository.

Examples of the boundary:

- A HUD that passed tests but violated its screenshot reference is project UI practice when the prevention generalizes across the project's UI work.
- A completed quest that remains visible is feature behavior and belongs in FrogPile quest documentation or tests.
- Physical pointer-coordinate validation may be a project input-implementation skill when it applies to multiple interaction task types and satisfies the skill gate.
- A worker decision lost because supervision was absent belongs to Firstmate pipeline behavior.
- A Playbot-specific defect belongs to the Playbot repository.

Classification is a routing recommendation only.
Never edit the destination, create divergent Codex and Claude copies, open or merge an improvement, or bypass the destination repository's normal delivery authority from this procedure.

## No-one-off-skill gate

Route to a skill only when every condition is supported by preserved evidence:

- The proposed learning can be stated without feature-specific nouns.
- It benefits at least two distinct task types or is demonstrably feature-agnostic.
- It defines a repeatable procedure.
- It names a precise load trigger.
- Its counterfactual shows that the procedure would have prevented or exposed the original failure.

The command requires evidence for each condition and rejects an incomplete skill classification.
The command cannot decide whether semantic evidence is true; that judgment belongs to the curator.
When the gate fails, choose the feature or non-skill project surface that actually owns the behavior.

## Disposition

After classification, record one disposition through the command:

- `documented` when the recommendation is already represented at the recorded reference.
- `promoted` when the recommendation has entered the destination's normal improvement path.
- `follow-up` when a proposed follow-up record owns the next action.
- `dismissed` when no reusable prevention should proceed; dismissal may occur without classification.

Deduplication marks only the duplicate and leaves the canonical candidate available for curation.
None of these states is a prerequisite for cleaning up the originating task.
