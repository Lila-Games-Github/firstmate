#!/usr/bin/env bash
# fm-jev-wiki-audit.sh - audit every wiki page against a rule set, one page per consult.
#
# Usage: fm-jev-wiki-audit.sh [--rules <file>] [--label <text>] <wiki-dir> <output-dir>
#
# Every `*.md` file under <wiki-dir>, except those under its top-level
# `sources/` directory, is one subject. Each consultation carries one page (or
# one chunk of it) and one yes/no Choice per rule key, where yes means the page
# violates that rule. The rule set is data: `bin/jev-questions/wiki-audit.json`
# by default, or the file named by --rules, shaped as
#   {"preamble": "<shared instructions>",
#    "rules": {"<key>": {"question": "...", "yes": "...", "no": "...",
#                        "source": "<where the rule comes from>"}}}
# with keys of letters, digits, and underscores. The preamble is prepended to
# every question; `source` is reported but never sent. A malformed rule file
# exits 2 naming the problem, before any page is read or sent.
#
# Each request carries `page.path`, `page.head` (the opening lines),
# `page.outline` (every heading), and `chunk.text`. A page whose request would
# exceed the per-call budget reported by `bin/fm-jev.sh request-budget
# wiki-audit` is split into chunks at section headings outside code fences,
# then at blank lines, then at line ends, and only as a last resort inside one
# over-long line. Every chunk is consulted separately and the answers are merged
# per page and rule: a confident yes in any chunk flags the page, a confident no
# in every chunk clears it, and anything else is reported as not judged
# confidently. The chunks together always carry the whole page, so page text is
# never truncated; the record names how many chunks a page needed and their
# line ranges. The budget is counted in bytes, so dense text can still exceed
# the service's own token limit: when the service rejects a chunk with HTTP 400
# or 413, the whole page is split again at half the size, at most three times,
# and the page record keeps each discarded attempt under `resplits`.
#
# Writes <output-dir>/jev-verdicts.jsonl (one raw per-page record, including
# each chunk's per-rule choice and confidence and its consultation id) and
# <output-dir>/jev-report.md (flags per page, counts per rule, pages not judged
# confidently, chunked pages, and spend). It never edits a wiki page. Each row
# in the Jev ledger has the page path as its subject, with `#chunk-<i>-of-<n>`
# appended for a chunk, and a baseline of "no" for every rule, because without
# this audit nothing checks a page against the rules; a later human
# classification can be recorded with `bin/fm-jev.sh finalize`.
#
# A daily cap or an unreadable ledger stops the run: the remaining pages are
# recorded as unavailable with that reason rather than consulted. Off or
# unavailable mode names the reason on stderr, writes nothing, and exits zero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="$SCRIPT_DIR/jev-questions/wiki-audit.json"
RULES_LABEL="bin/jev-questions/wiki-audit.json (built-in)"
LABEL=
# The client adds the pinned model to the request it sends; keep room for that
# and for any re-encoding difference between this build and that one.
BUDGET_MARGIN=256
HEAD_LINES=12
HEAD_CHARS=1500
OUTLINE_CHARS=4000
MIN_ALLOWANCE=512
MAX_RESPLITS=3

usage() { sed -n '4p' "$0" | sed 's/^# //' >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rules) [ "$#" -ge 2 ] || usage; RULES_FILE=$2; RULES_LABEL=$2; shift 2 ;;
    --label) [ "$#" -ge 2 ] || usage; LABEL=$2; shift 2 ;;
    -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 2 ] || usage
WIKI_DIR=$1
OUT_DIR=$2
command -v jq >/dev/null 2>&1 || { printf 'wiki-audit: jq is required\n' >&2; exit 2; }
[ -d "$WIKI_DIR" ] && [ ! -L "$WIKI_DIR" ] || { printf 'wiki-audit: %s is not a directory\n' "$WIKI_DIR" >&2; exit 2; }
WIKI_ROOT=$(cd -P "$WIKI_DIR" && pwd -P) || exit 2

