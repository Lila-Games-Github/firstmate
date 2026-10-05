#!/usr/bin/env bash
# Read-only Playbot engine diagnostics and fail-closed dispatch via public MCP.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node "fm-playbot-engine-readiness"
TMP_ROOT=$(fm_test_tmproot fm-playbot-engine-readiness)
export FIXTURE_ROOT="$TMP_ROOT"
export PLAYBOT_DESKTOP_DIR="$TMP_ROOT/desktop"
export PLAYBOT_LANES_STATE_DIR="$TMP_ROOT/lanes"
export PLAYBOT_LANES_APP_RESOURCES="$TMP_ROOT/resources"
SCRIPT="$ROOT/bin/fm-playbot-lanes.mjs"
trap 'kill "${FAKE_CDP_PID:-}" 2>/dev/null || true; fm_test_cleanup' EXIT
mkdir -p "$PLAYBOT_DESKTOP_DIR"
node --no-warnings <<'NODE'
const fs = require('node:fs'), path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const root = process.env.FIXTURE_ROOT;
const db = new DatabaseSync(path.join(root, 'desktop/playbot.db'));
db.exec(`CREATE TABLE projects(id TEXT, name TEXT, default_working_root_id TEXT, deletion_state TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE repositories(id TEXT, name TEXT, path TEXT, default_branch TEXT);
CREATE TABLE project_roots(id TEXT, project_id TEXT, repository_id TEXT, position INTEGER);
CREATE TABLE workspaces(id TEXT, project_id TEXT, name TEXT, kind TEXT, is_selected INTEGER, archive_state TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE workspace_roots(workspace_id TEXT, project_root_id TEXT, path TEXT, branch TEXT);
CREATE TABLE workspace_threads(id TEXT,workspace_id TEXT,title TEXT,position INTEGER,is_active INTEGER,session_id TEXT,approval_mode TEXT,plan_mode INTEGER,pending_queue_json TEXT,agent_status TEXT,has_unread INTEGER,last_user_activity_at TEXT,created_at TEXT,updated_at TEXT,archived INTEGER);`);
db.prepare('INSERT INTO projects VALUES(?,?,?,?,?,?)').run('p','Game','r','active','','');
db.prepare('INSERT INTO repositories VALUES(?,?,?,?)').run('repo','Game',path.join(root,'game'),'main');
db.prepare('INSERT INTO project_roots VALUES(?,?,?,?)').run('r','p','repo',0);
db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)').run('ws','p','Main','local',1,'active','','');
db.prepare('INSERT INTO workspace_roots VALUES(?,?,?,?)').run('ws','r',path.join(root,'game'),'main');
db.exec("INSERT INTO workspace_threads VALUES('chat','ws','Validation',0,1,'session','full-access',0,NULL,'ready',0,'','','',0)");
db.close();
const bundle = path.join(root,'resources/app.asar.unpacked/electron/backend/godot-plugin/addons/playbot');
fs.mkdirSync(path.join(bundle,'native'),{recursive:true});
fs.mkdirSync(path.join(root,'resources/app'),{recursive:true});
fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.117.0'}));
fs.writeFileSync(path.join(bundle,'plugin.cfg'),'[plugin]\nversion="0.7.20"\n');
fs.writeFileSync(path.join(bundle,'plugin.gd'),'bundled code\n');
fs.writeFileSync(path.join(bundle,'native/library.so'),Buffer.from([1,2,3]));
fs.mkdirSync(path.join(root,'game'),{recursive:true});
fs.writeFileSync(path.join(root,'game/project.godot'),'config_version=5\n');
fs.cpSync(bundle,path.join(root,'game/addons/playbot'),{recursive:true});
// Binary fixture is inspected, never executed.
fs.writeFileSync(path.join(root,'godot'),Buffer.from([0x7f,0x45,0x4c,0x46,0]));
NODE
cat > "$TMP_ROOT/cdp.mjs" <<'NODE'
import fs from 'node:fs';
import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
import vm from 'node:vm';
const root = process.env.FIXTURE_ROOT;
const server = http.createServer((req,res) => {
  res.end(JSON.stringify([{type:'page',webSocketDebuggerUrl:`ws://127.0.0.1:${server.address().port}/page`}]));
});
server.on('upgrade',(req,socket) => {
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buffer = Buffer.alloc(0);
  socket.on('error',()=>{});
  socket.on('data',async data => {
    buffer = Buffer.concat([buffer,data]);
    while(buffer.length>=2) {
      if ((buffer[0]&15)===8) { socket.end(Buffer.from([0x88,0])); return; }
      let n = buffer[1]&127, off = 2;
      if(n===126) { if(buffer.length<4)return; n=buffer.readUInt16BE(2); off=4; }
      if(n===127) { if(buffer.length<10)return; n=Number(buffer.readBigUInt64BE(2)); off=10; }
      if(buffer.length<off+4+n)return;
      const mask=buffer.subarray(off,off+4), body=Buffer.from(buffer.subarray(off+4,off+4+n));
      buffer=buffer.subarray(off+4+n);
      for(let i=0;i<body.length;i++)body[i]^=mask[i%4];
      let message; try{message=JSON.parse(body);}catch{continue;}
      try {
        const value = message.method==='Runtime.evaluate' ? await vm.runInNewContext(message.params.expression,{window:{electronAPI:{invoke: async(channel,payload)=>{
          fs.appendFileSync(path.join(root,'calls'),JSON.stringify({channel,payload})+'\n');
          if(channel==='app:metadata')return {version:fs.existsSync(path.join(root,'version'))?fs.readFileSync(path.join(root,'version'),'utf8'):'0.117.0'};
          if(channel==='worktreeSettings:getRoot') {
            const defaultPath=path.join(root,'worktree-alias');
            const configuredPath=fs.existsSync(path.join(root,'worktree-root'))?fs.readFileSync(path.join(root,'worktree-root'),'utf8'):null;
            return {defaultPath,configuredPath,effectivePath:configuredPath??defaultPath,usesDefault:configuredPath===null};
          }
          if(channel==='worktreeSettings:setRoot') {
            fs.writeFileSync(path.join(root,'worktree-root'),payload.path);
            return {defaultPath:path.join(root,'worktree-alias'),configuredPath:payload.path,effectivePath:payload.path,usesDefault:false};
          }
          if(channel==='threads:send')return {pendingMessages:[],outboundMessages:[]};
          if(channel==='engine:activateProject')return;
          if(channel==='engine:installPlugin') {
            const bundle=path.join(root,'resources/app.asar.unpacked/electron/backend/godot-plugin/addons/playbot');
            fs.cpSync(bundle,path.join(payload.workspacePath,'addons/playbot'),{recursive:true});
            return {success:true};
          }
          if(channel==='engine:listWorkspaceProjects') {
            if(fs.existsSync(path.join(root,'hang-engine-read'))) return new Promise(()=>{});
            const projects=JSON.parse(fs.readFileSync(path.join(root,'engine.json'),'utf8'));
            if(fs.existsSync(path.join(root,'change-on-second'))) {
              const counter=path.join(root,'read-count');
              const n=fs.existsSync(counter)?Number(fs.readFileSync(counter,'utf8'))+1:1;
              fs.writeFileSync(counter,String(n));
              if(n>1)projects[0].snapshot={instances:[],routedInstanceId:null,connectionBlocked:false};
            }
            return projects;
          }
          throw new Error('Unexpected mutating IPC '+channel);
        }}}}) : undefined;
        const output=Buffer.from(JSON.stringify({id:message.id,result:{result:{value}}}));
        const header=output.length<126?Buffer.from([0x81,output.length]):Buffer.from([0x81,126,output.length>>8,output.length&255]);
        socket.write(Buffer.concat([header,output]));
      } catch(error) {
        const output=Buffer.from(JSON.stringify({id:message.id,result:{exceptionDetails:{text:error.message}}}));
        const header=Buffer.from([0x81,126,output.length>>8,output.length&255]);
        socket.write(Buffer.concat([header,output]));
      }
    }
  });
});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync(path.join(root,'desktop/DevToolsActivePort'),String(server.address().port)));
NODE
node --no-warnings "$TMP_ROOT/cdp.mjs" &
FAKE_CDP_PID=$!
for _ in $(seq 1 50); do
  [ -f "$PLAYBOT_DESKTOP_DIR/DevToolsActivePort" ] && break
  sleep 0.1
