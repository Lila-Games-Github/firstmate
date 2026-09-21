#!/usr/bin/env bash
# fm-jev-commit-lint.sh - advisory commit-message and branch-risk observer.
#
# Usage: fm-jev-commit-lint.sh <worktree>
#
# Resolves the task branch's merge base against origin/HEAD, then local main or
# master, and reviews each branch-only commit in its own request: five Nouls
# cover message/diff agreement, persistence or save format, weakened tests,
# debug output, and credentials.
#
# One request per commit is what keeps this use reachable. A single whole-branch
# request routinely exceeds the per-call budget, and one oversized commit would
# then cancel the whole branch's lint. A commit whose own diff still does not
# fit is sent as `git show --stat` plus as many leading hunk bytes as remain
# inside the budget, and its ledger row records truncated=true rather than
# skipping it. A commit whose message, diff summary, and question overhead
# cannot fit is left unreviewed as `status: "too-large"` in the evidence file.
#
# The findings are written to data/<task-id>/commit-lint.json and summarized on
# stdout; bin/fm-jev-report.sh also surfaces them from the ledger. No Jev
# adapter writes a task's status file, because a `note:` there is a status event
# that would supersede a worker's terminal `done:` line. Landing is never
# blocked or authorized by this observer.
#
# Off or unavailable mode names the reason on stderr and exits zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
QUESTIONS="$SCRIPT_DIR/jev-questions/commit-lint.json"
# The client adds the pinned model to the request it sends; keep room for that
# and for any re-encoding difference between this build and that one.
BUDGET_MARGIN=256
DIFF_CONTEXT=20

[ "$#" -eq 1 ] || exit 0
WT=$1
# shellcheck source=bin/fm-jev-adapter-lib.sh
. "$SCRIPT_DIR/fm-jev-adapter-lib.sh"
fm_jev_adapter_ready commit-lint || exit 0
MODE=$FM_JEV_ADAPTER_MODE
command -v jq >/dev/null 2>&1 || exit 0
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

BUDGET=$("$SCRIPT_DIR/fm-jev.sh" request-budget commit-lint 2>/dev/null || printf '0\n')
case "$BUDGET" in ''|*[!0-9]*) exit 0 ;; esac
BUDGET=$((BUDGET - BUDGET_MARGIN))
[ "$BUDGET" -gt 0 ] || exit 0

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] || exit 0
case "$BRANCH" in fm/*) TASK_ID=${BRANCH#fm/} ;; *) TASK_ID=${BRANCH##*/} ;; esac
case "$TASK_ID" in ''|.*|*[!A-Za-z0-9._-]*) TASK_ID=$(basename "$WT") ;; esac
EVIDENCE=
case "$TASK_ID" in ''|.*|*[!A-Za-z0-9._-]*) TASK_ID=unknown ;; *) EVIDENCE="$DATA/$TASK_ID/commit-lint.json" ;; esac

BASE=
REMOTE_HEAD=$(git -C "$WT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -n "$REMOTE_HEAD" ] && git -C "$WT" rev-parse --verify --quiet "$REMOTE_HEAD^{commit}" >/dev/null; then
  BASE=$REMOTE_HEAD
else
  for candidate in main master; do
    if git -C "$WT" rev-parse --verify --quiet "refs/heads/$candidate^{commit}" >/dev/null; then
      BASE="refs/heads/$candidate"
      break
    fi
  done
fi
[ -n "$BASE" ] || exit 0
MERGE_BASE=$(git -C "$WT" merge-base HEAD "$BASE" 2>/dev/null || true)
[ -n "$MERGE_BASE" ] || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-commit.XXXXXX") || exit 0
trap 'rm -rf -- "$TMP_DIR"' EXIT
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
FINDINGS="$TMP_DIR/findings.jsonl"
: > "$FINDINGS"

build_envelope() { # <sha> <message> <diff> <truncated>
  printf '%s' "$2" > "$TMP_DIR/message.txt" || return 1
  printf '%s' "$3" > "$TMP_DIR/diff.txt" || return 1
  jq -n --arg subject "$TASK_ID@${1:0:12}" --arg sha "$1" \
    --rawfile message "$TMP_DIR/message.txt" --rawfile diff "$TMP_DIR/diff.txt" \
    --argjson truncated "$4" --slurpfile template "$QUESTIONS" '
    {sha:$sha,message:$message,diff:$diff,truncated:$truncated} as $commit |
    ($template[0] | keys) as $checks |
    (((($commit | tojson) | length) + 3) / 4 | floor) as $estimate |
    {request:{state:{commit:$commit},questions:(
       reduce $checks[] as $check ({};
         . + {($check):($template[0][$check] | .instructions |= gsub("\\{commit_key\\}";"commit"))}))},
     ledger:{subject:$subject,baseline_decision:"safe",truncated:$truncated,
       baseline_rationale:"The existing landing path applies its normal delivery gates without this additional Jev risk lint.",
       estimated_big_model_tokens:$estimate,
       verdict:{strategy:"risk_nouls",positive_label:"flagged",negative_label:"safe",
         checks:[$checks[] | {question:.,risk_when:(if . == "message_matches" then "no" else "yes" end)}]}}}
  ' > "$ENVELOPE"
}

envelope_bytes() { jq -c '.request' "$ENVELOPE" | LC_ALL=C wc -c | tr -d ' '; }

STOP=
INDEX=0
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  [ -z "$STOP" ] || break
  INDEX=$((INDEX + 1))
  MESSAGE=$(git -C "$WT" show -s --format='%s%n%n%b' "$commit" 2>/dev/null) || continue
  DIFF=$(git -C "$WT" show --format= --no-ext-diff --find-renames --find-copies \
    "--unified=$DIFF_CONTEXT" "$commit" 2>/dev/null) || continue
  TRUNCATED=false
  build_envelope "$commit" "$MESSAGE" "$DIFF" false || continue
  BYTES=$(envelope_bytes)
  case "$BYTES" in ''|*[!0-9]*) continue ;; esac
  if [ "$BYTES" -gt "$BUDGET" ]; then
    # Keep the whole-commit shape (`git show --stat`) and as many leading hunk
    # bytes as fit, halving the hunk budget until the request is inside the cap.
    TRUNCATED=true
    STAT=$(git -C "$WT" show --stat --format= --no-ext-diff "$commit" 2>/dev/null) || STAT=
    build_envelope "$commit" "$MESSAGE" "$STAT" true || continue
    BYTES=$(envelope_bytes)
    case "$BYTES" in ''|*[!0-9]*) BYTES=$((BUDGET + 1)) ;; esac
    if [ "$BYTES" -gt "$BUDGET" ]; then
      jq -cn --arg sha "$commit" '{sha:$sha,status:"too-large",truncated:true,flags:[]}' >> "$FINDINGS"
      continue
    fi
    ALLOWANCE=$((BUDGET - BYTES))
    while [ "$ALLOWANCE" -gt 0 ]; do
      build_envelope "$commit" "$MESSAGE" \
        "$STAT
