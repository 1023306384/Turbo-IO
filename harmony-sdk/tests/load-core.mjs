// Runs actual TS/ETS sources with explicit mocked platform modules, not a replica.
import fs from 'node:fs';
import vm from 'node:vm';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const deveco=process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts=require(`${deveco}/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript`);
export function loadCore(entry, platform={}, globals={}) {
 const cache=new Map();
 function load(name) {
  if(Object.hasOwn(platform,name))return platform[name];
  if(!/^\.\/[A-Za-z][A-Za-z0-9]*$/.test(name))throw Error('Unexpected module '+name);
  if(cache.has(name))return cache.get(name);
  const stem=new URL(`../turbo_core/src/main/ets/${name.slice(2)}`,import.meta.url);
  const file=fs.existsSync(`${stem.pathname}.ts`)?`${stem.pathname}.ts`:`${stem.pathname}.ets`;
  const output=ts.transpileModule(fs.readFileSync(file,'utf8'),{fileName:'core.ts',compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};
  vm.runInNewContext(output,{module,exports:module.exports,require:load,Uint8Array,ArrayBuffer,Error,...globals});
  cache.set(name,module.exports);return module.exports;
 }
 return load(entry);
}
