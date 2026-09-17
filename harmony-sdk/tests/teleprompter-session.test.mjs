import test from 'node:test';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';
import {loadApp} from './load-app.mjs';import {loadCore} from './load-core.mjs';
const {businessEnvelope}=loadCore('./BusinessCommands'),{readLauncherEnvelope}=loadCore('./LauncherStatus'),{FileMessage,fileMessage,readFileMessage}=loadCore('./FileTransfer');
const peer='aabbccddeeff',settle=()=>new Promise(r=>setImmediate(r));
test('iOS parity: start carries the same total/checksum/did plus full scroll parameters, not only did/action',async()=>{
 const s=setup(),text=await ready(s);await s.t.control(3);
 const rows=s.sent.filter(x=>x.b===20).map(x=>readLauncherEnvelope(x.p));
 const body=type=>JSON.parse(new TextDecoder().decode(rows.find(x=>x.type===type).json));
 const p=body(2),start=body(3);let hash=2166136261;for(const b of text)hash=Number(((BigInt(hash)^BigInt(b))*16777619n)&0xffffffffn);
 assert.equal(p.checksum,hash.toString(16).padStart(8,'0'));
 for(const key of ['total','checksum','did','scroll','speed','pageOffset','highLightOffset'])assert.equal(start[key],p[key]);
 assert.equal(start.total,text.length);assert.equal(start.scroll,2);
});
function setup(){let id=0,blockHash,blockSend,connected=true;const timers=new Map(),sent=[];
 const cryptoFramework={createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(n).fill(9)})}),createMd:()=>{const hash=createHash('md5');return {update:async({data})=>hash.update(data),digest:async()=>{if(blockHash)await blockHash;return {data:Uint8Array.from(hash.digest())};}};}};
 const {TeleprompterSession}=loadApp('TeleprompterSession',{'@kit.CryptoArchitectureKit':{cryptoFramework}},{setTimeout:(f,ms)=>{timers.set(++id,{f,ms});return id;},clearTimeout:id=>timers.delete(id)});
 const t=new TeleprompterSession(async(b,p)=>{sent.push({b,p:p.slice()});if(blockSend)await blockSend;},()=>connected?peer:'',()=>true);
 const did=()=>JSON.parse(new TextDecoder().decode(readLauncherEnvelope(sent.find(s=>s.b===20).p).json)).did;
 const business=async(type,body={})=>{t.receive(peer,20,businessEnvelope(type,new TextEncoder().encode(JSON.stringify({did:did(),action:2,code:1,...body}))));await settle();};
 const file=async(type,patch={})=>{t.receive(peer,18,fileMessage(Object.assign(new FileMessage(),{type,uuid:did()},patch)));await settle();};
 return {t,sent,timers,did,business,file,hashWait:p=>blockHash=p,sendWait:p=>blockSend=p,disconnect:()=>{connected=false;t.disconnected();}};
}
async function prepare(s,text='测试稿件7392'){await s.t.prepare(text,120);await s.business(2);await s.file(2);return new TextEncoder().encode(text);}
async function ready(s){const text=await prepare(s);await s.file(3,{size:20480});await s.file(5);await s.business(2,{code:7});assert.equal(s.t.phase,'ready');return text;}
test('preparation preserves exact UTF-8 and MD5; both file completion and business reply required',async()=>{
 const s=setup(),text=await prepare(s,'  第一行\n第二行😀  '),info=readFileMessage(s.sent.find(x=>x.b===18).p);assert.equal(info.fileSize,text.length);assert.equal(info.md5,createHash('md5').update(text).digest('hex'));
 await s.file(3,{size:20480});const chunk=readFileMessage(s.sent.filter(x=>x.b===18).at(-1).p);assert.deepEqual(chunk.data,text);assert.equal(s.t.progress,100);await assert.rejects(s.t.control(3));
 await s.business(2,{code:7});assert.equal(s.t.phase,'transferring');await s.file(5);assert.equal(s.t.phase,'ready');assert(!s.sent.some(x=>x.b===20&&readLauncherEnvelope(x.p).type===3));
});
test('duplicate prepare code1 is not completion; premature code7 does not start file or playback',async()=>{
 const s=setup();await prepare(s);await s.file(3,{size:20480});await s.file(5);await s.business(2);assert.equal(s.t.phase,'transferring');await assert.rejects(s.t.control(3));
 await s.business(2,{code:7});assert.equal(s.t.phase,'ready');
 const early=setup();await early.t.prepare('提前',120);await early.business(2,{code:7});assert.equal(early.t.phase,'error');assert(!early.sent.some(x=>x.b===18));
});
test('controls wait for matching ACK and speed changes restore running state; eye stop exits with ACK',async()=>{
 const s=setup();await ready(s);await s.t.control(3);assert.equal(s.t.phase,'controlling');await s.business(4);assert.equal(s.t.phase,'controlling');await s.business(3);assert.equal(s.t.phase,'running');
 await s.t.control(7,240);await s.business(7);assert.equal(s.t.phase,'running');await s.t.control(4);await s.business(4);assert.equal(s.t.phase,'paused');await s.t.control(5);await s.business(5);assert.equal(s.t.phase,'running');
 await s.business(8,{action:1,pageOffset:3});assert.equal(s.t.offset,3);await s.business(6,{action:1});assert(!s.t.active);assert.equal(s.timers.size,0);assert.equal(readLauncherEnvelope(s.sent.at(-1).p).type,6);
});
test('premature success, refusal and timeout never unlock start',async()=>{
 for(const mode of ['premature','refused','timeout']){const s=setup();await prepare(s);if(mode==='premature')await s.file(5);if(mode==='refused')await s.business(2,{code:0});if(mode==='timeout')[...s.timers.values()][0].f();assert.equal(s.t.phase,'error');await assert.rejects(s.t.control(3));}
});
test('cancel while digest is pending cannot submit a new prepare or revive transfer',async()=>{
 const s=setup();let release;const wait=new Promise(r=>release=r);s.hashWait(wait);const pending=s.t.prepare('cancel',120);await settle();await s.t.stop();release();await pending;assert(!s.sent.some(x=>x.b===18||readLauncherEnvelope(x.p).type===2));assert.equal(s.t.phase,'closing');s.disconnect();assert.equal(s.t.phase,'idle');
});
test('disconnect during a chunk write prevents committing progress and stale ready',async()=>{
 const s=setup();await prepare(s);let release;s.sendWait(new Promise(r=>release=r));s.file(3,{size:20480});await settle();s.disconnect();release();await settle();assert.equal(s.t.phase,'idle');assert.equal(s.t.progress,0);assert.equal(s.timers.size,0);
});
test('explicit exit cancels file and sends type6, but does not report exited before reply',async()=>{
 const s=setup();await ready(s);await s.t.stop();assert.equal(s.t.phase,'closing');const tail=s.sent.slice(-2);assert.equal(tail[0].b,18);assert.equal(readFileMessage(tail[0].p).type,6);assert.equal(readLauncherEnvelope(tail[1].p).type,6);await s.business(6);assert.equal(s.t.phase,'idle');
});
