#!/usr/bin/env bash
# fm-jev-triage.sh - classify one already-narrowed supervision input.
#
# Usage: printf '%s\n' <item> | fm-jev-triage.sh --kind status|wake|review-answer
#
# One request returns routine or actionable. Review answers also return ruling,
# question, or instruction as a second space-separated field. Callers may
# inspect that output, but existing presentation remains authoritative in every
# mode because a mistaken routine verdict must never make a wake disappear.
# Off or unavailable mode prints nothing and exits zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTIONS="$SCRIPT_DIR/jev-questions/triage.json"
KIND=
if [ "${1:-}" = --kind ] && [ $# -eq 2 ]; then KIND=$2; fi
case "$KIND" in status|wake|review-answer) ;; *) exit 0 ;; esac
MODE=$("$SCRIPT_DIR/fm-jev.sh" mode triage 2>/dev/null || printf 'off\n')
[ "$MODE" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
ITEM=$(cat) || exit 0
[ -n "$ITEM" ] || exit 0
ESTIMATE=$(( (${#ITEM} + 3) / 4 ))

if [ "$KIND" = review-answer ]; then
  jq -n --arg kind "$KIND" --arg item "$ITEM" --argjson estimate "$ESTIMATE" \
    --slurpfile template "$QUESTIONS" '
    {request:{state:{kind:$kind,item:$item},questions:{attention:$template[0].attention,review_kind:$template[0].review_kind}},
     ledger:{subject:$kind,baseline_decision:"actionable",
       baseline_rationale:"The existing presentation path surfaces every narrowed supervision item and never suppresses it.",
       estimated_big_model_tokens:$estimate,
       verdict:{strategy:"choice",question:"attention"}}}
  ' | "$SCRIPT_DIR/fm-jev.sh" consult triage 2>/dev/null \
    | jq -r 'select(.status == "available") | [.answers.attention.choice,.answers.review_kind.choice] | join(" ")'
else
  jq -n --arg kind "$KIND" --arg item "$ITEM" --argjson estimate "$ESTIMATE" \
    --slurpfile template "$QUESTIONS" '
    {request:{state:{kind:$kind,item:$item},questions:{attention:$template[0].attention}},
     ledger:{subject:$kind,baseline_decision:"actionable",
       baseline_rationale:"The existing presentation path surfaces every narrowed supervision item and never suppresses it.",
       estimated_big_model_tokens:$estimate,
       verdict:{strategy:"choice",question:"attention"}}}
  ' | "$SCRIPT_DIR/fm-jev.sh" consult triage 2>/dev/null \
    | jq -r 'select(.status == "available") | .answers.attention.choice'
fi
exit 0
