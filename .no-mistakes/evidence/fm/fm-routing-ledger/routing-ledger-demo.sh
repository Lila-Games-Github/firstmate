#!/usr/bin/env bash
# End-to-end demo: record teardown rows for three tasks under two routing rules, then run the weekly summary.
set -eu
TOOL=$1; LAB=$(mktemp -d); trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/state/learning-candidates" "$LAB/data" "$LAB/wt" "$LAB/project"
export NM_HOME="$LAB/nm"; NOW=$(date +%s)
meta() { cat > "$LAB/state/$1.meta" <<EOF
project=$LAB/project
worktree=$LAB/wt
kind=ship
harness=$2
model=$3
routing_rule=$4
routing_harness=$2
routing_model=$3
routing_started_at=$((NOW-600))
routing_relaunches=0
usage_session_paths=$5
EOF
}
cat > "$LAB/pi.jsonl" <<EOF
{"type":"session","cwd":"$LAB/wt"}
{"type":"message","id":"m1","message":{"role":"assistant","model":"deepseek-chat","usage":{"input":100,"output":20,"cost":{"total":0.004}}}}
EOF
cat > "$LAB/codex.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$LAB/wt"}}
{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":200,"output_tokens":300}}}}
EOF
meta cheap-task pi deepseek-chat rule_cheap "$LAB/pi.jsonl"
printf 'blocked: waiting for tool\nworking: stale wake recovered\n' > "$LAB/state/cheap-task.status"
meta strong-task codex gpt-6.1-sol rule_strong "$LAB/codex.jsonl"
meta lost-task codex gpt-6.1-sol rule_strong "$LAB/absent.jsonl"
echo '$ fm-routing-ledger.py record ... (as fm-teardown.sh does at cleanup)'
python3 "$TOOL" record --meta "$LAB/state/cheap-task.meta" --state "$LAB/state" --data "$LAB/data" --id cheap-task --outcome landed --method pr-merge
python3 "$TOOL" record --meta "$LAB/state/strong-task.meta" --state "$LAB/state" --data "$LAB/data" --id strong-task --outcome landed --method pr-merge
python3 "$TOOL" record --meta "$LAB/state/lost-task.meta" --state "$LAB/state" --data "$LAB/data" --id lost-task --outcome not-landed --method unknown
echo; echo '--- data/routing-ledger.jsonl (key fields) ---'
jq -c '{task_id, routing_rule: (.routing.rule // .routing_rule), outcome, cost: {usd_estimate: .cost.usd_estimate, reason: .cost.reason}, blocked_count, stale_wake_count, wall_seconds, validation_rounds, pipeline_reason: .pipeline.reason}' "$LAB/data/routing-ledger.jsonl"
echo; echo '--- a captain correction captured AFTER teardown for strong-task ---'
printf '{"id":"lc-1","captured_at":"%s","incident":{"origin_task":"strong-task","signal_type":"captain-correction"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LAB/state/learning-candidates/lc-1.unresolved.json"
echo '$ fm-routing-ledger.py summary --data data --state state --from <week start> --to <week end>'
python3 "$TOOL" summary --data "$LAB/data" --state "$LAB/state" --from "$(date -u -d '-7 day' +%F)" --to "$(date -u -d '+1 day' +%F)" | column -t -s $'\t'
