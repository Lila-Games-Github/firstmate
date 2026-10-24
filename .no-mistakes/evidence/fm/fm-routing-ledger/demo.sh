#!/usr/bin/env bash
set -eu
TOOL=$1; L=$2; STAMP=$(date +%s)
export NM_HOME="$L/nm"; mkdir -p "$L/state" "$L/data" "$L/wt" "$L/project" "$L/nm"
meta() { cat > "$L/state/$1.meta" <<EOF
project=$L/project
worktree=$L/wt
kind=ship
mode=no-mistakes
harness=pi
model=deepseek-chat
routing_rule=$2
routing_provider=deepseek
routing_harness=pi
routing_model=deepseek-chat
routing_effort=high
routing_started_at=$STAMP
routing_relaunches=0
usage_session_paths=$L/$1.jsonl
EOF
cat > "$L/$1.jsonl" <<EOF
{"type":"session","cwd":"$L/wt"}
{"type":"message","id":"m1","message":{"role":"assistant","model":"deepseek-chat","usage":{"input":1000,"output":200,"cost":{"total":$3}}}}
EOF
printf 'working: started\nblocked: waiting for tool\n' > "$L/state/$1.status"; }
meta task-a rule_cheap 0.010; meta task-b rule_cheap 0.030; meta task-c rule_strong 0.200
echo '$ fm-routing-ledger.py record ... (3 tasks)'
python3 "$TOOL" record --meta "$L/state/task-a.meta" --state "$L/state" --data "$L/data" --id task-a --outcome landed --method pr-merge
python3 "$TOOL" record --meta "$L/state/task-b.meta" --state "$L/state" --data "$L/data" --id task-b --outcome not-landed --method discarded
python3 "$TOOL" record --meta "$L/state/task-c.meta" --state "$L/state" --data "$L/data" --id task-c --outcome landed --method local-landing
echo '$ duplicate record of task-a (should not add a row)'
python3 "$TOOL" record --meta "$L/state/task-a.meta" --state "$L/state" --data "$L/data" --id task-a --outcome landed --method pr-merge
echo "--- ledger files:"; find "$L/data" -type f
for f in $(find "$L/data" -type f -name "*.jsonl"); do echo "rows: $(wc -l < $f)"; head -1 "$f" | python3 -m json.tool; done
TODAY=$(date -u +%F)
echo "--- \$ fm-routing-ledger.py summary --from $TODAY --to $TODAY"
python3 "$TOOL" summary --data "$L/data" --state "$L/state" --from "$TODAY" --to "$TODAY"
