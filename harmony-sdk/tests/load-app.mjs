import fs from 'node:fs';import vm from 'node:vm';import {createRequire} from 'node:module';import {loadCore} from './load-core.mjs';
const require=createRequire(import.meta.url);const deveco=process.env.DEVECO_HOME||'/Applications/DevEco-Studio.app/Contents';const ts=require(`${deveco}/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript`);
export function loadApp(name,platform={},globals={}) {
 if(!['AmapNativeServices','AmapNavigationSession','ConnectedServices','DeviceFeatures','RemoteServices','CloudASR','VoiceSession','ConnectionStore','ProbeSession','BluetoothBackground','NavigationProgress','NavigationSession','LocalWorkspace','RecordingCoverage','RecordingSession','RecordingASR','TeleprompterSession','NotificationSession'].includes(name))throw Error('app-module-not-allowed');
 const source=fs.readFileSync(new URL(`../entry/src/main/ets/${name}.ets`,import.meta.url),'utf8');
 const compiled=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
 const module={exports:{}};const core={...loadCore('./BusinessCommands'),...loadCore('./LauncherStatus'),...loadCore('./VoiceCommands'),...loadCore('./FileTransfer')};
 const kits={'@kit.ArkTS':{util:{TextEncoder:class {encodeInto(s){return new TextEncoder().encode(s);}},TextDecoder:class {decodeToString(b){return new TextDecoder().decode(b);}}}},...platform};
 vm.runInNewContext(compiled,{module,exports:module.exports,require:n=>{if(Object.hasOwn(kits,n))return kits[n];if(n==='turbo_core')return core;throw Error(`missing module ${n}`);},Uint8Array,ArrayBuffer,Map,Error,JSON,...globals});return module.exports;
}
