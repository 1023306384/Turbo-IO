import test from 'node:test';import assert from 'node:assert/strict';import {loadApp} from './load-app.mjs';import {loadCore} from './load-core.mjs';
const {businessEnvelope}=loadCore('./BusinessCommands'),{readLauncherEnvelope}=loadCore('./LauncherStatus');
const flush=async()=>{for(let i=0;i<100;i++)await Promise.resolve();};
test('standby is not microphone/display occupancy; occupied features block wake without tearing down their window',async()=>{
 const s=setup();s.v.enable(s.config);assert.equal(s.v.active,false);s.v.canBegin=()=>false;
 s.receive(1);await flush();assert.equal(s.sent.length,0);assert.equal(s.v.state.enabled,true);assert.equal(s.v.active,false);
 s.v.canBegin=()=>true;s.receive(1);await flush();assert.equal(s.v.active,true);assert.equal(s.sent[0].type,2);
 s.v.disable();await flush();assert.equal(s.v.active,false);
});
function setup(deferred=false){const timers=new Map(),sent=[],asrs=[],requests=[];let tid=0,modelCalls=0,cancels=0,starts=0;
 class Config{};class Model{cancel(){cancels++;}async chat(){modelCalls++;if(deferred)return new Promise(resolve=>requests.push(resolve));return '测试回答😀'.repeat(8);}}
 class ASR{constructor(){asrs.push(this);}close(){}start(){starts++;}append(){}}
 const {VoiceSession}=loadApp('VoiceSession',{'libturbo_audio.so':{reset(){},close(){},decode(){return new ArrayBuffer(640);}},'@kit.CryptoArchitectureKit':{cryptoFramework:{createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(n).fill(4)})})}},'./CloudASR':{CloudASR:ASR},'./RemoteServices':{ServiceConfig:Config,RemoteServices:Model}},{setTimeout:(f,ms)=>{timers.set(++tid,{f,ms});return tid;},clearTimeout:id=>timers.delete(id)});
 const v=new VoiceSession(async(b,p)=>{const e=readLauncherEnvelope(p);sent.push({b,type:e.type,json:JSON.parse(new TextDecoder().decode(e.json))});});v.connected(true);
 const config={asrKey:'synthetic',asrHost:'test.aliyuncs.com',asrModel:'model',modelKey:'synthetic'};
 const receive=type=>v.receive(13,businessEnvelope(type,new TextEncoder().encode('{}')));
 return {v,config,sent,asrs,timers,receive,requests,modelCalls:()=>modelCalls,cancels:()=>cancels,starts:()=>starts};
}
test('native voice uses final ASR -> model -> answer chunks -> type12 -> 10 second exit',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();assert.equal(s.sent[0].type,2);assert.equal(s.sent[0].json.rc,1);
 s.asrs[0].onText('介绍香港',true);await flush();assert.equal(s.modelCalls(),1);assert.equal(s.v.state.phase,'displaying');
 const answers=s.sent.filter(x=>x.type===32);assert(answers.length>1);assert(answers.every(x=>!x.json.answer.isFinal));assert.equal(s.sent.at(-1).type,12);
 assert.equal(s.v.state.modelRequests,1);assert.equal(s.v.state.modelReplies,1);assert.equal(s.v.state.completedRounds,1);
 const timer=[...s.timers.values()].find(x=>x.ms===10000);assert(timer);
 s.receive(11);s.receive(11);await flush();assert.equal(s.v.state.phase,'displaying');assert.equal(s.starts(),2);assert.equal([...s.timers.values()].filter(x=>x.ms===10000).length,1);
 timer.f();await flush();assert.equal(s.sent.at(-1).type,7);assert.equal(s.v.state.phase,'idle');
});
test('explicit wake interrupts answer, clears old EOF timer, ignores duplicate wake while already recording',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();s.asrs[0].onText('第一句',true);await flush();
 const oldTimer=[...s.timers.values()].find(x=>x.ms===10000);const staleText=s.asrs[0].onText;
 s.receive(1);s.receive(1);await flush();assert.equal(s.v.state.phase,'recording');assert.equal(s.starts(),2);
 assert.equal([...s.timers.values()].filter(x=>x.ms===10000).length,0);oldTimer.f();staleText('旧识别',true);await flush();assert.equal(s.v.state.phase,'recording');
 s.asrs[0].onText('第二句',true);await flush();assert.equal(s.modelCalls(),2);assert.equal(s.v.state.completedRounds,2);
});
test('next-turn offer preserves old answer; real speech cancels pending model and rejects its late result',async()=>{
 const s=setup(true);s.v.enable(s.config);s.receive(1);await flush();s.asrs[0].onText('第一句',true);await flush();assert.equal(s.v.state.phase,'processing');
 const cancels=s.cancels();s.receive(11);await flush();assert.equal(s.cancels(),cancels);assert.equal(s.v.state.phase,'processing');
 s.asrs[0].onText('换一个问题',false);await flush();assert.equal(s.v.state.phase,'recording');assert.equal(s.cancels(),cancels+1);
 s.requests[0]('过期回答不得发送');await flush();assert.equal(s.sent.filter(x=>x.type===32).length,0);
 s.asrs[0].onText('换一个问题',true);await flush();s.requests[1]('新回答');await flush();assert.equal(s.v.state.answer,'新回答');assert.equal(s.v.state.completedRounds,1);
});
test('silence, empty ASR and followup error do not extend EOF or cancel completed answer',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();s.asrs[0].onText('第一句',true);await flush();
 const timer=[...s.timers.values()].find(x=>x.ms===10000);const answer=s.v.state.answer;
 s.receive(11);await flush();s.asrs[0].onText('  ',false);s.asrs[0].onError('失败');await flush();
 assert.equal(s.v.state.answer,answer);assert.equal(s.v.state.phase,'displaying');assert([...s.timers.values()].includes(timer));
 timer.f();await flush();assert.equal(s.v.state.phase,'idle');assert.equal(s.sent.at(-1).type,7);
});
test('followup speech during display replaces deadline, completes second turn then exits on its own deadline',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();s.asrs[0].onText('第一句',true);await flush();const old=[...s.timers.values()].find(x=>x.ms===10000);
 s.receive(11);await flush();const stale=s.asrs[0].onText;s.asrs[0].onText('第二句',false);await flush();old.f();assert.equal(s.v.state.phase,'recording');
 s.asrs[0].onText('第二句',true);await flush();stale('重复句末',true);await flush();assert.equal(s.modelCalls(),2);
 const current=[...s.timers.values()].find(x=>x.ms===10000);assert(current);current.f();await flush();assert.equal(s.v.state.phase,'idle');
 s.receive(11);await flush();assert.equal(s.v.state.phase,'idle');
});
test('ASR-only test needs no model key and never calls the model',async()=>{
 const s=setup();s.config.modelKey='';assert.throws(()=>s.v.enable(s.config));s.v.enable(s.config,true);s.receive(1);await flush();s.asrs[0].onText('测试',true);await flush();assert.equal(s.modelCalls(),0);assert.match(s.v.state.answer,/本地测试/);
});
test('disconnect and stale callbacks cannot send a new answer',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();const callback=s.asrs[0].onText;s.v.connected(false);const count=s.sent.length;callback('迟到',true);await flush();assert.equal(s.sent.length,count);assert.equal(s.modelCalls(),0);assert.equal(s.v.state.enabled,false);
});
test('silence exits after 6 seconds without pretending audio was received',async()=>{
 const s=setup();s.v.enable(s.config);s.receive(1);await flush();[...s.timers.values()].find(x=>x.ms===6000).f();await flush();assert.match(s.v.state.note,/未收到/);assert.equal(s.sent.at(-1).type,7);
});