# Rule parsing happens before the opt-in gate so a broken rule file is reported
# even where Jev is off, and before anything is read from the wiki.
RULE_ERROR=$(jq -r '
  def nonempty: type == "string" and length > 0;
  if type != "object" then "top-level value must be an object"
  elif (.preamble | nonempty | not) then "preamble must be a nonempty string"
  elif (.rules | type) != "object" or (.rules | length) == 0 then "rules must be a nonempty object"
  elif any(.rules | keys[]; test("^[A-Za-z0-9_]+$") | not) then
    "rule keys must use only letters, digits, and underscores: " + ([.rules | keys[] | select(test("^[A-Za-z0-9_]+$") | not)] | join(", "))
  elif any(.rules[]; type != "object") then "each rule must be an object"
  else
    ([.rules | to_entries[] | select(
        (.value.question | nonempty | not) or (.value.yes | nonempty | not) or
        (.value.no | nonempty | not) or
        ((.value | has("source")) and (.value.source | type) != "string")) | .key]) as $bad |
    if ($bad | length) > 0 then
      "rules need nonempty question, yes, and no strings and an optional string source: " + ($bad | join(", "))
    else empty end
  end
' "$RULES_FILE" 2>/dev/null) || RULE_ERROR='not readable JSON'
if [ -n "$RULE_ERROR" ]; then
  printf 'wiki-audit: rule file %s is invalid: %s\n' "$RULES_FILE" "$RULE_ERROR" >&2
  exit 2
fi

# shellcheck source=bin/fm-jev-adapter-lib.sh
. "$SCRIPT_DIR/fm-jev-adapter-lib.sh"
fm_jev_adapter_ready wiki-audit || exit 0
MODE=$FM_JEV_ADAPTER_MODE

BUDGET=$("$SCRIPT_DIR/fm-jev.sh" request-budget wiki-audit 2>/dev/null || printf '0\n')
case "$BUDGET" in ''|*[!0-9]*) BUDGET=0 ;; esac
BUDGET=$((BUDGET - BUDGET_MARGIN))
[ "$BUDGET" -gt 0 ] || { printf 'wiki-audit: no per-call budget is available\n' >&2; exit 0; }
mkdir -p "$OUT_DIR" || { printf 'wiki-audit: cannot create %s\n' "$OUT_DIR" >&2; exit 2; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-wiki.XXXXXX") || exit 0
trap 'rm -rf -- "$TMP_DIR"' EXIT
QUESTIONS="$TMP_DIR/questions.json"
PAGE_STATE="$TMP_DIR/page.json"
CHUNKS="$TMP_DIR/chunks.json"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
CHUNK_RECORDS="$TMP_DIR/chunk-records.jsonl"
RESPLITS="$TMP_DIR/resplits.json"
RECORDS="$TMP_DIR/records.jsonl"
: > "$RECORDS"

jq -c '.preamble as $p | .rules | with_entries(.value = {
    type:"choice", instructions:($p + "\n\n" + .value.question),
    criteria:{yes:.value.yes, no:.value.no}})' "$RULES_FILE" > "$QUESTIONS" || exit 0

# shellcheck disable=SC2016 # jq program; dollar names belong to jq.
CHUNK_FILTER='
  def enc: tojson | utf8bytelength - 2;
  def lines_of: split("\n") as $p | ($p | length) as $n
    | [range(0; $n) as $i | if $i < $n - 1 then $p[$i] + "\n" else $p[$i] end | select(. != "")];
  # Sections start at a Markdown heading outside a code fence.
  def sections: reduce lines_of[] as $line ({fence:false, out:[], cur:[]};
      ($line | test("^ {0,3}(```|~~~)")) as $toggle |
      if (.fence | not) and ($line | test("^#{1,6}[ \t]")) and (.cur | length) > 0
      then .out += [.cur | add] | .cur = [$line]
      else .cur += [$line] end
      | if $toggle then .fence = (.fence | not) else . end)
    | .out + (if (.cur | length) > 0 then [.cur | add] else [] end);
  def paragraphs: reduce lines_of[] as $line ({out:[], cur:[]};
      .cur += [$line] | if $line == "\n" then .out += [.cur | add] | .cur = [] else . end)
    | .out + (if (.cur | length) > 0 then [.cur | add] else [] end);
  def hard_split($max): (([($max / 6 | floor), 1] | max)) as $n | . as $s
    | [range(0; ($s | length); $n) as $i | $s[$i:$i + $n]];
  def fit($max; f): if enc <= $max then [.] else [f] end;
  def pieces($max):
    [sections[] | fit($max; paragraphs[] | fit($max; lines_of[] | fit($max; hard_split($max)[])[])[])[]];
  . as $text |
  if ($text | enc) <= $allowance then [$text]
  else reduce ($text | pieces($allowance))[] as $piece ({out:[], cur:"", size:0};
      ($piece | enc) as $n |
      if .size + $n > $allowance and .size > 0 then .out += [.cur] | .cur = $piece | .size = $n
      else .cur += $piece | .size += $n end)
    | .out + (if .size > 0 then [.cur] else [] end)
  end
  | reduce .[] as $chunk ({line:1, out:[]};
      ($chunk | split("\n") | length) as $parts |
      (if ($chunk | endswith("\n")) then $parts - 1 else $parts end) as $lines |
      .out += [{text:$chunk, first_line:.line, last_line:(.line + ([$lines, 1] | max) - 1)}]
      | .line += $lines)
  | .out
