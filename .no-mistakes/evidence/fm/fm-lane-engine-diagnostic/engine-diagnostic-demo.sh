#!/usr/bin/env bash
# Read-only Playbot engine diagnostics and fail-closed dispatch via public MCP.
set -eu
# shellcheck source=tests/lib.sh
. "/var/home/sanchith/.no-mistakes/worktrees/f62841b885f5/01M3KFWD5N9H3EE871CT5WNHB6/tests/lib.sh"
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
          if(channel==='threads:send')return {pendingMessages:[],outboundMessages:[]};
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
G="$TMP_ROOT/game"; B="$TMP_ROOT/resources/app.asar.unpacked/electron/backend/godot-plugin/addons/playbot"
stage() { # $1 lifecycle $2 status $3 pluginVersion
node -e '
const fs=require("fs"),p=require("path"),r=process.env.FIXTURE_ROOT;
const inst={id:"session",type:"headless",status:process.argv[2],lifecycleStatus:process.argv[1],pluginStatus:"up_to_date",pluginVersion:process.argv[3],processLogs:[`[Headless] Godot path: ${r}/godot`],processErrors:[]};
fs.writeFileSync(p.join(r,"engine.json"),JSON.stringify([{engineKind:"godot",projectPath:p.join(r,"game"),snapshot:{instances:[inst],routedInstanceId:"session",preferredInstanceType:"headless",connectionBlocked:false}}]));' "$@"; }
show() { echo; echo "===== $1 ====="; echo '$ fm-playbot-lanes.mjs call get_engine_readiness {"project":"p","workspace":"ws"}'
  node --no-warnings "$SCRIPT" call get_engine_readiness '{"project":"p","workspace":"ws"}' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).structuredContent;console.log(JSON.stringify({verdict:c.verdict,app:c.app,bundle:c.bundle,projects:c.projects},null,1))})' | sed "s#$TMP_ROOT#<fixture>#g"; }
stage connected idle-edit 0.7.20; show "1. healthy: addon matches bundle, session connected"
printf '[plugin]\nversion="0.7.14"\n' > "$G/addons/playbot/plugin.cfg"; show "2. addon drift (repo 0.7.14 vs bundle 0.7.20)"
cp "$B/plugin.cfg" "$G/addons/playbot/plugin.cfg"; rm "$G/addons/playbot/plugin.gd"; show "3. missing addon file"
cp "$B/plugin.gd" "$G/addons/playbot/plugin.gd"; stage starting offline 0.7.20; show "4. startup still pending"
stage connected idle-edit 0.7.20; printf '#!/bin/sh\nexec flatpak run org.godotengine.Godot "$@"\n' > "$TMP_ROOT/godot"; show "5. Flatpak shim selected (identity admission risk)"
echo; echo "===== 6. engine-dependent dispatch refused on unconfirmed readiness ====="
echo '$ fm-playbot-lanes.mjs call dispatch {"project":"p","workspace":"ws","thread":"chat","message":"Run engine tests"}'
: > "$TMP_ROOT/calls"; node --no-warnings "$SCRIPT" call dispatch '{"project":"p","workspace":"ws","thread":"chat","message":"Run engine tests"}' 2>&1 | sed "s#$TMP_ROOT#<fixture>#g"; echo "exit=${PIPESTATUS[0]}"
echo "IPC channels invoked: $(node -e 'console.log([...new Set(require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(l=>JSON.parse(l).channel))].join(", "))' "$TMP_ROOT/calls")  (no threads:send)"
echo; echo "===== 7. engine-dependent newWorkspace dispatch refused before creation ====="
: > "$TMP_ROOT/calls"; node --no-warnings "$SCRIPT" call dispatch '{"project":"p","landingBranch":"main","newWorkspace":{"branch":"fm-engine"},"title":"Engine","message":"Run engine tests"}' 2>&1 | sed "s#$TMP_ROOT#<fixture>#g"; echo "exit=${PIPESTATUS[0]}; IPC calls made: $(wc -l < "$TMP_ROOT/calls")"
