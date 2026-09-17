import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {loadCore} from './load-core.mjs';
const {encodeFrame,decodeFrame,encodeTlvs,decodeTlvs,authFields}=loadCore('./ProtocolCodec');
const {AndroidAuthCalculations}=loadCore('./AuthCalculations');
const sha=b=>Uint8Array.from(createHash('sha256').update(b).digest());const calc=new AndroidAuthCalculations({digest:sha});
const phone=Uint8Array.of(0,17,34,51,68,85),peer=Uint8Array.of(170,187,204,221,238,255);
const input=()=>({phoneIdentifier:phone.slice(),phoneNameUTF8:new Uint8Array(),manufacturerUTF8:new Uint8Array(),modelUTF8:new Uint8Array(),accountUTF8:null,publicKey:null,pairValue:null});
const service='0000b81d-0000-1000-8000-00805f9b34fb',tx='ea8b70d5-2bd3-49ab-9c31-9c38b2c3c4f9',rx='7db3e235-3608-41f3-a03c-955fcbd2ea4b';
const wire=payload=>encodeFrame({messageNumber:500,flags:0,address:null,slices:new Uint8Array(),businessID:0x10,payload});
const version=(identity=peer)=>wire(encodeTlvs([{tag:0x11,value:encodeTlvs([{tag:0x10,value:Uint8Array.of(1)},{tag:0x11,value:identity}])}]));
const proof=(bad=false)=>{const random=Uint8Array.of(5,6,7,8),p=calc.guestProof(random,phone,peer);if(bad)p[0]^=1;return wire(encodeTlvs([{tag:0x19,value:encodeTlvs([{tag:0x10,value:random},{tag:0x11,value:p}])}]));};
const settle=()=>new Promise(r=>setImmediate(r));
function setup(){
 const reports=[],clients=[],timers=new Map(),randomBuffers=[];let nextTimer=0,now=100,randomFailure=false,autoReply=false,deferWrite=false;
 const ch=(id,properties)=>({serviceUuid:service,characteristicUuid:id,properties,descriptors:[],characteristicValue:new ArrayBuffer(0)});
 let bondState=0,bondListener;const pairCalls=[];
 const radio={connection:{BondState:{BOND_STATE_BONDED:2},on:(k,f)=>{bondListener=f;},off:()=>{bondListener=undefined;},getPairState:()=>bondState,pairDevice:async id=>{pairCalls.push(id);}},constant:{ProfileConnectionState:{STATE_CONNECTED:2,STATE_DISCONNECTED:0}},ble:{GattWriteType:{WRITE_NO_RESPONSE:2},createGattClientDevice:()=>{
  const listeners=new Map();const c={listeners,writes:[],closed:false,resolveWrite:undefined,on:(k,f)=>listeners.set(k,f),off:k=>listeners.delete(k),connect:()=>{},disconnect:()=>{},close:()=>{c.closed=true;},
   getServices:async()=>[{serviceUuid:service,characteristics:[ch(tx,{writeNoResponse:true}),ch(rx,{notify:true})]}],setBLEMtuSize:()=>{},setCharacteristicChangeNotification:async()=>{},
   notify:bytes=>listeners.get('BLECharacteristicChange')?.({...ch(rx,{}),characteristicValue:bytes.slice().buffer}),
   writeCharacteristicValue:value=>{
    const bytes=new Uint8Array(value.characteristicValue).slice();c.writes.push(bytes);
    if(autoReply){const tag=decodeTlvs(decodeFrame(bytes).payload)[0].tag;const reply=tag===0x11?version():proof();c.notify(reply.slice(0,7));c.notify(reply.slice(7));}
    return deferWrite?new Promise(resolve=>{c.resolveWrite=resolve;}):Promise.resolve();
   }};clients.push(c);return c;}}};
 const cryptoFramework={createRandom:()=>({generateRandomSync:n=>{if(randomFailure)throw Error('private');const b=new Uint8Array(n).fill(9);randomBuffers.push(b);return {data:b};}}),createMd:()=>{let input;return {updateSync:b=>{input=b.data.slice();},digestSync:()=>({data:sha(input)})};}};
 const globals={setTimeout:(fn,delay)=>{const id=++nextTimer;timers.set(id,{fn,delay});return id;},clearTimeout:id=>timers.delete(id)};
 const {BleGuestAuthProbe}=loadCore('./BleGuestAuthProbe',{'@kit.ArkTS':{util:{TextDecoder:class {decodeToString(b){return new TextDecoder().decode(b);}}}},'@kit.ConnectivityKit':radio,'@kit.CryptoArchitectureKit':{cryptoFramework},'@kit.BasicServicesKit':{systemDateTime:{TimeType:{STARTUP:0},getUptime:(type,nano)=>{assert.equal(type,0);assert.equal(nano,false);return now;}}}},globals);
 const probe=new BleGuestAuthProbe(r=>reports.push(r));
 return {probe,reports,clients,timers,randomBuffers,pairCalls,bond:(id='synthetic')=>{bondState=2;bondListener?.({deviceId:id,state:2});},last:()=>reports.at(-1),clock:n=>{now=n;},failRandom:()=>{randomFailure=true;},auto:()=>{autoReply=true;},manual:()=>{autoReply=false;},defer:()=>{deferWrite=true;},fire:delay=>[...timers.values()].find(t=>t.delay===delay).fn()};
}
test('concurrent authenticated feature commands serialize without interleaving or command-busy failures',async()=>{
 const ctx=setup();ctx.auto();const c=await connected(ctx,true);await settle();ctx.manual();ctx.bond();
 const {businessEnvelope}=loadCore('./BusinessCommands');const packet=businessEnvelope(2,new TextEncoder().encode('{"eventType":1}'));
 ctx.defer();const before=c.writes.length;const first=ctx.probe.sendBusiness(22,packet),second=ctx.probe.sendBusiness(22,packet);
 await settle();assert.equal(c.writes.length,before+1);c.resolveWrite();await first;await settle();assert.equal(c.writes.length,before+2);c.resolveWrite();await second;
 assert.equal(ctx.last().stage,'connected');assert(!c.closed);
});
test('queued business command is not replayed after disconnect',async()=>{
 const ctx=setup();ctx.auto();const c=await connected(ctx,true);await settle();ctx.manual();ctx.bond();
 const {businessEnvelope}=loadCore('./BusinessCommands');const packet=businessEnvelope(2,new TextEncoder().encode('{}'));
 ctx.defer();const before=c.writes.length;const first=ctx.probe.sendBusiness(22,packet),second=ctx.probe.sendBusiness(22,packet);
 const outcomes=Promise.allSettled([first,second]);await settle();ctx.probe.cancel();await outcomes;assert.equal(c.writes.length,before+1);assert(c.closed);
});
async function connected(ctx,maintain=false){ctx.probe.start('synthetic',input(),peer,true,maintain);const c=ctx.clients.at(-1);c.listeners.get('BLEConnectionStateChange')({state:2});await settle();c.listeners.get('BLEMtuChange')(512);await settle();return c;}
test('maintained session authenticates before requesting system bond and keeps native connection open',async()=>{
 const ctx=setup();ctx.auto();const c=await connected(ctx,true);await settle();assert.equal(ctx.last().stage,'pairing');assert(!c.closed);assert.deepEqual(ctx.pairCalls,['synthetic']);
 assert(![...ctx.timers.values()].some(t=>t.delay===20000));ctx.bond('unrelated');assert.equal(ctx.last().stage,'pairing');ctx.bond();assert.equal(ctx.last().stage,'connected');assert.equal(ctx.last().bonded,true);
 c.notify(wire(encodeTlvs([{tag:0x17,value:Uint8Array.of(2)}])));assert.equal(ctx.last().peerPairStatus,2);assert(!c.closed);ctx.probe.cancel();assert(c.closed);assert.equal(ctx.timers.size,0);
});
test('maintained mode does not pair on failed proof and closes if system bond times out',async()=>{
 const a=setup(),c=await connected(a,true);c.notify(version());await settle();c.notify(proof(true));await settle();assert.equal(a.pairCalls.length,0);assert(c.closed);
 const b=setup();b.auto();const d=await connected(b,true);await settle();b.fire(60000);assert(d.closed);assert.equal(b.last().reason,'system-pair-timeout');assert.equal(b.timers.size,0);
});
test('full actual source stack: native mocks, early split replies, proof success closes without business or keys',async()=>{
 const ctx=setup();ctx.auto();const c=await connected(ctx);await settle();assert.equal(ctx.last().stage,'verified');assert.match(ctx.last().reason,/not-paired-or-initialized/);assert(c.closed);assert.equal(c.writes.length,2);assert.equal(ctx.timers.size,0);
 const versionPacket=decodeFrame(c.writes[0]),authPacket=decodeFrame(c.writes[1]);assert.equal(authPacket.messageNumber,(versionPacket.messageNumber+1)&65535);
 const auth=authFields(authPacket.payload,0x18);assert.deepEqual(auth[0].value,new Uint8Array(4).fill(9));assert.deepEqual(auth[1].value,calc.guestProof(new Uint8Array(4).fill(9),phone,peer));
 assert(ctx.randomBuffers.every(b=>b.every(n=>n===0)));assert(!JSON.stringify(ctx.reports).includes('session'));assert.equal(ctx.last().txBytes,c.writes.reduce((n,b)=>n+b.length,0));
});
test('consent, input and bound account validation happen before radio creation',()=>{
 const ctx=setup();assert.throws(()=>ctx.probe.start('synthetic',input(),peer,false),/confirmation/);
 assert.throws(()=>ctx.probe.start('synthetic',{...input(),accountUTF8:Uint8Array.of(1)},peer,true),/guest/);
 assert.throws(()=>ctx.probe.start('synthetic',input(),new Uint8Array(5),true));assert.equal(ctx.clients.length,0);
});
test('wrong identity and proof fail closed and never send extra frames',async()=>{
 const a=setup(),c=await connected(a);c.notify(version(phone));await settle();assert.equal(a.last().reason,'peer-identifier-mismatch');assert(c.closed);assert.equal(c.writes.length,1);
 const b=setup(),d=await connected(b);d.notify(version());await settle();d.notify(proof(true));await settle();assert.equal(b.last().reason,'proof-mismatch');assert(d.closed);assert.equal(d.writes.length,2);
});
test('final asynchronous proof RX remains counted when verification closes transport immediately',async()=>{
 const ctx=setup(),c=await connected(ctx);const v=version(),p=proof();c.notify(v);await settle();c.notify(p);await settle();assert.equal(ctx.last().stage,'verified');assert.equal(ctx.last().rxBytes,v.length+p.length);
});
test('native random failure does not send; clock deadline rejects valid late reply',async()=>{
 const a=setup();a.failRandom();const c=await connected(a);assert.equal(a.last().reason,'auth-start-failed');assert.equal(c.writes.length,0);assert(c.closed);
 const b=setup(),d=await connected(b);b.clock(5100);d.notify(version());await settle();assert.equal(b.last().reason,'timeout');assert(d.closed);
});
test('independent auth timer cancels a partial frame and pending native write',async()=>{
 const a=setup(),c=await connected(a);c.notify(version().slice(0,8));a.fire(5000);assert.equal(a.last().reason,'auth-timeout');assert(c.closed);
 const b=setup();b.defer();const d=await connected(b);b.fire(5000);await settle();d.resolveWrite();await settle();assert.equal(b.last().reason,'auth-timeout');assert(d.closed);
});
test('cancel and restart discard stale callbacks and queued frames',async()=>{
 const ctx=setup(),c=await connected(ctx);const oldNotify=c.listeners.get('BLECharacteristicChange');ctx.probe.cancel();const d=await connected(ctx);
 oldNotify({serviceUuid:service,characteristicUuid:rx,characteristicValue:version().buffer});await settle();assert.equal(ctx.last().stage,'version');assert.equal(d.writes.length,1);
 d.notify(version());await settle();d.notify(proof());await settle();assert.equal(ctx.last().stage,'verified');
});
test('unsupported flags or corrupt CRC rejected without guessing',async()=>{
 for(const alter of [b=>{b[8]^=1;return b;},b=>{const p=decodeFrame(b);return encodeFrame({...p,flags:1});}]){
  const ctx=setup(),c=await connected(ctx);c.notify(alter(version()));await settle();assert.equal(ctx.last().reason,'response-frame-invalid');assert(c.closed);
 }
});
