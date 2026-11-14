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
// An unreachable bridge exposes no renderer at all, which is the fault distinct
// from a channel that answered and a contract that changed.
const server = http.createServer((req,res) => {
  if(fs.existsSync(path.join(root,'bridge-down')))return res.end('[]');
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
          if(channel==='engine:controlInstance') {
            if(payload.action!=='reset'||payload.instanceType!=='headless'||payload.workspacePath!==path.join(root,'game/prototype-game')) throw new Error('Unexpected engine cache reset target');
            return {success:true};
          }
          if(channel==='engine:listWorkspaceProjects') {
            if(fs.existsSync(path.join(root,'engine-no-handler')))throw new Error("No handler registered for 'engine:listWorkspaceProjects'");
            if(fs.existsSync(path.join(root,'engine-shape')))return [{engineKind:'godot'}];
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
// The live bridge, the classified IPC contract, the engine handshake for the
// exact project path, and the capture capability are four separate readings.
assert.equal(d.ipc.bridge.status,'reachable');
assert.equal(d.ipc.contract.status,'version-verified');
assert.equal(d.ipc.contract.channel,'engine:listWorkspaceProjects');
assert.equal(d.projects[0].bridge.status,'connected');
assert.equal(d.projects[0].bridge.projectPath,game);
assert.equal(d.projects[0].graphicalCapture.status,'unavailable');
assert.equal(d.projects[0].graphicalCapture.reason,'headless-display-driver');
// A session that is not headless cannot be proven to capture either, because
// this read-only diagnostic attempts no capture; it stays unproven, never available.
instance.type='editor'; stage(); const nonHeadless=call('get_engine_readiness');
assert.equal(nonHeadless.projects[0].graphicalCapture.status,'unproven');
assert.equal(nonHeadless.projects[0].graphicalCapture.reason,'capture-not-attempted');
instance.type='headless';
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
fs.writeFileSync(path.join(root,'version'),'0.129.0'); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.129.0'}));
stage();
const current=call('get_engine_readiness');
assert.equal(current.verdict,'ready'); assert.equal(current.app.version,'0.129.0');
assert.equal(current.app.verifiedVersions,'0.117.0, 0.124.0, and 0.129.0');
assert.equal(current.projects[0].addon.byteIdentical,true);
fs.writeFileSync(path.join(root,'version'),'0.145.0'); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.145.0'}));
fs.rmSync(path.join(game,'addons/playbot/native/library.so'));
const currentPrepared=call('prepare_engine_workspace',{confirm:true});
const sourceProjectCount=JSON.parse(fs.readFileSync(path.join(root,'engine.json'),'utf8')).length;
assert.equal(sourceProjectCount,1);
assert.equal(currentPrepared.before.projects.length,1); assert.equal(currentPrepared.after.projects.length,1);
assert.equal(currentPrepared.after.projects[0].addon.byteIdentical,true);
console.log(`prepare_engine_workspace: source Godot projects=${sourceProjectCount}, observed projects before=${currentPrepared.before.projects.length} after=${currentPrepared.after.projects.length}, missing native files installed=${currentPrepared.before.projects[0].addon.missingFiles.length}`);
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
// Rendered editor evidence is a capability separate from engine execution: a
// headless session runs code but refuses screenshots, so a task that needs the
// screenshots is refused before any chat exists rather than at review.
for(const extra of [{requiresGraphicalCapture:true},{engineDependent:true,requiresGraphicalCapture:true}]) {
  stage(); fs.writeFileSync(path.join(root,'calls'),'');
  const r=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','dispatch',JSON.stringify({project:'p',workspace:'ws',title:'Capture',message:'Capture the editor',...extra})],{encoding:'utf8'});
  assert.notEqual(r.status,0); assert.match(r.stderr,/Graphical capture is unavailable[\s\S]*headless-display-driver/);
  const attempted=fs.readFileSync(path.join(root,'calls'),'utf8');
  assert(!attempted.includes('threads:launch')&&!attempted.includes('threads:send'),attempted);
}
for(const extra of [{engineDependent:false,requiresGraphicalCapture:true},{requiresGraphicalCapture:'true'}]) {
  const r=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','dispatch',JSON.stringify({project:'p',workspace:'ws',title:'Capture',message:'Capture the editor',...extra})],{encoding:'utf8'});
  assert.notEqual(r.status,0); assert.match(r.stderr,/requiresGraphicalCapture (needs the engine readiness read|must be a boolean)/);
}
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
// A reachable bridge whose engine call never answered is its own status, so a
// stalled read never reads as an unreachable bridge or a changed contract.
fs.writeFileSync(path.join(root,'hang-engine-read'),''); stage();
const stalled=call('get_engine_readiness');
assert.equal(stalled.verdict,'unconfirmed');
assert.equal(stalled.ipc.bridge.status,'reachable');
assert.equal(stalled.ipc.contract.status,'call-failed');
fs.rmSync(path.join(root,'hang-engine-read'));
// The engine snapshot IPC contract is classified by capability, never by an
// app-version allowlist. An allowlist stranded engine-dependent lanes on the
// next Playbot upgrade until someone extended it, so an unlisted version whose
// channel answers with the readable contract is admitted on that probe alone.
fs.writeFileSync(path.join(root,'version'),'0.118.0'); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.118.0'}));
fs.writeFileSync(path.join(root,'calls'),''); stage();
const unlisted=call('get_engine_readiness');
assert.equal(unlisted.verdict,'ready',JSON.stringify(unlisted));
assert.equal(unlisted.ipc.contract.status,'capability-verified');
assert.equal(unlisted.ipc.contract.observedVersion,'0.118.0');
assert.match(unlisted.ipc.contract.detail,/not on the verified list/);
assert(fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:listWorkspaceProjects'));
fs.rmSync(path.join(root,'version')); fs.writeFileSync(path.join(root,'resources/app/package.json'),JSON.stringify({version:'0.117.0'}));
// A channel Playbot no longer registers is named rather than guessed at.
fs.writeFileSync(path.join(root,'engine-no-handler'),''); stage();
const missingChannel=call('get_engine_readiness');
assert.equal(missingChannel.verdict,'unconfirmed');
assert.equal(missingChannel.ipc.contract.status,'channel-missing');
assert.equal(missingChannel.ipc.bridge.status,'reachable');
assert.match(missingChannel.ipc.contract.detail,/does not register engine:listWorkspaceProjects/);
fs.rmSync(path.join(root,'engine-no-handler'));
// A channel that answers with an unreadable shape is a changed contract.
fs.writeFileSync(path.join(root,'engine-shape'),''); stage();
const changedShape=call('get_engine_readiness');
assert.equal(changedShape.verdict,'unconfirmed');
assert.equal(changedShape.ipc.contract.status,'shape-changed');
fs.rmSync(path.join(root,'engine-shape'));
// An unreachable bridge is a different fault from a changed contract, and it
// leaves the contract unclassified rather than mislabelled.
fs.writeFileSync(path.join(root,'bridge-down'),''); stage();
const downBridge=call('get_engine_readiness');
assert.equal(downBridge.verdict,'unconfirmed');
assert.equal(downBridge.ipc.bridge.status,'unreachable');
assert.equal(downBridge.ipc.contract.status,'unprobed');
fs.rmSync(path.join(root,'bridge-down'));
// Reset/stash preservation exercises real Git, tracked helpers, untracked
// helpers, and ignored native files through the same lane executable.
fs.rmSync(path.join(root,'version'),{force:true});
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
git('add','.'); git('commit','-m','complete engine project');
const engineHead=git('rev-parse','HEAD');
assert.equal(JSON.parse(fs.readFileSync(path.join(root,'engine.json'),'utf8')).length,sourceProjectCount);
fs.writeFileSync(path.join(root,'calls'),'');
const reset=call('reset_engine_workspace_cache',{expectedHead:engineHead,confirm:true});
assert.equal(reset.head,engineHead); assert.equal(reset.workspaceId,'ws');
assert.equal(reset.before.projects.length,1); assert.equal(reset.after.projects.length,1);
assert.equal(reset.ready,true);
const resetCalls=fs.readFileSync(path.join(root,'calls'),'utf8').trim().split('\n').map(JSON.parse);
assert.equal(resetCalls.filter(row=>row.channel==='engine:controlInstance').length,1);
assert.deepEqual(resetCalls.find(row=>row.channel==='engine:controlInstance').payload,{action:'reset',instanceType:'headless',workspacePath:proj});
fs.writeFileSync(path.join(root,'calls'),'');
let refusedCache=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','reset_engine_workspace_cache',JSON.stringify({project:'p',workspace:'ws',expectedHead:'0'.repeat(40),confirm:true})],{encoding:'utf8'});
assert.notEqual(refusedCache.status,0); assert.match(refusedCache.stderr,/differs from expectedHead/);
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:controlInstance'));
fs.writeFileSync(path.join(proj,'project.godot'),'dirty\n');
refusedCache=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','reset_engine_workspace_cache',JSON.stringify({project:'p',workspace:'ws',expectedHead:engineHead,confirm:true})],{encoding:'utf8'});
assert.notEqual(refusedCache.status,0); assert.match(refusedCache.stderr,/uncommitted tracked changes/);
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:controlInstance'));
git('checkout','--','prototype-game/project.godot');
instance.type='interactive'; stage();
refusedCache=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'call','reset_engine_workspace_cache',JSON.stringify({project:'p',workspace:'ws',expectedHead:engineHead,confirm:true})],{encoding:'utf8'});
assert.notEqual(refusedCache.status,0); assert.match(refusedCache.stderr,/only supports a headless session/);
assert(!fs.readFileSync(path.join(root,'calls'),'utf8').includes('engine:controlInstance'));
instance.type='headless'; stage();
console.log(`reset_engine_workspace_cache: registered roots=1, source Godot projects=${sourceProjectCount}, observed projects before=${reset.before.projects.length} after=${reset.after.projects.length}, reset IPC calls=${resetCalls.filter(row=>row.channel==='engine:controlInstance').length}; bad SHA, dirty tree, and interactive session rejected`);
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
guard('remote-checkout','main',oldhead); assert.equal(git('rev-parse','HEAD'),oldhead);
assert.equal(fs.readFileSync(path.join(proj,'addons/playbot/plugin.gd'),'utf8'),'bundled code\n');
guard('remote-checkout','main',base); assert.equal(git('rev-parse','HEAD'),base);
assert.equal(fs.readFileSync(path.join(proj,'addons/playbot/untracked-helper.gd'),'utf8'),'injected helper');
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
const unverifiedTarget=spawnSync(process.execPath,['--no-warnings',process.env.SCRIPT,'addon-guard','remote-checkout','main',oldhead],{cwd:game,encoding:'utf8',env:{...process.env,...noBundle}});
assert.notEqual(unverifiedTarget.status,0); assert.match(unverifiedTarget.stderr,/no verified addon/); assert.equal(git('rev-parse','HEAD'),dropped);
const bare=guardRun(noBundle,'reset',later); assert.deepEqual(bare.addons,[]); assert.equal(git('rev-parse','HEAD'),later);
console.log('verified engine readiness fixture verdicts and dispatch refuses unconfirmed readiness');
NODE
pass "fm-playbot-engine-readiness: fixture verdicts and dispatch execute through public tools"

# Keep the companion-import regression with its existing engine/addon owner.
# The child has an independent fixture/cleanup scope and no DevTools endpoint.
bash -s -- "$ROOT" <<'LANE_IMPORT_TEST'
#!/usr/bin/env bash
# Owned lane-import CLI with real Git worktrees and a fake Godot only.
set -eu
# shellcheck source=tests/lib.sh
. "$1/tests/lib.sh"
fm_test_require_node "fm-playbot-lane-import"
case "$(uname -s)" in Linux) ;; *) echo "skip: Linux lane-import runtime required"; exit 0 ;; esac
TMP_ROOT=$(fm_test_tmproot fm-playbot-lane-import)
export FIXTURE_ROOT="$TMP_ROOT"
export PLAYBOT_DESKTOP_DIR="$TMP_ROOT/desktop"
export IMPORT_SCRIPT="$ROOT/bin/fm-playbot-lanes.mjs"
trap 'fm_test_cleanup' EXIT
mkdir -p "$PLAYBOT_DESKTOP_DIR"
# No DevTools endpoint exists: successful imports prove the command never
# requires app/engine IPC, a connected engine session, or Playbot lifecycle.
# argv/environment-driven fake editor models imports, not engine readiness.
cat > "$TMP_ROOT/godot" <<'NODE'
#!/usr/bin/env node
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const root=process.env.FIXTURE_ROOT,mode=fs.existsSync(root+'/mode')?fs.readFileSync(root+'/mode','utf8'):'success';
const args=process.argv.slice(2);
fs.appendFileSync(root+'/engine-calls',JSON.stringify(args)+'\n');
if(args[0]==='--version'){console.log(mode==='version'?'4.6.1.stable.official.abc123':'4.7.1.stable.official.abc123');process.exit(0);}
if(args[0]==='--help'){console.log('--headless --recovery-mode --import --path');process.exit(0);}
const expected=['--headless','--recovery-mode','--import','--path'];
if(args.length!==5||!expected.every((x,i)=>args[i]===x))throw Error('unsafe import arguments');
if(!process.env.XDG_CONFIG_HOME.includes('fm-lane-import-')||fs.readdirSync(process.env.ANDROID_HOME).length||process.env.ANDROID_HOME===process.env.HOSTILE_SDK)throw Error('host SDK/settings leaked');
if(process.env.ADB_SERVER_SOCKET||process.env.GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD)throw Error('host ADB/credential environment leaked');
fs.appendFileSync(root+'/imports',args[4]+'\n');
const project=args[4],repo=path.dirname(project);
fs.mkdirSync(project+'/.godot/imported',{recursive:true});
fs.writeFileSync(project+'/.godot/imported/cache','ignored cache');
const uid=mode==='malformed'?'handcrafted garbage\n':'uid://abc123\n';
fs.writeFileSync(project+'/new.gd.uid',uid);
fs.writeFileSync(project+'/art.png.import','[remap]\nimporter="texture"\nuid="uid://asset123"\n\n[deps]\nsource_file="res://art.png"\n\n[params]\n');
if(mode==='source')fs.writeFileSync(project+'/new.gd','unexpected source mutation\n');
if(mode==='unrelated')fs.writeFileSync(repo+'/unexpected.txt','unexpected product output\n');
if(mode==='addon')fs.writeFileSync(project+'/addons/playbot/plugin.gd','unexpected addon mutation\n');
if(mode==='second-pass'&&fs.readFileSync(root+'/imports','utf8').trim().split('\n').length>1)fs.writeFileSync(project+'/new.gd.uid','uid://changed456\n');
if(mode==='lock-drift'){const lock=cp.execFileSync('git',['-C',repo,'rev-parse','--path-format=absolute','--git-path','index.lock'],{encoding:'utf8'}).trim();fs.renameSync(lock,lock+'.displaced');fs.writeFileSync(lock,'foreign lock owner');}
if(mode==='head-drift')cp.execFileSync('git',['-C',repo,'update-ref','HEAD',fs.readFileSync(root+'/base','utf8').trim()]);
if(mode==='failed')process.exit(7);
NODE
chmod +x "$TMP_ROOT/godot"
node --no-warnings <<'NODE'
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const {DatabaseSync}=require('node:sqlite');
const root=process.env.FIXTURE_ROOT,script=process.env.IMPORT_SCRIPT;
const db=new DatabaseSync(path.join(root,'desktop/playbot.db'));
db.exec(`CREATE TABLE projects(id TEXT,name TEXT,default_working_root_id TEXT,deletion_state TEXT,created_at TEXT,updated_at TEXT);
CREATE TABLE repositories(id TEXT,name TEXT,path TEXT,default_branch TEXT);
CREATE TABLE project_roots(id TEXT,project_id TEXT,repository_id TEXT,position INTEGER);
CREATE TABLE workspaces(id TEXT,project_id TEXT,name TEXT,kind TEXT,is_selected INTEGER,archive_state TEXT,created_at TEXT,updated_at TEXT);
CREATE TABLE workspace_roots(workspace_id TEXT,project_root_id TEXT,path TEXT,branch TEXT);`);
const bundle=path.join(root,'bundle');
fs.mkdirSync(bundle+'/native',{recursive:true});
fs.writeFileSync(bundle+'/plugin.cfg','[plugin]\nversion="0.9"\n');fs.writeFileSync(bundle+'/plugin.gd','bundled addon\n');fs.writeFileSync(bundle+'/native/helper.so','native bytes');
let serial=0;
function git(repo,...args){const r=cp.spawnSync('git',['-C',repo,...args],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return r.stdout.trim();}
function fixture(large=false){
  serial++;const main=root+'/main'+serial,repo=root+'/lane'+serial,branch='playbot/wave-three-'+serial;
  fs.mkdirSync(main);git(main,'init','-q','-b','main');git(main,'config','user.name','Fixture');git(main,'config','user.email','fixture@example.invalid');
  fs.mkdirSync(main+'/prototype-game',{recursive:true});
  fs.writeFileSync(main+'/.gitignore','prototype-game/.godot/\nprototype-game/addons/playbot/native/\nprototype-game/tests/task_evidence/\nprototype-game/private.env\n');
  fs.writeFileSync(main+'/prototype-game/project.godot','config_version=5\n');
  if(large){
    fs.mkdirSync(main+'/prototype-game/docs',{recursive:true});
    fs.writeFileSync(main+'/prototype-game/docs/large.bin',Buffer.alloc(17*1024*1024,0x61));
  }
  fs.mkdirSync(main+'/prototype-game/android/build',{recursive:true});
  fs.writeFileSync(main+'/prototype-game/android/build/gradlew','#!/bin/sh\nexit 0\n',{mode:0o755});
  fs.mkdirSync(main+'/scripts');
  fs.writeFileSync(main+'/scripts/check_guide_compliance.py','# fixture dependency\n');
  fs.writeFileSync(main+'/scripts/guide_submission_checks.py','# fixture dependency\n');
  fs.writeFileSync(main+'/scripts/check_import_clean.py',`import json, pathlib, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[1]
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
if (root.parent/'mode').read_text()=='gate-no-receipt': sys.exit(0)
subprocess.run(sys.argv[2:],cwd=root,check=True)
receipt=root/'prototype-game/.godot/automation-data/guide-checks/import.json'
receipt.parent.mkdir(parents=True,exist_ok=True)
receipt.write_text(json.dumps(dict(schema='frogpile.import-clean.v1',sha=head,exit_code=0,unchanged=True)))
`);
  fs.writeFileSync(main+'/outside.txt','committed\n');fs.writeFileSync(main+'/unstaged.txt','committed\n');
  fs.cpSync(bundle,main+'/prototype-game/addons/playbot',{recursive:true});
  git(main,'add','.');git(main,'commit','-qm','base');const base=git(main,'rev-parse','HEAD');git(main,'branch','proto/godot/frog-pile',base);
  git(main,'worktree','add','-q','-b',branch,repo,'HEAD');
  fs.writeFileSync(repo+'/prototype-game/new.gd','extends RefCounted\n');fs.writeFileSync(repo+'/prototype-game/art.png','fixture asset bytes\n');
  git(repo,'add','prototype-game/new.gd','prototype-game/art.png');git(repo,'commit','-qm','task sources\n\nGuide-check-base: '+base);
  const head=git(repo,'rev-parse','HEAD');fs.cpSync(bundle,repo+'/prototype-game/addons/playbot',{recursive:true});
  fs.writeFileSync(repo+'/prototype-game/addons/playbot/untracked.gd','injected helper\n');
  fs.mkdirSync(repo+'/prototype-game/tests/task_evidence',{recursive:true});fs.writeFileSync(repo+'/prototype-game/tests/task_evidence/inventory.txt','ignored evidence\n');fs.writeFileSync(repo+'/prototype-game/private.env','private fixture credentials\n');
  fs.writeFileSync(repo+'/outside.txt','staged work\n');git(repo,'add','outside.txt');fs.writeFileSync(repo+'/outside.txt','staged plus unstaged work\n');fs.writeFileSync(repo+'/unstaged.txt','unstaged work\n');
  const project='p'+serial,workspace='ws'+serial;
  db.prepare('INSERT INTO projects VALUES(?,?,?,?,?,?)').run(project,project,'r'+serial,'active','','');
  db.prepare('INSERT INTO repositories VALUES(?,?,?,?)').run('repo'+serial,project,main,'main');
  db.prepare('INSERT INTO project_roots VALUES(?,?,?,?)').run('r'+serial,project,'repo'+serial,0);
  db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)').run(workspace,project,workspace,'worktree',0,'active','','');
  db.prepare('INSERT INTO workspace_roots VALUES(?,?,?,?)').run(workspace,'r'+serial,repo,branch);
  const args={project,workspace,expectedBranch:branch,expectedHead:head,base,landingBranch:'proto/godot/frog-pile',godotProject:'prototype-game',godot:root+'/godot',companions:['prototype-game/new.gd.uid','prototype-game/art.png.import']};
  const index=git(repo,'rev-parse','--path-format=absolute','--git-path','index');
  fs.writeFileSync(root+'/mode','success');fs.writeFileSync(root+'/base',base);fs.writeFileSync(root+'/imports','');fs.writeFileSync(root+'/engine-calls','');
  return {repo,main,branch,head,base,index,args,indexBefore:fs.readFileSync(index),staged:git(repo,'diff','--cached','--','outside.txt')};
}
function run(f,extra={},mode='success',cwd=f.repo){
  fs.writeFileSync(root+'/mode',mode);
  return cp.spawnSync(process.execPath,['--no-warnings',script,'lane-import',JSON.stringify({...f.args,...extra})],{cwd,encoding:'utf8',env:{...process.env,ANDROID_HOME:'/unusable-host-sdk',ANDROID_SDK_ROOT:'/unusable-host-sdk',ADB_SERVER_SOCKET:'tcp:host:5037',GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD:'never-in-child'}});
}
function reject(f,extra,pattern,mode='success',cwd=f.repo){const r=run(f,extra,mode,cwd);assert.notEqual(r.status,0,r.stdout);assert.match(r.stderr,pattern);assert.equal(git(f.repo,'rev-parse','HEAD'),f.head);assert(fs.readFileSync(f.index).equals(f.indexBefore));return r;}
let f=fixture();
reject(f,{expectedHead:'0'.repeat(40)},/branch\/head differs/);
reject(f,{expectedBranch:'fm/wrong'},/branch\/head differs/);
reject(f,{workspace:'absent'},/active lane workspace/);
reject(f,{},/canonical registered lane root/,'success',f.repo+'/prototype-game');
reject(f,{},/version mismatch/,'version');assert.equal(fs.readFileSync(root+'/imports','utf8'),'');
reject(f,{companions:['outside.txt']},/not authorized/);
reject(f,{companions:['prototype-game/addons/playbot/plugin.gd.uid']},/not authorized/);
reject(f,{base:'0'.repeat(40)},/base differs from merge-base/);
fs.writeFileSync(f.repo+'/prototype-game/new.gd','uncommitted work\n');reject(f,{},/differs from committed head/);fs.writeFileSync(f.repo+'/prototype-game/new.gd','extends RefCounted\n');
fs.writeFileSync(f.repo+'/prototype-game/untracked.gd','preserve\n');reject(f,{},/untracked product work/);assert.equal(fs.readFileSync(f.repo+'/prototype-game/untracked.gd','utf8'),'preserve\n');fs.unlinkSync(f.repo+'/prototype-game/untracked.gd');
git(f.repo,'update-index','--assume-unchanged','prototype-game/new.gd');f.indexBefore=fs.readFileSync(f.index);reject(f,{},/hidden index flags/);git(f.repo,'update-index','--no-assume-unchanged','prototype-game/new.gd');
console.log('identity: wrong head/branch/workspace/root, invalid base/companions, dirty inputs and hidden index flags rejected before import');
let r;
f=fixture();
const gradlew=f.repo+'/prototype-game/android/build/gradlew';
fs.chmodSync(gradlew,0o700);
assert.equal(fs.statSync(gradlew).mode & 0o777,0o700);
assert.equal(git(f.repo,'diff','--name-only','--','prototype-game/android/build/gradlew'),'');
r=run(f);assert.equal(r.status,0,r.stderr);
assert.equal(fs.statSync(gradlew).mode & 0o777,0o700);
f=fixture();fs.chmodSync(f.repo+'/prototype-game/android/build/gradlew',0o600);
reject(f,{},/Project differs from committed head.*gradlew/);
assert.equal(fs.readFileSync(root+'/imports','utf8'),'');
console.log('Git file mode: 0700 remains executable and imports without chmod; 0600 loses executability and refuses before Godot');
f=fixture(true);
r=run(f);assert.equal(r.status,0,r.stderr);
assert.equal(JSON.parse(r.stdout).sourceCounts.headTracked,13);
f=fixture(true);
const largeFile=f.repo+'/prototype-game/docs/large.bin';
const fd=fs.openSync(largeFile,'r+');fs.writeSync(fd,Buffer.from([0x62]),0,1,0);fs.closeSync(fd);
reject(f,{},/Project differs from committed head.*large.bin/);
assert.equal(fs.readFileSync(root+'/imports','utf8'),'');
console.log('large tracked blob: 17 MiB raw committed file imports without Git stdout overflow; one-byte drift refuses before Godot');
f=fixture();
const originalBranch=f.branch, renamedBranch='fm/'+originalBranch;
git(f.repo,'branch','-m',renamedBranch);
f.args.expectedBranch=renamedBranch;
r=run(f);assert.equal(r.status,0,r.stderr);
const renamed=JSON.parse(r.stdout);
assert.equal(renamed.branch,renamedBranch);
assert.equal(renamed.registeredBranch,originalBranch);
assert.equal(git(f.repo,'symbolic-ref','HEAD'),'refs/heads/'+renamedBranch);
assert.equal(git(f.repo,'rev-parse','HEAD'),renamed.head);
assert.equal(fs.readFileSync(root+'/imports','utf8').trim().split('\n').length,2);
f=fixture();git(f.repo,'branch','-m','fm/'+f.branch);
reject(f,{},/branch\/head differs/);
f.args.expectedBranch='fm/'+f.branch;
reject(f,{expectedHead:'0'.repeat(40)},/branch\/head differs/);
f=fixture();
db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)').run('duplicate-'+f.args.workspace,f.args.project,'duplicate','worktree',0,'active','','');
db.prepare('INSERT INTO workspace_roots VALUES(?,?,?,?)').run('duplicate-'+f.args.workspace,'r'+serial,f.repo,'duplicate');
reject(f,{},/ambiguous Playbot ownership/);
console.log('renamed lane: actual symbolic branch and full head authorize import while stale registration is reported; wrong actual branch/head and duplicate ownership refuse');
f=fixture();
const sourceTracked=git(f.repo,'ls-tree','-r','--name-only',f.head).split('\n').length;
const sourceChanged=git(f.repo,'diff','--name-only',f.base,f.head).split('\n').length;
r=run(f);assert.equal(r.status,0,r.stderr);const result=JSON.parse(r.stdout);
assert.notEqual(result.head,f.head);assert.equal(git(f.repo,'rev-parse','HEAD'),result.head);
assert.deepEqual(git(f.repo,'diff-tree','--no-commit-id','--name-only','-r',f.head,result.head).split('\n').sort(),f.args.companions.slice().sort());
assert.equal(git(f.repo,'show','-s','--format=%(trailers:key=Guide-check-base,valueonly)','HEAD'),f.base);
assert.equal(result.sourceCounts.headTracked,sourceTracked);assert.equal(result.sourceCounts.changed,sourceChanged);assert.equal(result.sourceCounts.authorizedCompanions,2);assert.equal(result.committedCompanions,2);
assert.equal(result.importClean,true);assert.equal(fs.readFileSync(root+'/imports','utf8').trim().split('\n').length,2);
assert.equal(git(f.repo,'diff','--cached','--','outside.txt'),f.staged);
assert.equal(git(f.repo,'diff','--cached','--name-only'),'outside.txt');
assert.equal(fs.readFileSync(f.repo+'/outside.txt','utf8'),'staged plus unstaged work\n');assert.equal(fs.readFileSync(f.repo+'/unstaged.txt','utf8'),'unstaged work\n');
assert.equal(fs.readFileSync(f.repo+'/prototype-game/addons/playbot/plugin.gd','utf8'),'bundled addon\n');assert.equal(fs.readFileSync(f.repo+'/prototype-game/addons/playbot/native/helper.so','utf8'),'native bytes');assert.equal(fs.readFileSync(f.repo+'/prototype-game/addons/playbot/untracked.gd','utf8'),'injected helper\n');
assert(!fs.existsSync(f.index+'.lock'));
assert.equal(fs.readFileSync(f.repo+'/prototype-game/private.env','utf8'),'private fixture credentials\n');
assert.equal(fs.readFileSync(f.repo+'/prototype-game/tests/task_evidence/inventory.txt','utf8'),'ignored evidence\n');
console.log(`success: source tracked=${sourceTracked}, observed=${result.sourceCounts.headTracked}; source changed=${sourceChanged}, observed=${result.sourceCounts.changed}; authorized=2 committed=${result.committedCompanions}; import passes=2; original staged/unstaged/addon bytes preserved`);
f.args.expectedHead=result.head;f.head=result.head;f.indexBefore=fs.readFileSync(f.index);r=run(f,{mode:'check'});assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).head,result.head);assert(fs.readFileSync(f.index).equals(f.indexBefore));
f=fixture();r=run(f,{importCleanGuard:'scripts/check_import_clean.py'});assert.equal(r.status,0,r.stderr);const gated=JSON.parse(r.stdout);assert.equal(JSON.parse(fs.readFileSync(f.repo+'/'+gated.importCleanReceipt,'utf8')).sha,gated.head);assert.equal(gated.importCleanGuard,'scripts/check_import_clean.py');
console.log('native gate routing: guard subprocess received pinned import with isolated environment and certified resulting committed head');
f=fixture();r=run(f,{importCleanGuard:'scripts/check_import_clean.py'},'gate-no-receipt');assert.notEqual(r.status,0);assert.notEqual(git(f.repo,'rev-parse','HEAD'),f.head);assert.match(r.stderr,/no such file|did not certify/);assert(!fs.existsSync(f.index+'.lock'));
console.log('native gate refusal: a zero exit without a resulting-head receipt cannot certify import-clean');
console.log('import-clean: exact generated head passed a separate check with no commit or index change');
for(const [mode,pattern,mutated] of [['source',/Unexpected import mutations preserved/,'prototype-game/new.gd'],['unrelated',/Unexpected import mutations preserved/,'unexpected.txt'],['addon',/Unexpected import mutations preserved/,'prototype-game/addons/playbot/plugin.gd'],['failed',/Godot import failed/,'prototype-game/new.gd.uid'],['malformed',/Malformed generated UID/,'prototype-game/new.gd.uid']]){
  f=fixture();r=reject(f,{},pattern,mode);assert(fs.existsSync(f.repo+'/'+mutated));assert.match(r.stderr,/evidence\/backups:/);const scratch=r.stderr.trim().split('evidence/backups: ').at(-1);assert(fs.existsSync(scratch+'/index.before'));assert(fs.existsSync(scratch+'/addons/prototype-game/addons/playbot/plugin.gd'));
}
console.log('refusals: source/addon/unrelated mutations, failed import, malformed UID preserved outputs, index, head and private backups');
f=fixture();fs.writeFileSync(f.repo+'/prototype-game/addons/playbot/plugin.gd','drift\n');r=run(f);assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(f.repo+'/prototype-game/addons/playbot/plugin.gd','utf8'),'drift\n');
f=fixture();fs.writeFileSync(f.repo+'/prototype-game/addons/playbot/plugin.gd','staged addon\n');git(f.repo,'add','prototype-game/addons/playbot/plugin.gd');f.indexBefore=fs.readFileSync(f.index);reject(f,{},/Injected addon changes are staged/);
f=fixture();fs.writeFileSync(f.index+'.lock','another owner');reject(f,{},/EEXIST/);assert.equal(fs.readFileSync(f.index+'.lock','utf8'),'another owner');
f=fixture();reject(f,{},/Index lock ownership changed/,'lock-drift');assert.equal(fs.readFileSync(f.index+'.lock','utf8'),'foreign lock owner');
f=fixture();r=run(f,{},'head-drift');assert.notEqual(r.status,0);assert.match(r.stderr,/branch\/head differs/);assert.equal(git(f.repo,'rev-parse','HEAD'),f.base);assert(fs.readFileSync(f.index).equals(f.indexBefore));
assert(!fs.existsSync(root+'/ipc'));
f=fixture();r=run(f,{},'second-pass');assert.notEqual(r.status,0);assert.match(r.stderr,/Import-clean failed on committed head/);assert.notEqual(git(f.repo,'rev-parse','HEAD'),f.head);assert.equal(fs.readFileSync(f.repo+'/prototype-game/new.gd.uid','utf8'),'uid://changed456\n');assert(!fs.existsSync(f.index+'.lock'));
f=fixture();git(f.repo,'update-ref','refs/heads/proto/godot/frog-pile',f.head);reject(f,{},/base differs from merge-base/);
f=fixture();const alias=f.repo+'-alias';fs.symlinkSync(f.repo,alias);db.prepare('UPDATE workspace_roots SET path=? WHERE workspace_id=?').run(alias,f.args.workspace);r=run(f);assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).root,f.repo);assert.equal(JSON.parse(r.stdout).registeredRoot,alias);
console.log('path aliases: registered alias resolves to one exact physical lane checkout without changing Playbot registration');
console.log('committed-head refusal: unstable second import retained generated head and changed bytes; stale guide base refused');
console.log('guards: existing index lock/concurrent head drift refused; addon drift preserved; no Playbot IPC or ADB invoked');
db.close();
NODE
pass 'fm-playbot-lane-import: public CLI identity, exact companions, import-clean and preservation (fake Godot only)'
LANE_IMPORT_TEST