'

build_envelope() { # <page-path> <index> <count> <chunk-json-file> <subject>
  jq -n --arg path "$1" --argjson index "$2" --argjson count "$3" --arg subject "$5" \
    --slurpfile page "$PAGE_STATE" --slurpfile chunk "$4" --slurpfile questions "$QUESTIONS" '
    ($questions[0] | keys) as $keys |
    {request:{state:{page:($page[0] + {path:$path}),
                     chunk:{index:$index, count:$count, text:$chunk[0].text}},
              questions:$questions[0]},
     ledger:{subject:$subject,
       baseline_decision:(reduce $keys[] as $k ({}; . + {($k):"no"})),
       baseline_rationale:"Without this audit no page is checked against the documentation rules, so every rule is presumed unviolated.",
       estimated_big_model_tokens:((($chunk[0].text | utf8bytelength) + 3) / 4 | floor),
       truncated:false,
       verdict:{strategy:"choices", questions:$keys}}}
  ' > "$ENVELOPE"
}

envelope_bytes() { jq -c '.request' "$ENVELOPE" | LC_ALL=C wc -c | tr -d ' '; }

record_chunk_unavailable() { # <index> <reason> <chunk-json-file|->
  local file=$3
  [ "$file" != - ] || { jq -n '{first_line:null,last_line:null,text:""}' > "$TMP_DIR/empty-chunk.json"; file="$TMP_DIR/empty-chunk.json"; }
  jq -c --argjson index "$1" --arg reason "$2" '
    {index:$index, first_line:.first_line, last_line:.last_line,
     bytes:(.text | utf8bytelength), status:"unavailable", reason:$reason,
     consultation_id:null, truncated:false, cost_usd:0, input_tokens:0, answers:{}}
  ' "$file" >> "$CHUNK_RECORDS"
}

