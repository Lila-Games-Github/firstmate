#!/usr/bin/env bash
# Hermetic end-to-end poll cases against fixture GitHub, Playbot DB, and lane IPC.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node "fm-playbot-ci-autofix"
T=$(fm_test_tmproot fm-playbot-ci-autofix)
mkdir -p "$T/bin" "$T/home/state" "$T/desktop" "$T/worktree"
export FM_HOME="$T/home" PLAYBOT_DESKTOP_DIR="$T/desktop"
export FM_PLAYBOT_CI_AUTOFIX_LANES="$T/lanes.mjs" FM_CI_FIXTURE="$T/fixture.json" FM_CI_CALLS="$T/calls.log"
export FM_CI_DB="$T/desktop/playbot.db" FM_CI_WORKTREE="$T/worktree"
git -C "$T/worktree" init -q
git -C "$T/worktree" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m first
export FM_CI_HEAD=$(git -C "$T/worktree" rev-parse HEAD)
cat > "$T/bin/gh-axi" <<'SH'
#!/usr/bin/env node
const fs=require('fs');
const fixture=JSON.parse(fs.readFileSync(process.env.FM_CI_FIXTURE));
const endpoint=process.argv[3].replace(/^repos\/Lila-Games-Github\/frogpile\//,'');
const value=fixture[endpoint];
if(value===undefined){process.stderr.write('missing fixture '+endpoint+'\n');process.exit(1)}
process.stdout.write('api_response:\n  body: '+Buffer.from(JSON.stringify(value)).toString('base64')+'\n  truncated: false\n');
SH
chmod +x "$T/bin/gh-axi"
export PATH="$T/bin:$PATH"
cat > "$T/lanes.mjs" <<'JS'
import fs from 'node:fs';
const [name,encoded]=process.argv.slice(3),args=JSON.parse(encoded);
fs.appendFileSync(process.env.FM_CI_CALLS,JSON.stringify({name,args})+'\n');
if(name==='adopt_pr') console.log(JSON.stringify({structuredContent:{taskId:`frogpile-playbot-pr-${args.pullRequestNumber}`,adopted:true}}));
else if(name==='launch_fix_checks') console.log(JSON.stringify({structuredContent:{mechanism:'git-actions:launch',thread:{id:'fix-'+args.expectedHead.slice(0,8)}}}));
else process.exit(2);
JS
node --no-warnings <<'JS'
const {DatabaseSync}=require('node:sqlite');
const d=new DatabaseSync(process.env.FM_CI_DB);
d.exec("CREATE TABLE projects(id TEXT,deletion_state TEXT); CREATE TABLE repositories(id TEXT,remote_url TEXT); CREATE TABLE project_roots(id TEXT,project_id TEXT,repository_id TEXT); CREATE TABLE workspaces(id TEXT,archive_state TEXT); CREATE TABLE workspace_roots(workspace_id TEXT,project_root_id TEXT,branch TEXT,path TEXT,pull_request_number INTEGER); CREATE TABLE workspace_threads(id TEXT,workspace_id TEXT,title TEXT,agent_status TEXT,archived INTEGER,ephemeral INTEGER)");
d.prepare('INSERT INTO projects VALUES (?,?)').run('project','active');
d.prepare('INSERT INTO repositories VALUES (?,?)').run('repo','https://github.com/Lila-Games-Github/frogpile.git');
d.prepare('INSERT INTO project_roots VALUES (?,?,?)').run('root','project','repo');
d.prepare('INSERT INTO workspaces VALUES (?,?)').run('workspace','active');
d.prepare('INSERT INTO workspace_roots VALUES (?,?,?,?,?)').run('workspace','root','fix/fixture',process.env.FM_CI_WORKTREE,41);
JS
fixture() {
  FM_CI_CASE=$1 node <<'JS'
const fs=require('fs');
const head=process.env.FM_CI_HEAD,kind=process.env.FM_CI_CASE;
const number=41,url='https://github.com/Lila-Games-Github/frogpile/pull/41';
const x={
 'pulls?state=open&per_page=100':[{number,url,title:'ET-725: fix fixture',branch:'fix/fixture',head,base:'development'}],
 'pulls/41':{number,mergeable:kind!=='conflict',mergeable_state:kind==='conflict'?'dirty':'clean',draft:false,base:'development',head},
 [`commits/${head}/status`]:{state:'success',statuses:[]},
};
let checks=[];
if(kind==='stale') checks=[{name:'quick checks',conclusion:null,status:'queued',started_at:'2020-01-01T00:00:00Z',details_url:null}];
else if(kind!=='ready') checks=[{name:kind==='infra'?'quick checks':'docs and description',conclusion:'failure',status:'completed',details_url:'https://github.com/Lila-Games-Github/frogpile/actions/runs/1/job/2'}];
x[`commits/${head}/check-runs?per_page=100`]={total_count:checks.length||1,checks:checks.length?checks:[{name:'docs and description',conclusion:'success',status:'completed',details_url:null}]};
if(checks.length && kind!=='stale')x['actions/jobs/2']={name:checks[0].name,conclusion:'failure',status:'completed',steps:[{name:kind==='infra'?'Upload artifact':'Validate docs and description',conclusion:'failure'}]};
fs.writeFileSync(process.env.FM_CI_FIXTURE,JSON.stringify(x));
JS
}
poll() { node --no-warnings "$ROOT/bin/fm-playbot-ci-autofix.mjs" poll > "$T/out" 2> "$T/report"; }
fixture own
poll
[ "$(rg -c '"name":"launch_fix_checks"' "$T/calls.log")" = 1 ] || fail 'own-code failure did not launch exactly once'
poll
[ "$(rg -c '"name":"launch_fix_checks"' "$T/calls.log")" = 1 ] || fail 'same head launched twice'
pass 'own-code failure adopts and launches once per head'

# A running fix chat blocks another head even when the first attempt completed.
git -C "$T/worktree" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m second
export FM_CI_HEAD=$(git -C "$T/worktree" rev-parse HEAD)
fixture own
node --no-warnings <<'JS'
const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.env.FM_CI_DB);
d.prepare('INSERT INTO workspace_threads VALUES (?,?,?,?,?,?)').run('inflight','workspace','Fix failing CI checks for pull request #41, verify the fix, commit it, and push the branch','working',0,1);
JS
poll
[ "$(rg -c '"name":"launch_fix_checks"' "$T/calls.log")" = 1 ] || fail 'in-flight fix did not block a new head'
pass 'in-flight fix chat blocks dispatch'
node --no-warnings <<'JS'
const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync(process.env.FM_CI_DB);d.exec('DELETE FROM workspace_threads');
JS
poll
[ "$(rg -c '"name":"launch_fix_checks"' "$T/calls.log")" = 2 ] || fail 'second round was not launched'
poll
rg -q 'two failed Fix CI checks rounds' "$T/out" || fail 'second same-head failure did not wake the stop'
git -C "$T/worktree" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m third
export FM_CI_HEAD=$(git -C "$T/worktree" rev-parse HEAD)
fixture own
poll
rg -q 'two failed Fix CI checks rounds' "$T/out" || fail 'two-round stop did not wake'
[ "$(rg -c '"name":"launch_fix_checks"' "$T/calls.log")" = 2 ] || fail 'third round was launched'
pass 'two failed rounds stop and wake'

