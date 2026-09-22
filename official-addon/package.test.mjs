import test from 'node:test';
import assert from 'node:assert/strict';
import {validateOptions,entitlementsFor,validateResearchPair} from './package.mjs';
const o={app:'/example/Runner.app',addon:'/example/addon.dylib',profile:'/example/profile.mobileprovision',out:'/example/new-output',identity:'A'.repeat(40),device:'synthetic-device',bundle:'com.example.test'};
test('experimental firmware packaging is explicit and original bundle only',()=>{
  assert.throws(()=>validateOptions({...o,'experimental-ota':'R3'}));
  assert.throws(()=>validateOptions({...o,bundle:'com.rayneo.venus.pub','experimental-ota':'unknown'}));
  validateOptions({...o,bundle:'com.rayneo.venus.pub','experimental-ota':'R3'});
});
test('local packaging requires explicit paths and credentials',()=>{validateOptions(o);for(const bad of [{app:'relative.app'},{out:'/example/bad.app'},{identity:'not-a-cert'},{device:''},{bundle:'bad'},{product:'anything'}])assert.throws(()=>validateOptions({...o,...bad}));});
test('profile authority is preserved, never grant push implicitly',()=>{const p={certs:[o.identity],devices:[o.device],expires:'2099-01-01',entitlements:{'application-identifier':'EXAMPLE.*','keychain-access-groups':['EXAMPLE.*']}};const e=entitlementsFor(p,o);assert.equal(e['application-identifier'],'EXAMPLE.com.example.test');assert(!e['aps-environment']);assert.equal(p.entitlements['application-identifier'],'EXAMPLE.*');for(const bad of [{expires:'2000-01-01'},{certs:[]},{devices:[]},{entitlements:{'application-identifier':'EXAMPLE.com.another'}}])assert.throws(()=>entitlementsFor({...p,...bad},o));});

test('TNV1 packaging cannot cross-wire old firmware or addon',()=>{
  const n={...o,bundle:'com.rayneo.venus.pub','experimental-ota':'TNV1',firmware:'/example/TNV1.zip'};
  validateOptions(n);
  assert.throws(()=>validateOptions({...n,firmware:undefined}));
  assert.throws(()=>validateOptions({...n,'experimental-ota':'R3'}));
  assert.throws(()=>validateResearchPair('_TNVStart','R3'));
  assert.throws(()=>validateResearchPair('','TNV1',Buffer.alloc(0)));
  assert.throws(()=>validateResearchPair('_TNVStart','TNV1',Buffer.alloc(9258094)));
  validateResearchPair('',undefined);
  validateResearchPair('','R3');
});
