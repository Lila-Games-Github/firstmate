// Bounded direct headless-Chrome/CDP capture fallback: fixed viewport, PNG size check.
import { spawn } from 'node:child_process';
import { writeFileSync, statSync } from 'node:fs';
const [chrome, url, out, w, h] = process.argv.slice(2);
const W = +w, H = +h, port = 9333 + Math.floor(Math.random()*500);
const p = spawn(chrome, ['--headless=new','--no-sandbox','--disable-gpu',`--remote-debugging-port=${port}`,'--user-data-dir=/tmp/cdp-'+port,'about:blank'], {stdio:'ignore'});
const kill = setTimeout(() => { p.kill('SIGKILL'); console.error('timeout'); process.exit(3); }, 30000);
let targets; for (let i=0;i<50;i++){ try{ targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); break;}catch{ await new Promise(r=>setTimeout(r,200)); } }
const ws = new WebSocket(targets.find(t=>t.type==='page').webSocketDebuggerUrl);
await new Promise(r=>ws.onopen=r);
let id=0; const pend={}; ws.onmessage=e=>{const m=JSON.parse(e.data); if(m.id&&pend[m.id]){pend[m.id](m); delete pend[m.id];}};
const send=(method,params={})=>new Promise(r=>{const i=++id; pend[i]=r; ws.send(JSON.stringify({id:i,method,params}));});
await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride',{width:W,height:H,deviceScaleFactor:1,mobile:W<600});
await send('Page.navigate',{url}); await new Promise(r=>setTimeout(r,1500));
const snap = await send('Runtime.evaluate',{expression:'document.title + " | nodes=" + document.querySelectorAll("*").length',returnByValue:true});
const shot = await send('Page.captureScreenshot',{format:'png'});
const buf = Buffer.from(shot.result.data,'base64'); writeFileSync(out, buf);
const pw = buf.readUInt32BE(16), ph = buf.readUInt32BE(20);
console.log(JSON.stringify({out, bytes: statSync(out).size, png:`${pw}x${ph}`, requested:`${W}x${H}`, sizeMatches: pw===W&&ph===H, snapshot: snap.result.result.value}));
ws.close(); clearTimeout(kill); p.kill(); process.exit(pw===W&&ph===H&&buf.length>0?0:1);
