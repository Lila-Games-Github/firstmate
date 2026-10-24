#!/usr/bin/env bash
# Behavioral usage fixtures for Pi, Codex, Claude, missing usage, and summary.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-routing-ledger)
trap 'rm -rf "$LAB"' EXIT
TOOL="$ROOT/bin/fm-routing-ledger.py"
mkdir -p "$LAB/state" "$LAB/data" "$LAB/wt"
STAMP=$(date +%s)

make_meta() {
  local task=$1 harness=$2 usage=$3 model=$4
  cat > "$LAB/state/$task.meta" <<EOF
project=$LAB/project
worktree=$LAB/wt
kind=ship
mode=no-mistakes
harness=$harness
model=$model
effort=high
routing_rule=rule_1
routing_provider=codex
routing_harness=$harness
routing_model=$model
routing_effort=high
routing_started_at=$STAMP
routing_relaunches=0
usage_session_paths=$usage
EOF
}

record() {
  python3 "$TOOL" record --meta "$LAB/state/$1.meta" --state "$LAB/state" \
    --data "$LAB/data" --id "$1" --outcome landed --method pr-merge
}

cat > "$LAB/pi.jsonl" <<EOF
{"type":"session","cwd":"$LAB/wt"}
{"type":"message","id":"m1","message":{"role":"assistant","model":"deepseek-chat","usage":{"input":100,"output":20,"cost":{"total":0.004}}}}
{"type":"message","id":"m2","message":{"role":"assistant","model":"deepseek-chat","usage":{"input":50,"output":10,"cost":{"total":0.002}}}}
EOF
make_meta pi-task pi "$LAB/pi.jsonl" deepseek-chat
cat > "$LAB/state/pi-task.status" <<'EOF'
phase: validating - reviewing results
working: validation round 1 failed tests
needs-decision: clarify outcome
blocked: waiting for tool
working: stale wake recovered
working: captain correction recorded
EOF
mkdir -p "$LAB/state/learning-candidates"
printf '%s\n' '{"id":"lc-example","incident":{"origin_task":"pi-task"}}' > "$LAB/state/learning-candidates/lc-example.unresolved.json"
record pi-task
jq -e '.cost.usd_estimate == 0.006 and .cost.sessions[0].raw.dollars == 0.006
  and .validation_rounds == 1 and .failed_rounds == 1 and .needs_decision_count == 1
  and .blocked_count == 1 and .stale_wake_count == 1
  and .wall_seconds >= 0
  and .outcome.captain_corrected == true and .learning_candidates == ["lc-example"]' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "Pi runtime dollars missing"
pass "Pi dollar usage survives in ledger"

cat > "$LAB/codex.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$LAB/wt"}}
{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":100}}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":200,"output_tokens":300}}}}
EOF
make_meta codex-task codex "$LAB/codex.jsonl" gpt-6.1-sol
record codex-task
jq -e 'select(.task_id == "codex-task") | .cost.sessions[0].raw.input_tokens == 2000 and .cost.usd_estimate == 0.00662' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "Codex cumulative usage was miscounted"
pass "Codex cumulative tokens use the final total and price table"

mkdir -p "$LAB/codex-home/sessions/2026/10/25"
cp "$LAB/codex.jsonl" "$LAB/codex-home/sessions/2026/10/25/discovered.jsonl"
make_meta discovered-task codex '' gpt-6.1-sol
CODEX_HOME="$LAB/codex-home" record discovered-task
jq -e 'select(.task_id == "discovered-task") | .cost.usd_estimate == 0.00662' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "Codex session discovery missed task usage"
pass "Codex session discovery binds usage by worktree"

cat > "$LAB/claude.jsonl" <<EOF
{"type":"user","cwd":"$LAB/wt"}
{"type":"assistant","message":{"id":"a1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":10},"output_tokens":20}}}
{"type":"assistant","message":{"id":"a1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":10},"output_tokens":100}}}
EOF
make_meta claude-task claude "$LAB/claude.jsonl" claude-sonnet-4-5-20250929
record claude-task
jq -e 'select(.task_id == "claude-task") | .cost.sessions[0].raw.input_tokens == 1000
  and .cost.sessions[0].raw.cache_write_1h_tokens == 10 and .cost.usd_estimate == 0.00474' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "Claude usage or cache pricing was miscounted"
pass "Claude message ids prevent duplicate token charges"

make_meta mixed-task codex "$LAB/codex.jsonl:$LAB/pi.jsonl" gpt-6.1-sol
printf '%s\n' 'routing_harness_history=pi,codex' 'routing_relaunches=1' >> "$LAB/state/mixed-task.meta"
record mixed-task
jq -e 'select(.task_id == "mixed-task") |
  .cost.sessions | length == 2' "$LAB/data/routing-ledger.jsonl" >/dev/null \
  || fail "a later harness omitted a previously inspected session path"
jq -e 'select(.task_id == "mixed-task") |
  .cost.usd_estimate == 0.01262' "$LAB/data/routing-ledger.jsonl" >/dev/null \
  || fail "mixed runtime price conversion used the wrong harness"
pass "Relaunch across Pi and Codex includes both runtime records and pricing"

make_meta missing-task codex "$LAB/absent.jsonl" gpt-6.1-sol
printf '%s\n' 'routing_instance_id=first' >> "$LAB/state/missing-task.meta"
record missing-task
record missing-task
jq -es 'map(select(.task_id == "missing-task")) | length == 1 and .[0].cost.usd_estimate == null and .[0].cost.reason != null' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "unreadable usage was omitted or duplicated"
printf '%s\n' 'routing_instance_id=second' >> "$LAB/state/missing-task.meta"
record missing-task
jq -es 'map(select(.task_id == "missing-task")) | length == 2' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "a later task incarnation was deduplicated"
pass "Unreadable usage remains a null-cost row for each task incarnation"

make_meta rerun-task codex "$LAB/codex.jsonl" gpt-6.1-sol
printf '%s\n' 'routing_relaunches=1' >> "$LAB/state/rerun-task.meta"
record rerun-task
jq -e 'select(.task_id == "rerun-task") |
  .cost.usd_estimate == null and .cost.reason == "fewer readable sessions than launches"' \
  "$LAB/data/routing-ledger.jsonl" >/dev/null || fail "missing rerun usage was silently omitted"
pass "Missing relaunch usage prevents a complete cost estimate"

out=$(python3 "$TOOL" summary --data "$LAB/data" --from 2026-01-01 --to 2027-01-01)
printf '%s\n' "$out" | grep -F $'rule_1\t8\t1.000\t0\t5/8\t0.00662\tnull' >/dev/null \
  || fail "summary treated missing usage as zero cost"
pass "Summary groups by rule and preserves incomplete cost"
