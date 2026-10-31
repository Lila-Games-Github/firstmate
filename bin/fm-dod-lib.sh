#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [landing-branch] prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.
# fm_long_suite_block owns the worker-side contract for a task whose definition
# of done requires a long-running suite: the durable reattachable job shape that
# survives one execution-session limit, and the evidence snapshot policy that
# keeps every cited capture and the final suite receipt describing one commit.
# bin/fm-brief.sh and bin/fm-promote.sh render it into every ship brief and
# promotion payload; the function below owns why it is not gated on a flag.

# fm_nm_target_block <landing-branch> owns the no-mistakes target handoff.
# An empty branch emits nothing, preserving the pipeline's default behavior.
# Brief, launch (including relaunch), and promotion callers supply the recorded
# landing_branch, or the lane's explicit landing branch. The launch overlay
# supersedes old/custom brief guidance and precedes the authorized intent body.
# Only the command is shell-quoted; prose and equality checks use the raw name.
fm_nm_target_block() {
  local branch=${1:-} target_arg
  [ -n "$branch" ] || return 0
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || {
    echo "error: no-mistakes landing branch is not a valid branch name: $branch" >&2
    return 1
  }
  printf -v target_arg '%q' "$branch"
  cat <<EOF

# Current no-mistakes target contract
This section supersedes earlier brief guidance about the no-mistakes target.
The recorded landing branch is \`$branch\`.
When starting validation, run \`no-mistakes axi run --target-branch $target_arg\` with the authorized intent supplied separately through \`--intent\`.
The target is a separate flag; never put it inside \`--intent\`.
Reattach an existing run using its immutable target rather than starting a replacement run with a default target.
Before reporting a PR, verify the run's \`target_branch\` through \`no-mistakes axi status\` and the forge PR base both equal \`$branch\`.
Use \`gh-axi\` with an explicit repository scope to read the forge PR base (\`base.ref\`); never infer it from the head branch or the PR title.
If either target differs or cannot be verified, stop and report \`blocked: no-mistakes target verification failed\` with the evidence; do not report that PR as ready.
EOF
}

# fm_direct_pr_target_block <landing-branch> owns the direct-PR base handoff.
# Brief, launch (including relaunch), and promotion callers supply the recorded
# landing_branch. Empty emits nothing; commands quote the branch separately
# from the raw forge equality check, matching fm_nm_target_block above.
fm_direct_pr_target_block() {
  local branch=${1:-} base_arg
  [ -n "$branch" ] || return 0
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || {
    echo "error: direct-PR landing branch is not a valid branch name: $branch" >&2
    return 1
  }
  printf -v base_arg '%q' "$branch"
  cat <<EOF

# Current direct-PR base contract
This section supersedes earlier brief guidance about the direct-PR base.
The recorded landing branch is \`$branch\`.
When opening the PR, run \`gh-axi pr create --base $base_arg\` with an explicit repository scope and the other PR arguments.
Before appending \`done: PR {url}\`, use \`gh-axi\` with an explicit repository scope to verify the forge PR base (\`base.ref\`) equals \`$branch\`.
Never infer the base from the head branch or PR title.
If the base differs or cannot be verified, stop and report \`blocked: direct-PR base verification failed\` with the evidence; do not report that PR as ready.
EOF
}

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into your recorded landing branch (the default branch when none is recorded)."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# The worker-side half of the durable-long-suite contract. AGENTS.md section 7
# owns the supervision half: firstmate leaves such a job running and lets the
# worker reattach instead of relaunching, interrupting, or tearing it down.
# Rendered into every ship brief and every promotion payload rather than gated on
# --green-final-head: that marker carries the dispatch-time base-health receipt
# requirement, and a promoted scout's payload is built without any such marker,
# so gating would lose this contract exactly where a promoted worker still owes a
# long final suite.
# A missed trigger would lose the whole protection, so every ship gets it.
fm_long_suite_block() {
  cat <<'EOF'
# Long-suite and evidence snapshot contract
When the definition of done requires a long-running suite, run it as a durable job that outlives one execution session: keep its progress and its identifier outside the process that started it (a log path plus a recorded job or session identifier), and reattach through that identifier instead of re-running the suite.
A required suite that is still running, or queued behind a shared suite lock, is work under way rather than a stalled task: report it as the declared external wait rule 4 defines, naming its identifier and what it is waiting on, and never abandon, duplicate, or restart it because one command call was killed, timed out, or hit an execution-session limit.
For a test-service request, append `paused: test-service request=<request-id>` and end your turn after submission; resume on its durable completion message, without polling status or holding a waiter session.
Evidence must describe one snapshot: every capture and artifact you cite and the final suite receipt must all name the same commit.
In a landing train, defer the exact-head suite, gate checks, and captures until your car is bottom on the live tip; ordinary target movement while above bottom uses no re-capture budget.
Once final captures begin (at bottom for a landing train), either the landing tip is held still through the final suite, or a tip that moved invalidates that evidence, and the re-capture budget is one re-capture and re-run - a second move during final validation is the same obstacle twice, so report it as a blocker rather than repeating.
EOF
}

# Quote generated worker commands independently of the caller's shell helpers.
fm_dod_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Shared worker handoff, also rendered on scout promotion. The queue executable
# owns mechanics; this block supplies the task-bound invocation and next steps.
fm_landing_queue_block() { # <task-id> [landing-branch]
  local id=$1 landing=${2:-} root home state data queue_command queue_target=''
  root=${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
  home=${FM_HOME:-$root}
  state=${STATE:-${FM_STATE_OVERRIDE:-$home/state}}
  data=${DATA:-${FM_DATA_OVERRIDE:-$home/data}}
  queue_command="FM_HOME=$(fm_dod_quote "$home") FM_STATE_OVERRIDE=$(fm_dod_quote "$state") FM_DATA_OVERRIDE=$(fm_dod_quote "$data") $(fm_dod_quote "$root/bin/fm-landing-queue.sh")"
  [ -z "$landing" ] || queue_target=" --landing-branch $(fm_dod_quote "$landing")"
  cat <<EOF

## Self-service landing train
Use the queue tool for your place, rebase target, and final receipt; do not wait for a firstmate message assigning or updating them.
The tool's header and \`--help\` own the protocol.
You may update this task's shared queue and receipt state through this tool, including when its home is outside your worktree.
Define this helper in your worker shell:
\`\`\`sh
landing_queue() {
  local action=\$1
  shift
  $queue_command "\$action" $(fm_dod_quote "$id") --project .$queue_target "\$@"
}
\`\`\`
1. Once implementation is committed, join with \`landing_queue ready --branch "\$(git branch --show-current)" --head "\$(git rev-parse HEAD)"\`.
2. Run \`landing_queue status\` before rebasing, before the exact-head full suite, after the suite, and whenever you resume waiting.
   Read its \`place\`, \`target_ref\`, \`target_sha\`, and \`rebase_from\`; these replace any earlier target, even if another car failed or landed.
   At \`waiting-for-front\`, do not rebase, run the final suite or gates, or capture final evidence, even when the target changes: append \`paused: landing-queue waiting-for-front\` and end your turn without polling.
   The queue sends your steering inbox one message when your car reaches bottom; resume then with \`landing_queue status\`.
   At bottom (\`place=1\`), when the base changes, rebase your own commits with \`git rebase --onto <target_sha> <rebase_from>\`, then acknowledge the prepared head with \`landing_queue ready --branch "\$(git branch --show-current)" --head "\$(git rev-parse HEAD)" --target <target_sha>\`.
   Resolve rebase conflicts yourself; do not merge or keep commits from a failed lower car.
3. At \`needs-final\` (bottom on the live tip), run the task's full suite on exactly that committed head and create its receipt using the format owned by \`$root/bin/fm-landing-health-lib.sh\`.
   Submit with \`landing_queue receipt --head <tested-full-sha> --target <tested-target-sha> --receipt <file>\`.
   For each required landing gate shown by this project's test-service configuration, complete that check on the same head and target, write the four-line \`fm-landing-gate.v1\` receipt from the queue tool's \`--help\`, and submit \`landing_queue gate --gate <name> --head <tested-full-sha> --target <tested-target-sha> --receipt <file>\`.
   At \`needs-gate\`, read the missing gate in \`reason\` and submit its pass after the check succeeds; status becomes ready only when all declared gates pass.
   A changed head or target refuses the receipt: read status and finalize again only when bottom on the live tip, under the re-capture budget above.
   If your car fails, record \`landing_queue fail --reason <failure>\` before reporting \`failed:\` and stopping.
   At \`red-receipt\`, do not rerun the suite on the same head: fix the failures its \`reason\` names in a new commit and finalize again, or record the failure as above.
   At \`failed\`, report \`failed:\` with the status \`reason\` and stop.
4. At \`ready-to-land\` or \`needs-baseline\`, append \`paused: landing-queue <status>\` and end your turn without polling; a pending test-service request instead follows the submit-and-end-turn rule above.
   The queue sends your steering inbox one message when your car lands, fails, its baseline resolves, or a moved head or target returns work to you; resume then with \`landing_queue status\`.
   The tool emits the readiness or baseline wake only for the bottom car with a valid receipt; do not add a ready \`done:\` or ask firstmate to coordinate the queue.
   Firstmate handles those wakes under the existing merge authority; \`$root/.agents/skills/landing-queue/SKILL.md\` owns that procedure.
   A changed target returns you to preparation; at \`landed\`, append \`done: landed {branch} at {head}\` and stop.
EOF
}

fm_dod_block() {  # <mode> <task-id> [landing-branch]
  local mode=$1 id=$2 landing_branch=${3:-} meta_file
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      fm_direct_pr_target_block "$landing_branch" || return 1
      ;;
    local-only)
      meta_file=$(fm_dod_quote "${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}/$id.meta")
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto your recorded landing branch - the \`landing_branch=\` firstmate recorded for this task in \`$meta_file\` (contract: bin/fm-spawn.sh's header), falling back to the default branch only when none is recorded.
Use the queue's current assigned target below when rebasing.
When it is implemented and committed, follow the self-service landing train below through landing.
The configured merge authority approves the ready branch, then firstmate merges it into that same recorded landing branch, or the default branch when none is recorded, through the guarded fast-forward path.
EOF
      fm_landing_queue_block "$id" "$landing_branch"
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
Once your implementation is committed, start /no-mistakes yourself and continue through the PR and green checks without waiting for a firstmate instruction.
Do not report \`done:\` before validation; the CI-green return point below is your completion gate.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.
Every gate fix must be a descendant commit on top of the current head.
Folding, amending, squashing, and rebasing are unsupported while a run is active.
For a commit-message or history finding, use the finding's own non-rewriting fallback first.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      fm_nm_target_block "$landing_branch" || return 1
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