(diff truncated to fit the Jev per-call budget)
${DIFF:0:$ALLOWANCE}" true || { ALLOWANCE=0; break; }
      BYTES=$(envelope_bytes)
      case "$BYTES" in ''|*[!0-9]*) BYTES=$((BUDGET + 1)) ;; esac
      [ "$BYTES" -gt "$BUDGET" ] || break
      ALLOWANCE=$((ALLOWANCE / 2))
    done
    if [ "$ALLOWANCE" -le 0 ]; then
      build_envelope "$commit" "$MESSAGE" "$STAT" true || continue
    fi
  fi

  "$SCRIPT_DIR/fm-jev.sh" consult commit-lint < "$ENVELOPE" > "$RESULT" 2>/dev/null || continue
  if [ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" != available ]; then
    REASON=$(jq -r '.reason // "unavailable"' "$RESULT" 2>/dev/null)
    case "$REASON" in *call-cap|*spend-cap) STOP=$REASON ;; esac
    jq -cn --arg sha "$commit" --arg reason "$REASON" --argjson truncated "$TRUNCATED" \
      '{sha:$sha,status:"unavailable",reason:$reason,truncated:$truncated,flags:[]}' >> "$FINDINGS"
    continue
  fi
  jq -c --arg sha "$commit" --argjson truncated "$TRUNCATED" '
    {sha:$sha,status:"reviewed",truncated:$truncated,consultation_id:.consultation_id,
     verdict:.verdict,confidence:.confidence,flags:(.flagged // [])}
  ' "$RESULT" >> "$FINDINGS"
done < <(git -C "$WT" rev-list --reverse "$MERGE_BASE..HEAD" 2>/dev/null)
[ "$INDEX" -gt 0 ] || exit 0
[ -s "$FINDINGS" ] || exit 0

SUMMARY=$(jq -s -r '
  [.[] | select((.flags | length) > 0) | "\(.sha[0:12]) \(.flags | join(","))"] as $flagged |
  if ($flagged | length) == 0 then "commit-lint: clear" else "commit-lint: " + ($flagged | join("; ")) end
' "$FINDINGS") || exit 0
printf '%s\n' "$SUMMARY"

if [ -n "$EVIDENCE" ]; then
  EVIDENCE_TMP="$(dirname "$EVIDENCE")/.$(basename "$EVIDENCE").tmp.$$"
  if mkdir -p "$(dirname "$EVIDENCE")" 2>/dev/null; then
    if jq -s --arg task "$TASK_ID" --arg branch "$BRANCH" --arg base "$MERGE_BASE" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$MODE" '
      . as $commits |
      ([$commits[] | select((.flags | length) > 0) | "\(.sha[0:12])=\(.flags | join(","))"]) as $flagged |
      {schema_version:1,task_id:$task,generated_at:$generated,mode:$mode,branch:$branch,
       merge_base:$base,commits:$commits,
       advisory:(if $mode == "active" and ($flagged | length) > 0 then
           "Jev commit lint flagged " + ($flagged | join("; "))
           + " (advisory only; landing is unchanged)"
         else null end)}
    ' "$FINDINGS" > "$EVIDENCE_TMP" 2>/dev/null; then
      chmod 0600 "$EVIDENCE_TMP" 2>/dev/null || true
      mv -f "$EVIDENCE_TMP" "$EVIDENCE" 2>/dev/null || rm -f "$EVIDENCE_TMP"
    else
      rm -f "$EVIDENCE_TMP"
    fi
  fi
fi
exit 0
