#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
import json, sqlite3, sys
from pathlib import Path
p=Path(sys.argv[1]); (p/'candidates').mkdir()
c=sqlite3.connect(p/'state.sqlite')
c.executescript('''CREATE TABLE runs(id TEXT,repo_id TEXT,branch TEXT,status TEXT,pr_url TEXT,created_at INT);
CREATE TABLE agent_invocations(id TEXT,run_id TEXT,step_name TEXT,round INT,purpose TEXT,agent TEXT,model TEXT,session_mode TEXT,input_tokens INT,output_tokens INT,cache_read_tokens INT,cache_creation_tokens INT,fresh_input_tokens INT,duration_ms INT,finding_count INT,started_at INT);
CREATE TABLE step_results(id TEXT,run_id TEXT,step_name TEXT);
CREATE TABLE step_rounds(id TEXT,step_result_id TEXT,round INT,findings_json TEXT,selected_finding_ids TEXT,selection_source TEXT,user_findings_json TEXT,fix_summary TEXT,reviewed_head_sha TEXT,starting_head_sha TEXT,created_at INT);''')
c.execute("INSERT INTO runs VALUES('run1','repo','branch','completed',NULL,1)")
c.execute("INSERT INTO agent_invocations VALUES('inv1','run1','review',1,'review','claude','opus','cold',100,20,0,0,100,10,1,1)")
c.execute("INSERT INTO step_results VALUES('step1','run1','review')")
finding={'findings':[{'id':'f1','file':'src/a.py','description':'A real issue','action':'auto-fix'}]}
for n in (1,2): c.execute('INSERT INTO step_rounds VALUES(?,?,?,?,?,?,?,?,?,?,?)',(str(n),'step1',n,json.dumps(finding),json.dumps(['f1']),'user',json.dumps(finding),'fix summary',None,None,n))
c.commit()
(p/'candidates'/'one.json').write_text(json.dumps({'id':'lc-one','incident':{'signal_type':'escaped-defect','project':'repo'}}))
(p/'candidates'/'other.json').write_text(json.dumps({'id':'lc-other','incident':{'signal_type':'review-rejection'}}))
(p/'cards.jsonl').write_text('\n'.join(map(json.dumps,[
    {'type':'BUG','id':'bug1','pr_url':'https://example.test/pull/1'},
    {'type':'BUG','id':'unlanded'},
    {'type':'TASK','id':'task1','pr_url':'https://example.test/pull/2'}]))+'\n')
(p/'bad.json').write_text(json.dumps({'patterns':[{'kind':'miss','pattern':'Fix PR 123 src/a.py bug','prevention':'Check src/a.py each time','owner':'reviewer-guidance','evidence':['run1','lc-one']}]}))
PY
python3 "$ROOT/bin/fm-review-lessons.py" extract --database "$TMP/state.sqlite" --candidates "$TMP/candidates" --bug-cards "$TMP/cards.jsonl" --output "$TMP/out.jsonl"
python3 - "$TMP/out.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
assert len(rows)==9, len(rows)
assert rows[0]['type']=='summary' and rows[0]['findings']==2 and rows[0]['escaped_defects']==1 and rows[0]['landed_bug_cards']==1
assert [r['re_raised_same_issue'] for r in rows if r['type']=='finding']==[False,True]
assert len([r for r in rows if r['type']=='review_invocation'])==1
assert len([r for r in rows if r['type']=='review_round'])==2
assert len([r for r in rows if r['type']=='landed_bug_card'])==1
PY
if python3 "$ROOT/bin/fm-review-lessons.py" validate "$TMP/bad.json" >"$TMP/validate.log" 2>&1; then
  echo 'instance-only playbook was accepted' >&2
  exit 1
fi
grep -q 'instance-specific' "$TMP/validate.log"
echo 'ok - extractor emits 9 named records and rejects an instance-only playbook'