done
SCRIPT="$SCRIPT" node --no-warnings <<'NODE' || fail "engine diagnostic, dispatch, or addon preservation fixture failed"
const fs=require('node:fs'), path=require('node:path'), assert=require('node:assert/strict');
const {spawn,spawnSync}=require('node:child_process');
const root=process.env.FIXTURE_ROOT, game=path.join(root,'game'), bundle=path.join(root,'resources/app.asar.unpacked/electron/backend/godot-plugin/addons/playbot');
let instance={id:'session',type:'headless',status:'idle-edit',lifecycleStatus:'connected',pluginStatus:'up_to_date',pluginVersion:'0.7.20',processLogs:[`[Headless] Godot path: ${root}/godot`],processErrors:[]};
let snapshot={instances:[instance],routedInstanceId:'session',preferredInstanceType:'headless',connectionBlocked:false};
let projectPath=game;
function stage() {fs.writeFileSync(path.join(root,'engine.json'),JSON.stringify([{engineKind:'godot',projectPath,snapshot}]));}
function call(name,args={}) {
  const r=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call',name,JSON.stringify({project:'p',workspace:'ws',...args})],{encoding:'utf8',timeout:10000});
  assert.equal(r.status,0,r.stderr); return JSON.parse(r.stdout).structuredContent;
}
function expect(verdict,code) {
  stage(); const d=call('get_engine_readiness');
  assert.equal(d.verdict,verdict,JSON.stringify(d));
  if(code) assert(d.projects[0].reasons.some(r=>r.code===code),JSON.stringify(d));
  assert.equal(d.app.version,'0.117.0'); assert.equal(d.bundle.version,'0.7.20');
  return d;
}
let d=expect('ready'); assert.equal(d.projects[0].addon.byteIdentical,true);
assert(!fs.existsSync(process.env.PLAYBOT_LANES_STATE_DIR),'read-only CLI created lane state');
fs.mkdirSync(path.join(root,'worktrees')); fs.symlinkSync(path.join(root,'worktrees'),path.join(root,'worktree-alias'));
const worktreeRoot=call('get_worktree_root'); assert.equal(worktreeRoot.before.usesDefault,true);
assert(!fs.existsSync(process.env.PLAYBOT_LANES_STATE_DIR),'read-only root inspection created lane state');
const canonicalized=call('canonicalize_worktree_root',{confirm:true});
assert.equal(canonicalized.before.effectivePath,path.join(root,'worktree-alias'));
assert.equal(canonicalized.after.effectivePath,path.join(root,'worktrees'));
assert.equal(call('canonicalize_worktree_root',{confirm:true}).changed,false);
fs.writeFileSync(path.join(root,'version'),'0.124.0'); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.124.0'}));
stage(); assert.equal(call('get_engine_readiness').verdict,'ready');
fs.rmSync(path.join(game,'addons/playbot/native/library.so'));
const prepared=call('prepare_engine_workspace',{confirm:true});
assert.equal(prepared.changed,true); assert.equal(prepared.after.projects[0].addon.byteIdentical,true);
assert.equal(call('prepare_engine_workspace',{confirm:true}).changed,false);
fs.rmSync(path.join(root,'version')); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.117.0'}));
fs.writeFileSync(path.join(game,'addons/playbot/extra.gd'),'extra'); expect('ready');
assert.equal(d.projects[0].selectedExecutable.path,path.join(root,'godot'));
fs.writeFileSync(path.join(game,'addons/playbot/plugin.cfg'),'[plugin]\nversion="0.7.14"\n');
expect('addon-drift','addon-drift');
fs.copyFileSync(path.join(bundle,'plugin.cfg'),path.join(game,'addons/playbot/plugin.cfg'));
fs.rmSync(path.join(game,'addons/playbot/plugin.gd')); expect('missing-addon-files','missing-addon-files');
fs.copyFileSync(path.join(bundle,'plugin.gd'),path.join(game,'addons/playbot/plugin.gd'));
fs.writeFileSync(path.join(game,'addons/playbot/native/library.so'),'different'); expect('addon-drift','addon-drift');
fs.copyFileSync(path.join(bundle,'native/library.so'),path.join(game,'addons/playbot/native/library.so'));
instance.lifecycleStatus='starting'; instance.status='offline'; expect('startup-pending','startup-pending');
instance.lifecycleStatus='connected'; instance.status='idle-edit';
fs.writeFileSync(path.join(root,'godot'),'#!/bin/sh\nexec flatpak run org.godotengine.Godot "$@"\n');
expect('identity-admission-risk','namespace-launcher');
fs.writeFileSync(path.join(root,'godot'),Buffer.from([0x7f,0x45,0x4c,0x46,0]));
fs.symlinkSync(game,path.join(root,'alias')); projectPath=path.join(root,'alias'); expect('identity-admission-risk','project-path-alias'); projectPath=game;
snapshot.connectionBlocked=true; expect('identity-admission-risk','connection-blocked'); snapshot.connectionBlocked=false;
instance.failure={code:'registration-rejected',message:'Process identity rejected'}; expect('identity-admission-rejected','registration-rejected'); delete instance.failure;
snapshot.instances=[]; snapshot.routedInstanceId=null; expect('unconfirmed','session-unconfirmed');
// Omission is fail-closed too; no chat creation or send can precede this verdict.
for(const extra of [{},{engineDependent:true},{engineDependent:'false'}]) {
  stage(); fs.writeFileSync(path.join(root,'calls'),'');
  const r=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','dispatch',JSON.stringify({project:'p',workspace:'ws',title:'Validation',message:'Run engine tests',...extra})],{encoding:'utf8'});
  assert.notEqual(r.status,0); assert.match(r.stderr,/engineDependent|engine readiness.*unconfirmed/i);
  const calls=fs.readFileSync(path.join(root,'calls'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  assert(calls.every(c=>['app:metadata','engine:listWorkspaceProjects'].includes(c.channel)),JSON.stringify(calls));
}
snapshot.instances=[instance,instance]; snapshot.routedInstanceId='session'; expect('unconfirmed','session-unconfirmed');
snapshot.instances=[instance]; instance.processLogs=[]; expect('unconfirmed','executable-unconfirmed');
if(process.platform==='linux') {
  const executable=path.join(root,'godot-fixture');
  fs.copyFileSync(process.execPath,executable);
  const child=spawn(executable,['-e','setTimeout(()=>{},30000)','--','--headless','--path',game],{stdio:'ignore'});
  try {
    let started=false;
    for(let attempt=0;attempt<100;attempt++) {
      try {started=fs.readFileSync(`/proc/${child.pid}/cmdline`,'utf8').includes('--headless');} catch {}
      if(started)break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,10);
    }
    assert(started,'native fixture did not start');
    instance.pid=child.pid;
    const observed=expect('ready');
    assert.equal(observed.projects[0].selectedExecutable.source,'live-headless-process');
    instance.pid=process.pid; expect('unconfirmed','executable-unconfirmed');
  } finally { child.kill(); delete instance.pid; }
}
instance.processLogs=[`[Headless] Godot path: ${root}/godot`];
instance.pluginVersion='0.7.14'; expect('addon-drift','loaded-addon-drift'); instance.pluginVersion='0.7.20';
instance.failure={code:'capture-failed',message:'Capture failed'}; expect('engine-failure','engine-failure'); delete instance.failure;
// Confirmed engine work reaches exactly one send after the second diagnostic.
stage(); fs.writeFileSync(path.join(root,'calls'),'');
const sent=call('dispatch',{thread:'chat',message:'Validate Godot',engineDependent:true});
assert.equal(sent.engineReadiness.verdict,'ready'); assert.equal(sent.delivery.state,'delivered');
const calls=fs.readFileSync(path.join(root,'calls'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(calls.filter(c=>c.channel==='threads:send').length,1);
assert.equal(calls.filter(c=>c.channel==='engine:listWorkspaceProjects').length,2);
// A healthy preflight cannot cover a later unconfirmed destination read.
fs.writeFileSync(path.join(root,'change-on-second'),''); fs.writeFileSync(path.join(root,'calls'),'');
const refused=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','dispatch',JSON.stringify({project:'p',workspace:'ws',thread:'chat',message:'Validate exact engine'})],{encoding:'utf8'});
assert.notEqual(refused.status,0); assert.match(refused.stderr,/Engine readiness unconfirmed/);
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('threads:send'));
fs.rmSync(path.join(root,'change-on-second'));
fs.rmSync(path.join(game,'addons/playbot/plugin.gd'));
fs.mkdirSync(path.join(game,'addons/playbot/plugin.gd')); expect('unconfirmed','addon-unreadable');
fs.rmdirSync(path.join(game,'addons/playbot/plugin.gd'));
fs.copyFileSync(path.join(bundle,'plugin.gd'),path.join(game,'addons/playbot/plugin.gd'));
fs.writeFileSync(path.join(root,'hang-engine-read'),''); stage();
assert.equal(call('get_engine_readiness').verdict,'unconfirmed');
fs.rmSync(path.join(root,'hang-engine-read'));
fs.writeFileSync(path.join(root,'version'),'0.118.0'); fs.writeFileSync(path.join(root,'calls'),''); stage();
assert.equal(call('get_engine_readiness').verdict,'unconfirmed');
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:listWorkspaceProjects'));
// Reset/stash preservation exercises real Git, tracked helpers, untracked
// helpers, and ignored native files through the same lane executable.
fs.rmSync(path.join(root,'version'));
// Engine-dependent work never creates a workspace it could not confirm.
fs.writeFileSync(path.join(root,'calls'),'');
const fresh=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','dispatch',JSON.stringify({project:'p',landingBranch:'main',newWorkspace:{branch:'fm-engine'},title:'Engine',message:'Run engine tests'})],{encoding:'utf8'});
assert.notEqual(fresh.status,0); assert.match(fresh.stderr,/cannot target newWorkspace.*Nothing was created/);
assert.equal(fs.readFileSync(path.join(root,'calls'),'utf8'),'');
const proj=path.join(game,'prototype-game'); fs.mkdirSync(proj);
fs.renameSync(path.join(game,'project.godot'),path.join(proj,'project.godot'));
fs.renameSync(path.join(game,'addons'),path.join(proj,'addons'));
projectPath=proj; stage();
function git(...args) {
  const r=spawnSync('git',['-C',game,...args],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); return r.stdout.trim();
}
git('init','--initial-branch=main'); git('config','user.name','Fixture'); git('config','user.email','fixture@example.invalid');
fs.writeFileSync(path.join(game,'.gitignore'),'prototype-game/addons/playbot/native/\nprotected.private\n');
fs.writeFileSync(path.join(game,'product.txt'),'old');
fs.writeFileSync(path.join(proj,'addons/playbot/plugin.cfg'),'[plugin]\nversion="0.7.14"\n');
fs.writeFileSync(path.join(proj,'addons/playbot/plugin.gd'),'old');
git('add','.'); git('commit','-m','old addon and product'); const oldhead=git('rev-parse','HEAD');
fs.writeFileSync(path.join(game,'protected.private'),'landing data'); git('add','-f','protected.private');
fs.writeFileSync(path.join(game,'product.txt'),'new'); git('add','product.txt'); git('commit','-m','product advance'); const base=git('rev-parse','HEAD');
git('reset','--hard',oldhead);
fs.cpSync(bundle,path.join(proj,'addons/playbot'),{recursive:true});
fs.writeFileSync(path.join(proj,'addons/playbot/untracked-helper.gd'),'injected helper');
fs.chmodSync(path.join(proj,'addons/playbot/native/library.so'),0o755);
function guardRun(env,operation,...args) {
  const r=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard',operation,...args],{cwd:game,encoding:'utf8',timeout:10000,env:{...process.env,...env}});
  assert.equal(r.status,0,r.stderr); return {...JSON.parse(r.stdout),stderr:r.stderr};
}
const guard=(...args)=>guardRun({},...args);
fs.writeFileSync(path.join(game,'protected.private'),'unlanded private data');
const collision=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','reset',base],{cwd:game,encoding:'utf8'});
assert.notEqual(collision.status,0); assert.equal(fs.readFileSync(path.join(game,'protected.private'),'utf8'),'unlanded private data');
fs.rmSync(path.join(game,'protected.private'));
guard('reset',base); assert.equal(git('rev-parse','HEAD'),base);
expect('ready');
assert.equal(fs.readFileSync(path.join(proj,'addons/playbot/untracked-helper.gd'),'utf8'),'injected helper');
assert(fs.readFileSync(path.join(proj,'addons/playbot/native/library.so')).equals(Buffer.from([1,2,3])));
assert.equal(fs.statSync(path.join(proj,'addons/playbot/native/library.so')).mode&0o777,0o755);
fs.writeFileSync(path.join(game,'product.txt'),'unstaged product work');
guard('stash','--all'); expect('ready');
assert.equal(fs.readFileSync(path.join(game,'product.txt'),'utf8'),'new');
assert.equal(fs.readFileSync(path.join(proj,'addons/playbot/untracked-helper.gd'),'utf8'),'injected helper');
git('add','prototype-game/addons/playbot');
const staged=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','check-index'],{cwd:game,encoding:'utf8'});
assert.notEqual(staged.status,0); assert.match(staged.stderr,/staged.*addon|addon.*staged/i);
git('reset','--','prototype-game/addons/playbot'); guard('check-index');
// Listed tracked Playbot churn is disclosed and reverted; nothing else is.
fs.appendFileSync(path.join(proj,'project.godot'),'playbot_setting=1\n');
const churned=guard('reset',base);
assert.deepEqual(churned.revertedChurn,['prototype-game/project.godot']);
assert.match(churned.stderr,/Reverting listed Playbot tracked churn: prototype-game\/project\.godot[\s\S]*\+playbot_setting=1/);
assert.equal(fs.readFileSync(path.join(proj,'project.godot'),'utf8'),'config_version=5\n');
assert.equal(fs.readFileSync(path.join(proj,'addons/playbot/untracked-helper.gd'),'utf8'),'injected helper');
fs.appendFileSync(path.join(proj,'project.godot'),'playbot_setting=1\n'); fs.writeFileSync(path.join(game,'notes.txt'),'untracked product');
const mixed=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','reset',base],{cwd:game,encoding:'utf8'});
assert.notEqual(mixed.status,0); assert.match(mixed.stderr,/notes\.txt/);
assert.match(fs.readFileSync(path.join(proj,'project.godot'),'utf8'),/playbot_setting=1/);
fs.rmSync(path.join(game,'notes.txt')); git('checkout','--','prototype-game/project.godot');
// Bundle-verified preservation does not depend on the engine-IPC version pin.
fs.writeFileSync(path.join(root,'version'),'0.118.0'); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.118.0'}));
fs.writeFileSync(path.join(root,'calls'),'');
assert.deepEqual(guard('verify').addons,['prototype-game/addons/playbot']);
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:listWorkspaceProjects'));
fs.rmSync(path.join(root,'version')); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.117.0'}));
// Outside product edits and divergent refs are never authorized as addon churn.
fs.writeFileSync(path.join(game,'product.txt'),'must survive');
const refusedReset=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','reset',base],{cwd:game,encoding:'utf8'});
assert.notEqual(refusedReset.status,0); assert.equal(fs.readFileSync(path.join(game,'product.txt'),'utf8'),'must survive');
fs.writeFileSync(path.join(game,'product.txt'),'new');
fs.rmSync(path.join(proj,'addons/playbot/plugin.gd'));
const incomplete=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','reset',base],{cwd:game,encoding:'utf8'});
assert.notEqual(incomplete.status,0); assert.equal(git('rev-parse','HEAD'),base);
// A target replacing an addon ancestor with a symlink must never redirect
// restoration outside the worktree; its complete recovery backup remains.
fs.copyFileSync(path.join(bundle,'plugin.gd'),path.join(proj,'addons/playbot/plugin.gd'));
const originalHead=git('rev-parse','HEAD');
const savedAddons=path.join(root,'saved-addons'), outside=path.join(root,'outside');
fs.mkdirSync(outside); fs.writeFileSync(path.join(outside,'sentinel'),'untouched');
git('rm','-r','--cached','prototype-game/addons');
fs.renameSync(path.join(proj,'addons'),savedAddons);
fs.symlinkSync(outside,path.join(proj,'addons')); git('add','prototype-game/addons'); git('commit','-m','symlink ancestor target');
const unsafeTarget=git('rev-parse','HEAD'); git('reset','--hard',originalHead);
fs.cpSync(savedAddons,path.join(proj,'addons'),{recursive:true});
const unsafe=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','reset',unsafeTarget],{cwd:game,encoding:'utf8'});
assert.notEqual(unsafe.status,0); assert.match(unsafe.stderr,/Unsafe addon restore directory/);
assert.equal(fs.readFileSync(path.join(outside,'sentinel'),'utf8'),'untouched');
assert(!fs.existsSync(path.join(outside,'playbot')));
const backup=/complete addon backup retained at ([^\n]+)/.exec(unsafe.stderr)?.[1]; assert(backup);
assert(fs.readFileSync(path.join(backup,'0/native/library.so')).equals(Buffer.from([1,2,3])));
fs.rmSync(backup,{recursive:true});
// Without any addon tree the guard preserves nothing and needs no bundle.
git('reset','--hard',originalHead); fs.rmSync(path.join(proj,'addons'),{recursive:true,force:true});
git('rm','-r','-q','--ignore-unmatch','prototype-game/addons'); git('commit','-q','--allow-empty','-m','drop addon'); const dropped=git('rev-parse','HEAD');
fs.writeFileSync(path.join(game,'product.txt'),'later'); git('commit','-q','-am','later product'); const later=git('rev-parse','HEAD');
git('reset','--hard',dropped);
const noBundle={PLAYBOT_LANES_APP_RESOURCES:path.join(root,'missing-resources')};
assert.deepEqual(guardRun(noBundle,'verify').addons,[]);
const bare=guardRun(noBundle,'reset',later); assert.deepEqual(bare.addons,[]); assert.equal(git('rev-parse','HEAD'),later);
console.log('verified engine readiness fixture verdicts and dispatch refuses unconfirmed readiness');
NODE
pass "fm-playbot-engine-readiness: fixture verdicts and dispatch execute through public tools"
