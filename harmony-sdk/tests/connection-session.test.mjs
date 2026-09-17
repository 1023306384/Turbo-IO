import test from 'node:test';
import assert from 'node:assert/strict';
import {loadApp} from './load-app.mjs';
const flush=async()=>{for(let i=0;i<60;i++)await Promise.resolve();};
const peer=new Uint8Array([1,2,3,4,5,6]);
const saved={id:'synthetic-device',peer:'010203040506',name:'RayNeo iO',autoConnect:true};
test('previous explicit background choice restores after ready but does not request it during authentication',async()=>{
 const t=setup({...saved,backgroundEnabled:true});await t.s.resume(t.ctx);assert.equal(t.s.background.active,false);
 t.version.reply();await flush();t.auth.emit();await flush();assert(t.s.background.active);
 await t.s.setBackground(false);assert.equal(JSON.parse(t.values.get('verified_glasses')).backgroundEnabled,false);
});
function setup(initial='',permission=0){
 const values=new Map(initial?[['verified_glasses',typeof initial==='string'?initial:JSON.stringify(initial)]]:[]);
 let writes=0,tid=0;const timers=new Map(),versions=[],auths=[];
 const prefs={async get(k,d){return values.get(k)??d;},async put(k,v){writes++;values.set(k,v);},async flush(){}};
 const store=loadApp('ConnectionStore',{'@kit.AbilityKit':{},'@kit.ArkData':{preferences:{async getPreferences(){return prefs;}}}});
 class Candidate{constructor(){this.id='';this.classic=false;this.deviceName='';}}
 class Identity{async get(){return new Uint8Array(6).fill(9);}}
 class NullRadio{stop(){}close(){}cancel(){}}
 class Version extends NullRadio{constructor(update,accept){super();this.update=update;this.accept=accept;versions.push(this);}start(id){this.id=id;this.starts=(this.starts||0)+1;}reply(bytes=peer){this.accept({peerIdentifier:bytes.slice()});this.update({stage:'received'});}fail(reason){this.update({stage:'failed',reason});}}
 class Auth extends NullRadio{constructor(update){super();this.update=update;auths.push(this);}start(id){this.id=id;this.starts=(this.starts||0)+1;}async sendBusiness(){}emit(stage='connected',statusReplies=1,reason=''){this.update({stage,bonded:stage==='connected',battery:99,connectedSeconds:5,statusReplies,reason});}}
 class Features{connected(){}receive(){}}
 class Voice{connected(){}receive(){}}
 class Background{active=false;async start(){this.active=true;}async stop(){this.active=false;}}
 const ctx={applicationInfo:{accessTokenId:7}};
 const {probeSession:s}=loadApp('ProbeSession',{
  turbo_core:{Candidate,Discovery:NullRadio,TransportProbe:NullRadio,BleHandshakeTransport:NullRadio,
   BleVersionProbe:Version,BleGuestAuthProbe:Auth,LocalProtocolIdentity:Identity},
  '@kit.AbilityKit':{abilityAccessCtrl:{createAtManager:()=>({checkAccessTokenSync:()=>permission})}},
  './ConnectionStore':store,'./DeviceFeatures':{DeviceFeatures:Features},'./VoiceSession':{VoiceSession:Voice},
  './BluetoothBackground':{BluetoothBackground:Background}
 },{setTimeout:(fn,ms)=>{timers.set(++tid,{fn,ms});return tid;},clearTimeout:id=>timers.delete(id)});
 const candidate=new Candidate();candidate.id=saved.id;candidate.deviceName=saved.name;
 const fire=async ms=>{const entry=[...timers.entries()].find(([,v])=>v.ms===ms);assert(entry,'timer '+ms);timers.delete(entry[0]);entry[1].fn();await flush();};
 return {s,ctx,candidate,version:versions[0],auth:auths[0],values,timers,fire,writes:()=>writes};
}
test('first connection chains version/auth but saves only after bonded status readback',async()=>{
 const t=setup();await t.s.connect(t.candidate,t.ctx);assert.equal(t.version.starts,1);
 t.version.reply();await flush();assert.equal(t.auth.starts,1);assert.equal(t.writes(),0);
 t.auth.emit('connected',0);await flush();assert.equal(t.s.connection.phase,'initializing');assert.equal(t.writes(),0);
 t.auth.emit();await flush();assert.equal(t.s.connection.phase,'ready');assert.equal(t.s.connection.saved,true);
 assert.equal(JSON.parse(t.values.get('verified_glasses')).peer,saved.peer);assert.equal(t.timers.size,0);
});
test('saved verified device reconnects on launch without scan and validates peer again',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);assert.equal(t.version.id,saved.id);
 t.version.reply();await flush();t.auth.emit();await flush();assert.equal(t.s.connection.phase,'ready');assert.equal(t.writes(),0);
});
test('peer identity mismatch stops before authentication, never replaces saved identity',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.reply(new Uint8Array(6).fill(8));await flush();
 assert.equal(t.auth.starts,undefined);assert.equal(t.s.connection.phase,'failed');assert.equal(t.writes(),0);assert.equal(t.timers.size,0);
});
test('missing permission and disabled autoconnect do not touch radios',async()=>{
 const t=setup(saved,-1);await t.s.resume(t.ctx);assert.equal(t.version.starts,undefined);assert.equal(t.s.connection.phase,'permission');
 const off=setup({...saved,autoConnect:false});await off.s.resume(off.ctx);assert.equal(off.version.starts,undefined);
});
test('manual disconnect cancels retry and prevents foreground restart until explicit reconnect',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.fail('version-timeout');assert.equal(t.s.connection.phase,'retrying');
 t.s.stop();assert.equal(t.timers.size,0);await t.s.resume(t.ctx);assert.equal(t.version.starts,1);
 await t.s.reconnect(t.ctx);assert.equal(t.version.starts,2);
});
test('transient failures have three bounded retries; repeated resume cannot bypass delay',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);
 for(const ms of [2000,5000,10000]){t.version.fail('version-timeout');const starts=t.version.starts;await t.s.resume(t.ctx);assert.equal(t.version.starts,starts);await t.fire(ms);}
 t.version.fail('version-timeout');assert.equal(t.s.connection.phase,'failed');assert.equal(t.timers.size,0);assert.equal(t.version.starts,4);
});
test('authentication proof failure is not retried',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.reply();await flush();t.auth.emit('failed',0,'proof-invalid');
 assert.equal(t.s.connection.phase,'failed');assert.equal(t.timers.size,0);
});
test('background cancels attempt; foreground restores only opted-in saved connection',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.s.suspend();t.version.reply();await flush();assert.equal(t.auth.starts,undefined);
 await t.s.resume(t.ctx);assert.equal(t.version.starts,2);assert.equal(t.s.foreground,true);
});
test('status readback timeout cannot be mistaken for ready or persisted first connection',async()=>{
 const t=setup();await t.s.connect(t.candidate,t.ctx);t.version.reply();await flush();t.auth.emit('connected',0);
 await t.fire(12000);assert.equal(t.s.connection.phase,'failed');assert.equal(t.writes(),0);
});
test('corrupt saved identity is not silently replaced',async()=>{
 const t=setup('{"id":"synthetic-device"}');await t.s.resume(t.ctx);
 assert.equal(t.s.connection.phase,'failed');assert.equal(t.version.starts,undefined);assert.equal(t.writes(),0);
 await t.s.connect(t.candidate,t.ctx);assert.equal(t.version.starts,undefined);assert.equal(t.writes(),0);
});
test('autoconnect preference persists and turning it off cancels pending retry',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.fail('version-timeout');
 await t.s.setAutoConnect(false);assert.equal(t.timers.size,0);assert.equal(JSON.parse(t.values.get('verified_glasses')).autoConnect,false);
});
test('native background grant retains same connected session across background and foreground',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.reply();await flush();t.auth.emit();await flush();
 await t.s.setBackground(true);t.s.suspend();assert.equal(t.s.connection.phase,'ready');assert.equal(t.s.background.active,true);
 await t.s.resume(t.ctx);assert.equal(t.version.starts,1);assert.match(t.s.connection.backgroundReport,/未重新认证/);
});
test('revocation in background stops connection and no retry survives',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);t.version.reply();await flush();t.auth.emit();await t.s.setBackground(true);
 t.s.suspend();t.s.background.active=false;t.s.background.revoked();assert.equal(t.s.connection.phase,'idle');assert.equal(t.timers.size,0);
});
test('background task requires ready foreground connection and is released on manual disconnect',async()=>{
 const t=setup(saved);await t.s.resume(t.ctx);await t.s.setBackground(true);assert.equal(t.s.background.active,false);
 t.version.reply();await flush();t.auth.emit();await t.s.setBackground(true);assert.equal(t.s.background.active,true);
 t.s.stop();assert.equal(t.s.background.active,false);
});
