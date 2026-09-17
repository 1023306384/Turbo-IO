import test from 'node:test';import assert from 'node:assert/strict';import {loadCore} from './load-core.mjs';
const b=loadCore('./BusinessCommands'),{readLauncherEnvelope}=loadCore('./LauncherStatus');
const encode=s=>new TextEncoder().encode(s);
test('homepage weather uses nested JSON string, timestamp and type18 envelope',()=>{
 const s=b.currentWeather('北京',27,101,1700000000),j=JSON.parse(s);assert.equal(j.cmd,'current_weather_update');assert.equal(typeof j.payload.data,'string');assert.deepEqual(JSON.parse(j.payload.data),{location:'北京',temp:27,icon:101});
 const e=readLauncherEnvelope(b.businessEnvelope(18,encode(s),1001));assert.equal(e.type,18);assert.equal(e.sequence,1001);
 assert.throws(()=>b.currentWeather('北京',999,101,1700000000));
});
test('minimal widget fits verified MTU512 and only addresses own widget',()=>{
 const s=b.installTextWidget('Turbo IO 7392'),j=JSON.parse(s);assert.equal(j.cmd,'widget_install');assert.equal(j.payload.data.id,b.HARMONY_WIDGET_ID);assert.equal(JSON.parse(j.payload.data.extras).uiContent.updateComponents.components[0].text,'Turbo IO 7392');
 assert(b.businessEnvelope(18,encode(s),1001).length+10<=509);
 assert.equal(JSON.parse(b.removeTextWidget()).payload.data.id,b.HARMONY_WIDGET_ID);assert(!b.removeTextWidget().includes('widgets_v2'));assert.throws(()=>b.installTextWidget('x'.repeat(21)));
});
test('temporary display does not request ASR and content preserves literal JSON metacharacters',()=>{
 const sid='a'.repeat(32),j=JSON.parse(b.displayStart(sid));assert.equal(j.force,false);assert.equal(j.scope,'temporary');assert.equal(j.config.is_display,true);
 const text='导航测试\n转弯"\\80米';assert.equal(JSON.parse(b.displayText(sid,text)).content.source_transcript,text);assert.equal(JSON.parse(b.displayStop(sid)).reason_code,10);assert.throws(()=>b.displayStart('wrong'));
});
