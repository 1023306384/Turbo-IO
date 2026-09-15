import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {inspectedHost,inspectedHosts} from './host-compatibility.mjs';
test('native and packaging allowlists agree; mismatches fail closed',()=>{
  const native=fs.readFileSync(new URL('./HostCompatibility.h',import.meta.url),'utf8').replaceAll('-','').toLowerCase();
  for(const h of inspectedHosts){
    const info={CFBundleIdentifier:'com.rayneo.venus.pub',CFBundleExecutable:'Runner',CFBundleShortVersionString:h.version,CFBundleVersion:h.build};
    assert.equal(inspectedHost(info,h.uuid),h);assert.ok(native.includes(h.uuid));
    assert.equal(inspectedHost({...info,CFBundleVersion:'999'},h.uuid),null);
    assert.equal(inspectedHost({...info,CFBundleIdentifier:'other'},h.uuid),null);
    assert.equal(inspectedHost({...info,CFBundleExecutable:'Other'},h.uuid),null);
    assert.equal(inspectedHost(info,'0'.repeat(32)),null);
  }
  assert.equal(inspectedHost({},null),null);
});