fixture infra
poll
rg -q 'infrastructure or unknown CI failure' "$T/out" || fail 'infrastructure did not wake'
pass 'infrastructure failure wakes without dispatch'
fixture stale
poll
rg -q 'check queued over 30 minutes' "$T/out" || fail 'stale queued check did not wake'
pass 'check queued too long wakes as infrastructure'
fixture conflict
poll
rg -q 'merge conflict with development' "$T/out" || fail 'conflict did not wake'
pass 'merge conflict wakes'
fixture ready
poll
rg -q 'ready-to-merge' "$T/out" || fail 'green head did not wake ready'
pass 'green current head wakes ready-to-merge'

# A malformed GitHub response must fail closed, rather than yield an empty poll.
cat > "$T/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api_response:\n  body: e30=\n  truncated: true\n'
SH
chmod +x "$T/bin/gh-axi"
if poll; then fail 'truncated GitHub fixture was accepted'; fi
rg -q 'missing or truncated' "$T/report" || fail 'bad fixture refusal not explained'
pass 'known-bad truncated source fixture is rejected'
node --no-warnings "$ROOT/bin/fm-playbot-ci-autofix.mjs" arm > "$T/arm.out" || fail 'watcher arm failed'
[ -x "$FM_HOME/state/playbot-ci-autofix.check.sh" ] || fail 'watcher check was not installed'
[ -f "$FM_HOME/state/playbot-ci-autofix.check-trust" ] || fail 'watcher check was not hash-registered'
pass 'watcher check installs through the supported registration helper'
