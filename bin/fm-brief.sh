#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--lane --landing-branch <branch> [--lane-branch <branch>]] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to the recorded landing branch (else the default branch)
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --lane writes the same ship contract for a Playbot lane. A lane brief is designed
# to need ZERO dispatch-time overrides: a caller hands it over with nothing but
# "read the brief at <path> and follow it exactly" plus a one-line task summary, so
# every lane-specific instruction firstmate used to send by hand is generated here.
# Three differences from a crewmate brief carry that:
#   1. Branch. A lane's workspace already owns its branch, so every crewmate
#      `fm/<task-id>` instruction - the setup step, rule 1, the definition of done,
#      and the ready status line - becomes "verify and stay on the workspace's own
#      branch, and create or switch none".
#   2. Base. firstmate creates a crewmate's worktree from the recorded landing
#      branch locally, while Playbot creates a lane workspace from that branch's
#      REMOTE tip, so an unpushed landing leaves the workspace behind. Setup step 1b
#      runs bin/fm-lane-base-check.sh, whose own header and --help own that check's
#      contract and exit codes, and the generated brief carries only its invocation
#      plus the three arms of that exit code: proceed, reset to the ref it names
#      after disclosing any Playbot churn it names, or stop with the line it
#      reported. The two PR-producing modes pass its --publishes flag, because a
#      PR's base is the landing branch as published; local-only does not.
#   3. Delivery contract. The mode is declared prominently after the task, above the
#      Herdr and setup sections, repeating only the machine-readable contract line
#      and that mode's one prohibition and pointing at the Definition of done as the
#      only authority, so firstmate never needs to restate the mode on dispatch.
# Everything else, including the worktree-isolation assertion, the status protocol,
# the shared-daemon rule, and the {TASK} placeholder, is identical to a non-lane
# brief of the same mode. Task-specific content still belongs in {TASK}.
# --lane-branch <branch> names the workspace branch exactly (Playbot's generated
# task/<task-id>-<date>, for example); without it the brief refers to the branch the
# workspace was created on rather than inventing a name. It requires --lane.
# --landing-branch <branch> names the branch the base check compares against and is
# REQUIRED with --lane: the base check is what a lane cannot be dispatched without,
# a lane is created by Playbot's dispatch and never by bin/fm-spawn.sh so it has no
# recorded landing_branch= to read, and substituting a repository default is exactly
# what docs/playbot-lanes.md forbids for a lane - so a brief that could not name the
# branch is refused at scaffold time rather than emitted for a worker to stop on.
# It requires --lane, because a non-lane worktree is already based locally on the
# branch firstmate recorded for it. The value is a plain local branch name that git
# itself accepts (git check-ref-format --branch), restricted to letters, digits,
# '.', '_', '/', '+' and '-' because it is rendered into commands the brief tells
# the worker to run, and refs/... ref paths are refused in favour of the bare name;
# --lane-branch takes exactly the same value form. These are string checks only, so
# a multi-segment name such as proto/godot/frog-pile is always accepted and a
# remote-tracking spelling such as origin/main is accepted here too: whether the
# branch actually exists is settled by the generated brief's step 1b in the real
# lane worktree, whose missing-branch arm stops and reports.
# --lane is refused on scout and secondmate scaffolds: a scout brief carries no
# branch convention to replace, and a charter is not a lane.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns approval decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Ship and scout briefs also carry one conditional terminal-lifecycle pointer to
# the learning-candidate skill plus an absolute shell-quoted capture invocation
# bound to the selected private home and tracked command. It causes no completion
# audit: a routine success does nothing, an originating lane performs bounded
# capture only after a named qualifying signal, and curation never blocks cleanup.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
# Both lane branch flags name a branch the generated brief renders into commands a
# worker runs, so the same screen applies to both: a conservative character set, so
# no shell metacharacter or command substitution can ever be rendered; git's own
# branch-name validation, which owns the leading-dash, `..`, `@{`, trailing-.lock,
# control-character and empty-segment cases; and a refusal of fully-qualified
# refs/... spellings, which the brief's own commands qualify themselves and which
# `git branch --show-current` never prints.
# All three are pure string checks that need no repository, and deliberately so:
# this scaffold cannot know which clone a lane will actually use, since the REPO
# argument carries no reliable signal about which repository it names (recorded in
# .agents/skills/firstmate-coding-guidelines/SKILL.md), and a Playbot workspace is
# a worktree of Playbot's project root rather than a clone under this home. A
# scaffold-time resolution check would therefore judge the wrong tree and could
# refuse a valid branch, which is worse than no check. Whether the branch exists is
# settled by the generated brief's step 1b, in the real lane worktree, where the
# answer is knowable and the arm is fail-closed.
reject_unsafe_branch_value() {
  local flag=$1 value=$2
  case "$value" in
    *[!A-Za-z0-9._/+-]*)
      echo "error: $flag takes a plain branch name; '$value' contains characters outside letters, digits, '.', '_', '/', '+' and '-', and this value is rendered into commands the brief tells the worker to run" >&2
      return 1 ;;
    refs/heads/*)
      echo "error: $flag names a branch, not a ref path; the generated brief qualifies the name itself, so pass '${value#refs/heads/}'" >&2
      return 1 ;;
    refs/*)
      echo "error: $flag names a branch, not a ref path; the generated brief resolves refs/heads/<branch> only, and a tag or remote-tracking ref path can never satisfy it" >&2
      return 1 ;;
  esac
  git check-ref-format --branch "$value" >/dev/null 2>&1 || {
    echo "error: $flag value '$value' is not a valid git branch name (git check-ref-format --branch refuses it)" >&2
    return 1
  }
}

KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
LANE=0
LANE_BRANCH=
LANE_BRANCH_SET=0
LANDING_BRANCH=
LANDING_BRANCH_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      lane-branch) LANE_BRANCH=$a; LANE_BRANCH_SET=1 ;;
      landing-branch) LANDING_BRANCH=$a; LANDING_BRANCH_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --lane) LANE=1 ;;
    --lane-branch) want_value=lane-branch ;;
    --lane-branch=*) LANE_BRANCH=${a#--lane-branch=}; LANE_BRANCH_SET=1 ;;
    --landing-branch) want_value=landing-branch ;;
    --landing-branch=*) LANDING_BRANCH=${a#--landing-branch=}; LANDING_BRANCH_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's approval authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's approval posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# A lane brief replaces the crewmate branch convention, so it only means anything
# where that convention exists: a ship scaffold. Refuse the other combinations
# rather than emitting a brief whose lane wording contradicts its own kind.
if [ "$LANE" -eq 1 ] && [ "$KIND" != ship ]; then
  echo "error: --lane applies only to ship briefs; a scout brief creates no branch to replace and a secondmate charter is not a lane" >&2
  exit 1
fi
if [ "$LANE_BRANCH_SET" -eq 1 ]; then
  [ "$LANE" -eq 1 ] || {
    echo "error: --lane-branch requires --lane; a non-lane brief works on its own fm/<task-id> branch" >&2
    exit 1
  }
  [ -n "$LANE_BRANCH" ] || { echo "error: --lane-branch requires a value" >&2; exit 1; }
  reject_unsafe_branch_value --lane-branch "$LANE_BRANCH" || exit 1
fi
if [ "$LANDING_BRANCH_SET" -eq 1 ]; then
  [ "$LANE" -eq 1 ] || {
    echo "error: --landing-branch requires --lane; a non-lane worktree is already based on the landing branch firstmate recorded for the task" >&2
    exit 1
  }
  [ -n "$LANDING_BRANCH" ] || { echo "error: --landing-branch requires a value" >&2; exit 1; }
  reject_unsafe_branch_value --landing-branch "$LANDING_BRANCH" || exit 1
fi
# The base check is the first thing a lane brief tells its worker to do, and it
# cannot be written without the branch it compares against, so a lane brief that
# could not name one is never generated.
if [ "$LANE" -eq 1 ] && [ "$LANDING_BRANCH_SET" -ne 1 ]; then
  echo "error: --lane requires --landing-branch <branch>: a lane verifies its base against that branch as its first action, and a Playbot lane has no recorded landing branch to fall back on" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
META_FILE=$(shell_quote "$STATE/$ID.meta")

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

LEARNING_HOME=$(shell_quote "$FM_HOME")
LEARNING_STATE=$(shell_quote "$STATE")
LEARNING_COMMAND=$(shell_quote "$SCRIPT_DIR/fm-learning-candidate.sh")
LEARNING_TASK=$(shell_quote "$ID")
LEARNING_PROJECT=$(shell_quote "$REPO")
LEARNING_SKILL="$FM_ROOT/.agents/skills/learning-candidate-lifecycle/SKILL.md"
LEARNING_SECTION=$(printf '%s\n' \
'# Learning-candidate reminder' \
"If this task hits a meaningful-signal condition named in \`$LEARNING_SKILL\`, read that skill and perform its bounded originating-lane capture before terminal completion when practical." \
'When that skill requires capture, set the incident variables named below and run this generated command from any working directory.' \
'```sh' \
"FM_HOME=$LEARNING_HOME FM_STATE_OVERRIDE=$LEARNING_STATE $LEARNING_COMMAND capture \\" \
"  --task $LEARNING_TASK \\" \
"  --project $LEARNING_PROJECT \\" \
"  --signal \"\${FM_LEARNING_SIGNAL:?set FM_LEARNING_SIGNAL}\" \\" \
"  --impact \"\${FM_LEARNING_IMPACT:?set FM_LEARNING_IMPACT}\" \\" \
"  --root-cause \"\${FM_LEARNING_ROOT_CAUSE:?set FM_LEARNING_ROOT_CAUSE}\" \\" \
"  --escaped-contract \"\${FM_LEARNING_ESCAPED_CONTRACT:?set FM_LEARNING_ESCAPED_CONTRACT}\" \\" \
"  --missing-check \"\${FM_LEARNING_MISSING_CHECK:?set FM_LEARNING_MISSING_CHECK}\" \\" \
"  --consumer \"\${FM_LEARNING_CONSUMER:?set FM_LEARNING_CONSUMER}\" \\" \
"  --prevention \"\${FM_LEARNING_PREVENTION:?set FM_LEARNING_PREVENTION}\" \\" \
"  --evidence \"\${FM_LEARNING_EVIDENCE:?set FM_LEARNING_EVIDENCE}\" \\" \
"  --proposed-owner \"\${FM_LEARNING_PROPOSED_OWNER:?set FM_LEARNING_PROPOSED_OWNER}\" \\" \
"  --counterfactual \"\${FM_LEARNING_COUNTERFACTUAL:?set FM_LEARNING_COUNTERFACTUAL}\"" \
'```' \
'Do not run a completion audit to search for candidates; routine success adds nothing.' \
"The originating lane captures only, and neither later classification nor curation may block this task's cleanup.")

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

$LEARNING_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report, the status file below, and a private learning candidate created through the conditional lifecycle above.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by this task's explicit
# delivery mode, validated above. The generated DOD opens with the fixed
# "Delivery contract: mode=<mode>" line that bin/fm-spawn.sh checks against its own
# explicit --mode before launching.
#
# A lane's workspace already owns its branch, so every branch instruction below
# becomes "stay on the branch you are already on". LANE_BRANCH_DESC names that
# branch exactly when the caller supplied it and otherwise refers to the branch the
# workspace was created on; nothing here ever invents a branch name.
#
# A lane also needs its base verified before it works, which an ordinary crewmate
# does not: firstmate creates a crewmate's worktree from the recorded landing
# branch locally, while Playbot creates a lane workspace from that branch's REMOTE
# tip, so a landing that has not been pushed yet leaves the workspace behind.
# That verdict is bin/fm-lane-base-check.sh's to give - it names every state and
# is tested per state - so nothing here re-derives it; the generated step carries
# the invocation and branches on its exit code. --landing-branch is validated as
# required before anything is written, so every lane brief names one concrete
# branch here, in rule 1 and in the definition of done.
if [ "$LANE" -eq 1 ]; then
  if [ -n "$LANE_BRANCH" ]; then
    LANE_BRANCH_DESC="your workspace branch \`$LANE_BRANCH\`"
    LANE_READY_LINE="\`done: ready in branch $LANE_BRANCH\`"
  else
    LANE_BRANCH_DESC="the branch your workspace was created on"
    LANE_READY_LINE="\`done: ready in branch {your workspace branch}\`"
  fi
  LANE_LANDING_TARGET="your landing branch \`$LANDING_BRANCH\`"
  # Whether this landing branch is safe to start from is one question with many
  # states, and prose in a generated document cannot be tested, so the procedure
  # lives in bin/fm-lane-base-check.sh and the brief carries only its invocation
  # and the three arms of its exit code. That script also reads the tracked-churn
  # allowlist from its owner, so no copy of those paths is rendered here.
  # --publishes is passed only by the modes that ship through a PR: a PR's base is
  # the landing branch as published, so those lanes may not start from a local
  # landing branch carrying commits the remote tip lacks. local-only publishes
  # nothing and makes no remote comparison.
  LANE_BASE_CHECK=$(shell_quote "$FM_ROOT/bin/fm-lane-base-check.sh")" $LANDING_BRANCH"
  case "$MODE" in
    local-only) ;;
    *) LANE_BASE_CHECK="$LANE_BASE_CHECK --publishes" ;;
  esac
  SETUP_PREAMBLE="You are in a Playbot lane workspace: an isolated git worktree of $REPO that Playbot created and already checked out on the branch that workspace owns."
  IFS= read -r -d '' SETUP1 <<EOF || true
1. First action: verify your starting point before you touch anything. Both checks below are mandatory; this brief is complete, so nothing outside it will tell you to run them.

   a. **Branch.** Your workspace already owns its branch, and that branch is what workspace freshness, retirement inspection, and firstmate's landing all resolve.
      Run \`git branch --show-current\` and verify it is $LANE_BRANCH_DESC.
      If it is not, STOP - append \`blocked: lane is not on its workspace branch\` to the status file and stop.
      Never run \`git checkout -b\` or \`git switch -c\`, and never switch branches: a branch of your own steps off the one your workspace owns.

   b. **Base.** Playbot creates a lane workspace from the REMOTE tip of the landing branch, so a landing that has not been pushed yet leaves your workspace behind and you would build on stale code. One command decides whether your base is safe to start from; act on its EXIT CODE, never on your own reading of the repository.
      Run \`$LANE_BASE_CHECK\` from the top of your workspace. It writes nothing - no reset, no fetch, no ref update - it only reports.
      - exit 0 (\`current: ...\`): your base is safe; proceed.
      - exit 10: it printed \`reset-required: <ref>\` and \`churn-paths: <paths>\`. When \`churn-paths\` names any path, DISCLOSE BEFORE YOU RESET: run \`git diff HEAD -- <exactly those paths>\` and leave its complete output in your log, untruncated and unsummarized - \`prototype-game/project.godot\` may be among them, and it is a hand-editable settings file rather than a generated one, so it can carry real human edits - then append \`working: discarding Playbot churn before base reset: {those paths}\` to the status file. With paths named and that diff uncaptured or that line unappended, do not reset. Then run \`git reset --hard <the ref it printed>\` and proceed. When \`churn-paths\` is empty there is nothing to disclose: reset to that ref and proceed.
      - exit 20: it printed one \`blocked: ...\` line naming the evidence. STOP - append that exact line to the status file and stop.
      - any other exit code is itself a blocker: append \`blocked: lane base check failed: {its output}\` to the status file and stop.
EOF
  SETUP1=${SETUP1%$'\n'}
else
  SETUP_PREAMBLE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean copy of your task's base branch (its recorded landing branch, else the default branch)."
  SETUP1="1. First action: create your branch: \`git checkout -b fm/$ID\`"
fi

case "$MODE" in
  direct-PR)
    SETUP2=""
    if [ "$LANE" -eq 1 ]; then
      RULE1="1. Never push to the default branch (push only $LANE_BRANCH_DESC; never create or switch branches). Never merge a PR."
      DOD_PR_STEP="When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, passing \`--base $LANDING_BRANCH\` explicitly so the PR targets your landing branch.
That base is not optional: your work is based on \`$LANDING_BRANCH\`, and a PR opened without it targets the repository's default branch instead - a branch this lane must not touch, carrying every commit on the landing branch that the default branch does not have.
Then append \`done: PR {url}\` to the status file and stop."
    else
      RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
      DOD_PR_STEP="When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop."
    fi
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
$DOD_PR_STEP
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
    ;;
  local-only)
    SETUP2=""
    # One rendering for both modes: the branch phrase, the ready line and the
    # landing-branch phrases are the only differences, and a lane resolves its
    # landing branch from --landing-branch rather than from a state/<id>.meta it
    # never has.
    if [ "$LANE" -eq 1 ]; then
      RULE1="1. Never push to any remote and never open a PR. Work only on $LANE_BRANCH_DESC; never create or switch branches. Firstmate handles the merge into $LANE_LANDING_TARGET."
      DOD_BRANCH_DESC="$LANE_BRANCH_DESC"
      DOD_READY_LINE="$LANE_READY_LINE"
      DOD_LANDING_RULE="Keep that branch a clean fast-forward onto $LANE_LANDING_TARGET.
If that landing branch has advanced, rebase onto it so the eventual merge stays a fast-forward."
      DOD_LANDING_MERGE="The configured merge authority approves the ready branch, then firstmate merges it into $LANE_LANDING_TARGET through the guarded fast-forward path."
    else
      RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into your recorded landing branch (the default branch when none is recorded)."
      DOD_BRANCH_DESC="your branch \`fm/$ID\`"
      DOD_READY_LINE="\`done: ready in branch fm/$ID\`"
      DOD_LANDING_RULE="Keep your branch a clean fast-forward onto your recorded landing branch - the \`landing_branch=\` firstmate recorded for this task in \`$META_FILE\` (contract: bin/fm-spawn.sh's header), falling back to the default branch only when none is recorded.
If that landing branch has advanced, rebase onto it so the eventual merge stays a fast-forward."
      DOD_LANDING_MERGE="The configured merge authority approves the ready branch, then firstmate merges it into that same recorded landing branch, or the default branch when none is recorded, through the guarded fast-forward path."
    fi
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on $DOD_BRANCH_DESC. Do NOT push, do NOT open a PR, do NOT merge.
$DOD_LANDING_RULE
When it is implemented and committed, append $DOD_READY_LINE to the status file and stop.
$DOD_LANDING_MERGE
EOF
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    # A direct-PR lane establishes its own PR base with `gh-axi --base`, but
    # `no-mistakes axi run` takes no base flag, so this mode cannot. The lane is
    # still held to the publication precondition, whose whole premise is that the
    # PR base is the landing branch - so say plainly who chooses that base here,
    # and make a mismatch a report rather than something the worker may repair.
    # The confirmation lands on the OPENED PR rather than before the run, because
    # nothing the installed no-mistakes exposes reports its configured target:
    # `doctor` prints System/Agents health and `status` prints repo, remote, gate
    # path and daemon state, neither a base. A precondition the worker has no way
    # to read is worse than none, because it reads as a guarantee while the only
    # failure-free reading left is "nothing contradicts it, carry on".
    if [ "$LANE" -eq 1 ]; then
      RULE1="1. Never push to the default branch. Never merge a PR. Work only on $LANE_BRANCH_DESC; never create or switch branches."
      NM_LANE_PR_BASE="
That PR's base is whatever no-mistakes is configured to target; \`no-mistakes axi run\` takes no base flag, so neither this brief nor you can set it, and no-mistakes exposes no way to read that target in advance - so you confirm the base on the PR itself, at the end of this section."
      NM_LANE_PR_BASE_CHECK="Before you report anything as done, confirm the base of the PR no-mistakes opened. Read it with \`gh-axi api /repos/{owner}/{repo}/pulls/{number} --jq .base.ref\`.
If that base is not \`$LANDING_BRANCH\`, STOP and REPORT: append \`blocked: no-mistakes opened {url} against base {the base you read}, not landing branch $LANDING_BRANCH\` to the status file and stop. Never pass a base, edit no-mistakes configuration, retarget or edit the PR, or work around it - reporting the mismatch is the whole of your job here.
"
    else
      RULE1='1. Never push to the default branch. Never merge a PR.'
      NM_LANE_PR_BASE=""
      NM_LANE_PR_BASE_CHECK=""
    fi
    IFS= read -r -d '' DOD <<EOF || true
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.$NM_LANE_PR_BASE

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its \`AGENTS.md\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: it would silently bypass firstmate's authority check and any required captain escalation.

${NM_LANE_PR_BASE_CHECK}After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
    ;;
esac

# read -r -d '' preserves the heredoc's trailing newline that the removed
# $(...) command substitution used to strip. Drop that one newline so generated
# briefs stay byte-identical to the historical Bash 5 output.
DOD=${DOD%$'\n'}

# A lane brief must need no dispatch-time restatement of its delivery mode: the
# incident this guards is a lane that ran the no-mistakes pipeline on a local-only
# project, after which firstmate began restating the mode in every dispatch
# message. The prominent block repeats only the machine-readable contract line and
# the one prohibition that mode implies, then points at the Definition of done as
# the single authority, so the two copies cannot drift into different contracts.
# bin/fm-spawn.sh reads the first "Delivery contract: mode=" line, which is this
# one, and both are rendered from the same validated $MODE.
LANE_CONTRACT_BLOCK=""
if [ "$LANE" -eq 1 ]; then
  case "$MODE" in
    direct-PR)
      LANE_CONTRACT_RULE="You push your branch and open the PR yourself with \`gh-axi\`. Never run /no-mistakes on this task." ;;
    local-only)
      LANE_CONTRACT_RULE="No remote, no PR, no pipeline: never push, never open a PR, never run /no-mistakes. Firstmate lands your branch." ;;
    *)
      LANE_CONTRACT_RULE="Implement and commit, then report done and WAIT: firstmate tells you when to run /no-mistakes. Do not start the pipeline before it does." ;;
  esac
  IFS= read -r -d '' LANE_CONTRACT_BLOCK <<EOF || true

# Delivery contract - READ THIS BEFORE YOU SHIP ANYTHING
Delivery contract: mode=$MODE
$LANE_CONTRACT_RULE
\`# Definition of done\` at the end of this brief is the full contract and the only delivery authority. Do not infer a different path from habit, from what another lane did, or from anything said when this task was handed to you: this brief is complete and needs no dispatch-time override.
EOF
fi

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}
$LANE_CONTRACT_BLOCK
$HERDR_SECTION

$LEARNING_SECTION

# Setup
$SETUP_PREAMBLE

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

$SETUP1$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it except a private learning candidate created through the conditional lifecycle above.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will apply the configured authority and reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
if [ "$LANE" -eq 1 ]; then
  echo "scaffolded: $BRIEF (ship lane, mode=$MODE; replace {TASK})"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
fi
