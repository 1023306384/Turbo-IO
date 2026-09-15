import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {audit} from './check-source.mjs';

function fixture(files,run){
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'turbo-source-audit-'));
  try{for(const [name,value] of Object.entries(files)){const file=path.join(root,name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,value);}run(audit(root));}
  finally{fs.rmSync(root,{recursive:true,force:true});}
}
test('allows blank-key original Android source',()=>{
  fixture({'SecretStore.java':'String apiKey = "";'},r=>assert.deepEqual(r.findings,[]));
});
test('rejects model key without returning the secret',()=>{
  const fake='sk-'+'z'.repeat(24);
  fixture({'settings.json':JSON.stringify({api_key:fake})},r=>{
    assert.ok(r.findings.some(f=>f.rule==='api-key'));
    assert.ok(!JSON.stringify(r).includes(fake));
  });
});
for(const extension of ['apk','dex','jar','jks','keystore','jsonl']){
  test('rejects '+extension+' artifacts',()=>fixture({['sample.'+extension]:'fixture'},r=>assert.ok(r.findings.some(f=>f.rule==='non-source-artifact'))));
}
test('rejects private developer home paths',()=>{
  fixture({'build.sh':'sdk="'+['','Users','sample-person','Library','Android','sdk'].join('/')+'"'},r=>assert.ok(r.findings.some(f=>f.rule==='private-home')));
});
test('permits generated build directory without treating it as publishable',()=>{
  fixture({'build/output.dex':'fixture','README.md':'Source only'},r=>{assert.equal(r.files,1);assert.deepEqual(r.findings,[]);});
});
