#!/usr/bin/env bash
# fm-jev-open-questions.sh - propose semantic status for referenced open questions.
#
# Usage: fm-jev-open-questions.sh <questions-file> <pages-dir>
#
# A question line is a Markdown bullet ending in `[page: relative/path.md]`.
# The relative path must stay beneath pages-dir and name a readable regular file.
# One request contains one Choice per question: still_open, settled, or
# cannot_tell. The proposal is written beside the questions file as
# <stem>-jev-review.md. It never edits the questions file or any referenced page.
# Off or unavailable mode exits zero without output or side effects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTIONS_TEMPLATE="$SCRIPT_DIR/jev-questions/open-questions.json"
[ "$#" -eq 2 ] || exit 0
QUESTIONS_FILE=$1
PAGES_DIR=$2
MODE=$("$SCRIPT_DIR/fm-jev.sh" mode open-questions 2>/dev/null || printf 'off\n')
[ "$MODE" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$QUESTIONS_FILE" ] && [ -r "$QUESTIONS_FILE" ] && [ ! -L "$QUESTIONS_FILE" ] || exit 0
[ -d "$PAGES_DIR" ] && [ ! -L "$PAGES_DIR" ] || exit 0
PAGES_ROOT=$(cd -P "$PAGES_DIR" 2>/dev/null && pwd -P) || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-questions.XXXXXX") || exit 0
trap 'rm -rf -- "$TMP_DIR"' EXIT
ITEMS="$TMP_DIR/items.jsonl"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
: > "$ITEMS"
INDEX=0
while IFS= read -r line || [ -n "$line" ]; do
  TRIMMED=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//')
  case "$TRIMMED" in
    -[[:space:]]*) ;;
    *) continue ;;
  esac
  PAGE=$(printf '%s\n' "$line" | sed -n 's/.*\[page:[[:space:]]*\([^]]*\)\][[:space:]]*$/\1/p')
  [ -n "$PAGE" ] || continue
  case "$PAGE" in /*|*'..'*|*\\*) continue ;; esac
  PAGE_DIR=$(dirname "$PAGES_ROOT/$PAGE")
  PAGE_DIR=$(cd -P "$PAGE_DIR" 2>/dev/null && pwd -P) || continue
  case "$PAGE_DIR" in "$PAGES_ROOT"|"$PAGES_ROOT"/*) ;; *) continue ;; esac
  PAGE_FILE="$PAGE_DIR/$(basename "$PAGE")"
  [ -f "$PAGE_FILE" ] && [ -r "$PAGE_FILE" ] && [ ! -L "$PAGE_FILE" ] || continue
  QUESTION=$(printf '%s\n' "$TRIMMED" | sed 's/^-[[:space:]]*//; s/[[:space:]]*\[page:[[:space:]]*[^]]*\][[:space:]]*$//')
  [ -n "$QUESTION" ] || continue
  INDEX=$((INDEX + 1))
  KEY="question_$INDEX"
  PAGE_TEXT=$(cat "$PAGE_FILE") || exit 0
  jq -cn --arg key "$KEY" --arg question "$QUESTION" --arg page "$PAGE" --arg text "$PAGE_TEXT" \
    '{key:$key,question:$question,page:$page,text:$text}' >> "$ITEMS" || exit 0
done < "$QUESTIONS_FILE"
[ "$INDEX" -gt 0 ] || exit 0

ITEMS_JSON=$(jq -sc 'map({key:.key,value:{question:.question,page:.page,text:.text}}) | from_entries' "$ITEMS") || exit 0
EXISTING=$(jq -cn --argjson items "$ITEMS_JSON" 'reduce ($items | keys[]) as $key ({}; . + {($key):"still_open"})') || exit 0
ESTIMATE=$(( (${#ITEMS_JSON} + 3) / 4 ))
jq -n --arg subject "$(basename "$QUESTIONS_FILE")" --argjson items "$ITEMS_JSON" \
  --argjson existing "$EXISTING" --argjson estimate "$ESTIMATE" --slurpfile template "$QUESTIONS_TEMPLATE" '
  ($items | keys) as $keys |
  {request:{state:{questions:$items},questions:(reduce $keys[] as $key ({};
     . + {($key):($template[0].question
       | .instructions |= gsub("\\{question_key\\}";$key))}))},
   ledger:{subject:$subject,baseline_decision:$existing,
     baseline_rationale:"The existing question-register path leaves each entry open until an explicit reviewer settles it.",
     estimated_big_model_tokens:$estimate,
     verdict:{strategy:"choices",questions:$keys}}}
' > "$ENVELOPE" || exit 0

"$SCRIPT_DIR/fm-jev.sh" consult open-questions < "$ENVELOPE" > "$RESULT" 2>/dev/null || exit 0
[ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" = available ] || exit 0

case "$QUESTIONS_FILE" in
  *.md) OUTPUT=${QUESTIONS_FILE%.md}-jev-review.md ;;
  *) OUTPUT=$QUESTIONS_FILE-jev-review.md ;;
esac
OUTPUT_TMP="$(dirname "$OUTPUT")/.$(basename "$OUTPUT").tmp.$$"
jq -r --argjson items "$ITEMS_JSON" '
  . as $r |
  "# Proposed Jev open-question review", "",
  "Consultation: `\($r.consultation_id)`", "",
  ($items | to_entries[] as $item |
    ($r.answers[$item.key]) as $answer |
    "- **\($answer.choice)** (`\($answer.confidence)`): \($item.value.question) [page: \($item.value.page)]")
' "$RESULT" > "$OUTPUT_TMP" || { rm -f "$OUTPUT_TMP"; exit 0; }
chmod 0600 "$OUTPUT_TMP" || { rm -f "$OUTPUT_TMP"; exit 0; }
mv -f "$OUTPUT_TMP" "$OUTPUT" || { rm -f "$OUTPUT_TMP"; exit 0; }
printf '%s\n' "$OUTPUT"
exit 0
