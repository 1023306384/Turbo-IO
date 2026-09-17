import test from 'node:test';import assert from 'node:assert/strict';import {loadApp} from './load-app.mjs';import {loadCore} from './load-core.mjs';
const {businessEnvelope,HARMONY_WIDGET_ID}=loadCore('./BusinessCommands'),{readLauncherEnvelope}=loadCore('./LauncherStatus');
const wire=(type,j,seq=0)=>businessEnvelope(type,new TextEncoder().encode(JSON.stringify(j)),seq);
test('Chinese widget text is byte-budgeted before starting a pending launcher command',async()=>{
 const {device:d,sent}=setup();await d.dashboardRead();d.receive(15,wire(19,{cmd:'dashboard_config',payload:{data:{widgets_v2:[]}}}));
 const before=sent.length;await assert.rejects(d.widget('雷'.repeat(20)),/单帧/);assert.equal(sent.length,before);assert.equal(d.launcherBusy,false);
 await d.widget('雷'.repeat(15));assert.equal(sent.length,before+1);
});
test('display stop keeps occupancy until matching exit response or explicit physical confirmation',async()=>{
 const {device:d,sent,timers}=setup();await d.show('测试');const {sid}=JSON.parse(new TextDecoder().decode(sent[0].e.json));
 await d.stopDisplay();assert(d.displayActive);assert(d.displayClosing);await assert.rejects(d.show('不能抢占'));
 d.receive(19,wire(8,{sid,code:1}));assert.equal(d.state.displayReady,false);
 [...timers.values()].find(t=>t.n===8000).f();assert(d.displayActive);assert.match(d.state.display,/未确认/);
 d.receive(19,wire(3,{sid:'unrelated'}));assert(d.displayActive);d.receive(19,wire(3,{sid}));assert(!d.displayActive);
 await d.show('下一轮');await d.stopDisplay();d.confirmDisplayExited();assert(!d.displayActive);assert.match(d.state.display,/非设备回执/);
});
test('weather negative result is never relabeled success',async()=>{
 const {device:d}=setup();await d.weather('测试',27,101);d.receive(15,wire(19,{cmd:'current_weather_update',payload:{value:5}}));assert.match(d.state.weather,/未接受/);assert.equal(d.launcherBusy,false);
});
function setup(){const sent=[],timers=new Map();let id=0;const {DeviceFeatures}=loadApp('DeviceFeatures',{'@kit.CryptoArchitectureKit':{cryptoFramework:{createRandom:()=>({generateRandomSync:n=>({data:new Uint8Array(n).fill(7)})})}}},{setTimeout:(f,n)=>{timers.set(++id,{f,n});return id;},clearTimeout:id=>timers.delete(id)});const device=new DeviceFeatures(async(b,p)=>{sent.push({b,e:readLauncherEnvelope(p)});});device.connected(true,50);return {device,sent,timers};}
test('A2UI requires baseline and exact sequence/code ACK; unrelated or legacy value does not grant deletion',async()=>{
 const {device:d,sent}=setup();await assert.rejects(d.widget('test'),/基线/);await d.dashboardRead();d.receive(15,wire(19,{cmd:'dashboard_config',payload:{data:{widgets_v2:[{id:'weather'}]}}}));await d.widget('test');const seq=sent.at(-1).e.sequence;
 d.receive(15,wire(19,{code:0},seq+1));await assert.rejects(d.removeWidget(),/只能删除/);
 d.receive(15,wire(19,{code:0},seq));await d.removeWidget();const json=JSON.parse(new TextDecoder().decode(sent.at(-1).e.json));assert.equal(json.payload.data.id,HARMONY_WIDGET_ID);assert.equal(json.cmd,'widget_uninstall');
});
test('existing foreign-owned test id is never overwritten just because it uses our prefix',async()=>{
 const {device:d}=setup();await d.dashboardRead();d.receive(15,wire(19,{cmd:'dashboard_config',payload:{data:{widgets_v2:[{id:HARMONY_WIDGET_ID}]}}}));await assert.rejects(d.widget('test'),/拒绝覆盖/);
});
test('display waits for matching SID success before text, and stops on unexpected audio',async()=>{
 const {device:d,sent,timers}=setup();await d.show('测试7392');const start=JSON.parse(new TextDecoder().decode(sent[0].e.json));assert.equal(sent[0].b,19);assert.equal(sent[0].e.type,7);
 d.receive(19,wire(8,{sid:'wrong',code:1}));assert.equal(d.state.displayReady,false);
 d.receive(19,wire(8,{sid:start.sid,code:1}));assert.equal(d.state.displayReady,true);[...timers.values()].find(t=>t.n===0).f();await new Promise(r=>setImmediate(r));assert.equal(sent[1].e.type,5);
 d.receive(19,Uint8Array.of(8,1,16,4,34,1,99));await new Promise(r=>setImmediate(r));assert.equal(sent.at(-1).e.type,3);assert.equal(d.state.displayReady,false);
});
test('only owned continuous display removes the preview deadline and disconnect clears its lease',async()=>{
 for(const continuous of [false,true]){const {device:d,sent,timers}=setup();assert(!d.displayActive);await d.show('route',continuous);assert(d.displayActive);assert(!d.state.displayReady);const {sid}=JSON.parse(new TextDecoder().decode(sent[0].e.json));d.receive(19,wire(8,{sid,code:1}));assert.equal([...timers.values()].some(t=>t.n===180000),!continuous);d.connected(false,0);assert(!d.displayActive);assert.equal(timers.size,0);}
});
