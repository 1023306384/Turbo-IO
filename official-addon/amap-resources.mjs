// Pure preflight and explicit resource copy for the optional static SDK build.
import fs from 'node:fs';
import path from 'node:path';
export function amapResources(root){
  if(!path.isAbsolute(root))throw Error('amap_absolute_root_required');
  const items=[['navi/AMapNaviKit.framework/AMap.bundle','AMap.bundle'],['navi/AMapNaviKit.framework/AMapNavi.bundle','AMapNavi.bundle'],['search/AMapSearchKit.framework/AMapSearch.bundle','AMapSearch.bundle']];
  function inspect(p){const s=fs.lstatSync(p);if(s.isSymbolicLink())throw Error('amap_symlink_requires_review');if(s.isDirectory())for(const n of fs.readdirSync(p))inspect(path.join(p,n));else if(!s.isFile())throw Error('amap_regular_resources_required');}
  return items.map(([rel,name])=>{const source=path.join(root,rel);if(!fs.existsSync(source)||!fs.statSync(source).isDirectory())throw Error('amap_resources_missing');inspect(source);return {source,name};});
}
export function copyAMapResources(resources,app){for(const r of resources)if(fs.existsSync(path.join(app,r.name)))throw Error('amap_resource_collision');for(const r of resources)fs.cpSync(r.source,path.join(app,r.name),{recursive:true,force:false,errorOnExist:true});}
