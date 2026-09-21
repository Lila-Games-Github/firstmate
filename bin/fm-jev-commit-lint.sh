#!/usr/bin/env bash
# fm-jev-commit-lint.sh - advisory commit-message and branch-risk observer.
#
# Usage: fm-jev-commit-lint.sh <worktree>
#
# Resolves the task branch's merge base against origin/HEAD, then local main or
# master, and builds one request containing each branch-only commit's message and
# diff. Five Nouls per commit cover message/diff agreement, persistence or save
# format, weakened tests, debug output, and credentials. Shadow mode records the
# result only. Active mode may append one advisory `note:` to state/<id>.status
# listing flagged commits; it never blocks or authorizes a landing.
#
# Off or unavailable mode exits zero without output or side effects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUESTIONS="$SCRIPT_DIR/jev-questions/commit-lint.json"

[ "$#" -eq 1 ] || exit 0
WT=$1
MODE=$("$SCRIPT_DIR/fm-jev.sh" mode commit-lint 2>/dev/null || printf 'off\n')
[ "$MODE" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] || exit 0
case "$BRANCH" in fm/*) TASK_ID=${BRANCH#fm/} ;; *) TASK_ID=${BRANCH##*/} ;; esac
case "$TASK_ID" in ''|*[!A-Za-z0-9._-]*) TASK_ID=$(basename "$WT") ;; esac

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
COMMITS_JSONL="$TMP_DIR/commits.jsonl"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
: > "$COMMITS_JSONL"
INDEX=0
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  INDEX=$((INDEX + 1))
  KEY="commit_$INDEX"
  SUBJECT=$(git -C "$WT" show -s --format='%s%n%n%b' "$commit" 2>/dev/null) || exit 0
  DIFF=$(git -C "$WT" show --format= --no-ext-diff --find-renames --find-copies --unified=20 "$commit" 2>/dev/null) || exit 0
  jq -cn --arg key "$KEY" --arg sha "$commit" --arg message "$SUBJECT" --arg diff "$DIFF" \
    '{key:$key,sha:$sha,message:$message,diff:$diff}' >> "$COMMITS_JSONL" || exit 0
done < <(git -C "$WT" rev-list --reverse "$MERGE_BASE..HEAD" 2>/dev/null)
[ "$INDEX" -gt 0 ] || exit 0

COMMITS=$(jq -sc 'map({key:.key,value:{sha:.sha,message:.message,diff:.diff}}) | from_entries' "$COMMITS_JSONL") || exit 0
ESTIMATE=$(( (${#COMMITS} + 3) / 4 ))
jq -n --arg subject "$TASK_ID" --argjson commits "$COMMITS" --argjson estimate "$ESTIMATE" \
  --slurpfile template "$QUESTIONS" '
  def qname($commit; $check): $commit + "__" + $check;
  ($commits | keys) as $commit_keys |
  ($template[0] | keys) as $checks |
  {request:{state:{commits:$commits},questions:(
     reduce $commit_keys[] as $commit ({};
       reduce $checks[] as $check (.;
         . + {(qname($commit;$check)):
           ($template[0][$check] | .instructions |= gsub("\\{commit_key\\}";$commit))}))
   )},
   ledger:{subject:$subject,baseline_decision:"safe",
     baseline_rationale:"The existing landing path applies its normal delivery gates without this additional Jev risk lint.",
     estimated_big_model_tokens:$estimate,
     verdict:{strategy:"risk_nouls",positive_label:"flagged",negative_label:"safe",
       checks:[
         $commit_keys[] as $commit | $checks[] as $check |
         {question:qname($commit;$check),risk_when:(if $check == "message_matches" then "no" else "yes" end)}
       ]}}}
' > "$ENVELOPE" || exit 0

"$SCRIPT_DIR/fm-jev.sh" consult commit-lint < "$ENVELOPE" > "$RESULT" 2>/dev/null || exit 0
[ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" = available ] || exit 0

jq -r --argjson commits "$COMMITS" '
  . as $r |
  [($commits | to_entries[]) as $commit |
    {sha:$commit.value.sha,
     flags:[($r.risks[] | select(.question | startswith($commit.key + "__")) |
       select(.risk_probability >= $r.confidence_floor) |
       .question | sub("^" + $commit.key + "__"; ""))]} |
    select(.flags | length > 0) |
    "\(.sha[0:12]) \(.flags | join(","))"] |
  if length == 0 then "commit-lint: clear" else "commit-lint: " + join("; ") end
' "$RESULT"

if [ "$MODE" = active ]; then
  FLAGS=$(jq -r --argjson commits "$COMMITS" '
    . as $r |
    [($commits | to_entries[]) as $commit |
      {sha:$commit.value.sha,
       flags:[($r.risks[] | select(.question | startswith($commit.key + "__")) |
         select(.risk_probability >= $r.confidence_floor) |
         .question | sub("^" + $commit.key + "__"; ""))]} |
      select(.flags | length > 0) |
      "\(.sha[0:12])=\(.flags | join(","))"] | join("; ")
  ' "$RESULT")
  STATUS_FILE="$STATE/$TASK_ID.status"
  if [ -n "$FLAGS" ] && [ -f "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ]; then
    NOTE="note: Jev commit lint flagged $FLAGS (advisory only; landing is unchanged)"
    grep -qxF "$NOTE" "$STATUS_FILE" 2>/dev/null || printf '%s\n' "$NOTE" >> "$STATUS_FILE" 2>/dev/null || true
  fi
fi
exit 0