# consult_chunks <allowance>: splits the current page at <allowance> bytes of
# encoded text and consults each chunk, appending one record per chunk to
# CHUNK_RECORDS. Sets REJECTED when the service refused a chunk as a bad or
# oversized request, which is how a page whose text tokenizes denser than the
# client's bytes-per-token estimate shows up.
consult_chunks() { # <allowance>
  local allowance=$1 index=0 subject reason
  REJECTED=
  COUNT=
  if jq -Rs -c --argjson allowance "$allowance" "$CHUNK_FILTER" "$PAGE_FILE" > "$CHUNKS" 2>/dev/null; then
    COUNT=$(jq 'length' "$CHUNKS")
  fi
  case "$COUNT" in ''|*[!0-9]*|0) COUNT=0; record_chunk_unavailable 1 page-unreadable -; return 0 ;; esac
  while [ "$index" -lt "$COUNT" ]; do
    index=$((index + 1))
    jq -c ".[$((index - 1))]" "$CHUNKS" > "$TMP_DIR/chunk.json"
    if [ -n "$STOP" ]; then
      record_chunk_unavailable "$index" "$STOP" "$TMP_DIR/chunk.json"
      continue
    fi
    subject=$REL
    [ "$COUNT" -eq 1 ] || subject="$REL#chunk-$index-of-$COUNT"
    if ! build_envelope "$REL" "$index" "$COUNT" "$TMP_DIR/chunk.json" "$subject"; then
      record_chunk_unavailable "$index" envelope-failed "$TMP_DIR/chunk.json"
      continue
    fi
    "$SCRIPT_DIR/fm-jev.sh" consult wiki-audit < "$ENVELOPE" > "$RESULT" 2>/dev/null \
      || printf '{"status":"unavailable","reason":"client-failed"}\n' > "$RESULT"
    if [ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" != available ]; then
      reason=$(jq -r '.reason // "unavailable"' "$RESULT" 2>/dev/null)
      case "$reason" in
        *call-cap|*spend-cap|ledger-unreadable) STOP=$reason ;;
        http-400|http-413) REJECTED=$reason ;;
      esac
      record_chunk_unavailable "$index" "${reason:-unavailable}" "$TMP_DIR/chunk.json"
      continue
    fi
    FLOOR=$(jq -c '.confidence_floor' "$RESULT")
    jq -c --argjson index "$index" --slurpfile chunk "$TMP_DIR/chunk.json" '
      {index:$index, first_line:$chunk[0].first_line, last_line:$chunk[0].last_line,
       bytes:($chunk[0].text | utf8bytelength), status:"answered", reason:null,
       consultation_id:.consultation_id, truncated:(.truncated // false),
       cost_usd:(.cost_usd // 0), input_tokens:(.input_tokens // 0),
       answers:(.answers | with_entries(.value = {choice:.value.choice, confidence:.value.confidence}))}
    ' "$RESULT" >> "$CHUNK_RECORDS"
  done
}

STOP=
FLOOR=null
while IFS= read -r -d '' PAGE_FILE; do
  REL=${PAGE_FILE#"$WIKI_ROOT"/}
  : > "$CHUNK_RECORDS"
  printf '[]\n' > "$RESPLITS"
  jq -Rs --argjson lines "$HEAD_LINES" --argjson head_chars "$HEAD_CHARS" --argjson outline_chars "$OUTLINE_CHARS" '
    (split("\n")) as $all |
    ($all[0:$lines] | join("\n")) as $head |
    ([$all[] | select(test("^#{1,6}[ \t]"))] | join("\n")) as $outline |
    {head:(if ($head | length) > $head_chars then $head[0:$head_chars] + "\n(head shortened)" else $head end),
     outline:(if ($outline | length) > $outline_chars then $outline[0:$outline_chars] + "\n(outline shortened)" else $outline end)}
  ' "$PAGE_FILE" > "$PAGE_STATE" 2>/dev/null || printf '{"head":"","outline":""}\n' > "$PAGE_STATE"
  PAGE_BYTES=$(LC_ALL=C wc -c < "$PAGE_FILE" | tr -d ' ')
  # The request overhead is everything except the chunk text, measured with an
  # empty chunk at the widest index this page could need.
  printf '{"text":""}\n' > "$TMP_DIR/empty.json"
  OVERHEAD=
  if build_envelope "$REL" 99999 99999 "$TMP_DIR/empty.json" "$REL"; then
    OVERHEAD=$(envelope_bytes)
  fi
  case "$OVERHEAD" in ''|*[!0-9]*) OVERHEAD=$((BUDGET + 1)) ;; esac
  ALLOWANCE=$((BUDGET - OVERHEAD))
  if [ -n "$STOP" ]; then
    record_chunk_unavailable 1 "$STOP" -
  elif [ "$ALLOWANCE" -lt "$MIN_ALLOWANCE" ]; then
    record_chunk_unavailable 1 question-block-exceeds-budget -
  else
    # A rejected chunk re-splits the whole page at half the allowance, a bounded
    # number of times; the discarded attempt stays in the page record and its
    # answered chunks' spend is still counted.
    while :; do
      : > "$CHUNK_RECORDS"
      consult_chunks "$ALLOWANCE"
      [ -n "$REJECTED" ] && [ -z "$STOP" ] || break
      [ "$(jq 'length' "$RESPLITS")" -lt "$MAX_RESPLITS" ] || break
      [ $((ALLOWANCE / 2)) -ge "$MIN_ALLOWANCE" ] || break
      jq -c --argjson allowance "$ALLOWANCE" --arg reason "$REJECTED" --slurpfile chunks <(jq -s . "$CHUNK_RECORDS") '
        . + [{allowance_bytes:$allowance, chunk_count:($chunks[0] | length), rejected:$reason,
              discarded_cost_usd:([$chunks[0][].cost_usd] | add // 0),
              discarded_input_tokens:([$chunks[0][].input_tokens] | add // 0)}]
      ' "$RESPLITS" > "$RESPLITS.tmp" && mv -f "$RESPLITS.tmp" "$RESPLITS"
      ALLOWANCE=$((ALLOWANCE / 2))
    done
  fi
  jq -s -c --arg page "$REL" --argjson bytes "${PAGE_BYTES:-0}" --argjson floor "$FLOOR" \
    --slurpfile questions "$QUESTIONS" --slurpfile resplits "$RESPLITS" '
    . as $chunks | ($questions[0] | keys) as $keys | ($chunks | length) as $n |
    ([$chunks[] | select(.status == "answered")] | length) as $answered |
    (reduce $keys[] as $k ({}; . + {($k):(
      [$chunks[] | select(.status == "answered") | {i:.index, a:.answers[$k]} | select(.a != null)] as $ans |
      [$ans[] | select(.a.choice == "yes" and $floor != null and .a.confidence >= $floor)] as $cy |
      [$ans[] | select(.a.choice == "no" and $floor != null and .a.confidence >= $floor)] as $cn |
      [$ans[] | select(.a.choice == "yes")] as $ly |
      if ($cy | length) > 0 then
        {violates:true, confidence:([$cy[].a.confidence] | max), confident:true, chunks:[$cy[].i]}
      elif ($cn | length) == $n then
        {violates:false, confidence:([$cn[].a.confidence] | min), confident:true, chunks:[]}
      elif ($ans | length) == 0 then
        {violates:null, confidence:null, confident:false, chunks:[]}
      elif ($ly | length) > 0 then
        {violates:true, confidence:([$ly[].a.confidence] | max), confident:false, chunks:[$ly[].i]}
      else
        {violates:false, confidence:([$ans[].a.confidence] | min), confident:false, chunks:[]}
      end)})) as $rules |
    {page:$page, bytes:$bytes,
     status:(if $answered == $n then "judged" elif $answered == 0 then "unavailable" else "partial" end),
     chunked:($n > 1), chunk_count:$n, confidence_floor:$floor,
     flagged:[$keys[] | select($rules[.].violates == true and $rules[.].confident)],
     not_confident:[$keys[] | select($rules[.].confident | not)],
     rules:$rules,
     resplits:$resplits[0],
     cost_usd:(([$chunks[].cost_usd] | add // 0) + ([$resplits[0][].discarded_cost_usd] | add // 0)),
     input_tokens:(([$chunks[].input_tokens] | add // 0) + ([$resplits[0][].discarded_input_tokens] | add // 0)),
     chunks:$chunks}
  ' "$CHUNK_RECORDS" >> "$RECORDS" || continue
done < <(find "$WIKI_ROOT" -path "$WIKI_ROOT/sources" -prune -o -type f -name '*.md' -print0 | LC_ALL=C sort -z)

[ -s "$RECORDS" ] || { printf 'wiki-audit: no pages found under %s\n' "$WIKI_DIR" >&2; exit 0; }

VERDICTS="$OUT_DIR/jev-verdicts.jsonl"
REPORT="$OUT_DIR/jev-report.md"
if ! cp -- "$RECORDS" "$VERDICTS.tmp.$$" || ! mv -f "$VERDICTS.tmp.$$" "$VERDICTS"; then
  rm -f "$VERDICTS.tmp.$$"
  exit 0
fi

if ! jq -s -r --arg label "${LABEL:-$WIKI_DIR}" --arg mode "$MODE" --arg rules_file "$RULES_LABEL" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --slurpfile rules_data "$RULES_FILE" '
  . as $pages | ($rules_data[0].rules) as $rules | ($rules | keys) as $keys |
  def conf: if . == null then "n/a" else (. * 100 | round / 100 | tostring) end;
  def usd: (. * 1000000 | round) as $m
    | "US$" + (($m / 1000000 | floor) | tostring) + "." + (("000000" + (($m % 1000000) | tostring))[-6:]);
  def cell: gsub("\\|"; "\\|");
  ([$pages[].chunks[]] ) as $all_chunks |
  ([$all_chunks[] | select(.status == "answered")] | length) as $answered |
  ([$pages[] | select(.status != "judged" or (.not_confident | length) > 0)]) as $unsure |
  "# Jev wiki rule audit", "",
  "- Wiki: \($label)",
  "- Generated: \($generated) in \($mode) mode with confidence floor \($pages[0].confidence_floor // "n/a")",
  "- Rule file: \($rules_file) (\($keys | length) rules)",
  "- Pages: \($pages | length), of which \([$pages[] | select(.chunked)] | length) needed more than one chunk",
  "- Consultations: \($answered) answered of \($all_chunks | length)",
  "- Spend on answered consultations: \([$pages[].cost_usd] | add // 0 | usd) for \([$pages[].input_tokens] | add // 0) input tokens",
  "",
  "Each rule asks whether the page violates it; yes is a flag. A flag is listed only when its confidence met the floor. Nothing in the wiki was changed.",
  "",
  "## Per-rule counts", "",
  "| Rule | Pages flagged | Flagged below the floor | Not judged confidently | Source |",
  "| --- | --- | --- | --- | --- |",
  ($keys[] as $k |
    "| `\($k)` | \([$pages[] | select(.rules[$k].violates == true and .rules[$k].confident)] | length)"
    + " | \([$pages[] | select(.rules[$k].violates == true and (.rules[$k].confident | not))] | length)"
    + " | \([$pages[] | select(.rules[$k].confident | not)] | length)"
    + " | \(($rules[$k].source // "") | cell) |"),
  "",
  "## Per-page flags", "",
  "| Page | Rules flagged (confidence) | Chunks |",
  "| --- | --- | --- |",
  ($pages[] as $p |
    "| \($p.page | cell) | "
    + (if ($p.flagged | length) == 0 then (if $p.status == "unavailable" then "not judged" else "none" end)
       else ([$p.flagged[] | "`\(.)` \($p.rules[.].confidence | conf)"] | join(", ")) end)
    + " | \($p.chunk_count) |"),
  "",
  "## Pages Jev could not judge confidently", "",
  (if ($unsure | length) == 0 then "None." else
    ($unsure[] as $p |
      "- \($p.page)"
      + (if $p.status != "judged" then
           " - \([$p.chunks[] | select(.status != "answered")] | length) of \($p.chunk_count) chunks unanswered ("
           + ([$p.chunks[] | select(.status != "answered") | .reason] | unique | join(", ")) + ")"
         else "" end)
      + (if ($p.not_confident | length) > 0 then
           ": " + ([$p.not_confident[] as $k | $p.rules[$k] |
             "`\($k)` " + (if .violates == null then "unanswered"
               else "\(if .violates then "yes" else "no" end) \(.confidence | conf)" end)] | join(", "))
         else "" end))
  end),
  "",
  "## Chunked pages", "",
  (if ([$pages[] | select(.chunked or ((.resplits // []) | length) > 0)] | length) == 0 then "None." else
    ($pages[] | select(.chunked or ((.resplits // []) | length) > 0) |
      "- \(.page) (\(.bytes) bytes): \(.chunk_count) chunks, lines "
      + ([.chunks[] | "\(.first_line)-\(.last_line)"] | join(", "))
      + (if ((.resplits // []) | length) > 0 then
           "; split again after the service rejected the "
           + ([.resplits[] | "\(.chunk_count)-chunk attempt (\(.rejected))"] | join(" and the "))
         else "" end))
  end),
  "",
  "## Spend", "",
  "- Answered consultations: \($answered), \([$pages[].cost_usd] | add // 0 | usd), \([$pages[].input_tokens] | add // 0) input tokens",
  "- Unanswered consultations: \(($all_chunks | length) - $answered)"
    + (if (($all_chunks | length) - $answered) > 0 then
         " (" + ([$all_chunks[] | select(.status != "answered") | .reason] | group_by(.) | map("\(.[0]) \(length)") | join(", ")) + ")"
       else "" end),
  "- Pages split again after a rejected request: \([$pages[] | select(((.resplits // []) | length) > 0)] | length); spend on answered chunks of a discarded attempt is included above",
  "- Every attempt, including failed ones, is also in the Jev ledger; `bin/fm-jev-report.sh` reads it."
' "$RECORDS" > "$REPORT.tmp.$$" 2>/dev/null || ! mv -f "$REPORT.tmp.$$" "$REPORT"; then
  rm -f "$REPORT.tmp.$$"
  exit 0
fi

jq -s -r --arg report "$REPORT" '
  "wiki-audit: \(length) pages, \([.[] | select((.flagged | length) > 0)] | length) flagged, "
  + "\([.[] | select(.status != "judged" or (.not_confident | length) > 0)] | length) not judged confidently; \($report)"
' "$RECORDS"
exit 0
