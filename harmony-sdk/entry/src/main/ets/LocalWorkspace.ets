import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { businessEnvelope, readLauncherEnvelope } from 'turbo_core';

export class WorkspaceTodo {
  id: number = 0; title: string = ''; completed: boolean = false; important: boolean = false;
  created: number = 0; modified: number = 0; revision: number = 1;
  peer: string = ''; delivery: string = 'local'; observed: number = -1;
}
export class WorkspaceEntry {
  id: string = ''; kind: string = 'conversation'; title: string = ''; text: string = '';
  answer: string = ''; model: string = ''; created: number = 0;
}
class WorkspaceData { version: number = 1; todos: WorkspaceTodo[] = []; entries: WorkspaceEntry[] = []; }
interface TodoBody { eventType:number;eventID:number;createTime:number;title:string;isImportant:boolean;status:number;lastModifiedTime:number; }

// Separate private store. No credentials, raw voice or GPS tracks. Flush before
// publishing any successful local edit or assigning a wire identity.
export class LocalWorkspace {
  todos: WorkspaceTodo[] = []; entries: WorkspaceEntry[] = [];
  ready: boolean = false; note: string = '正在读取本机资料';
  changed: ()=>void = ():void=>{};
  private context: common.Context|undefined = undefined;
  private chain: Promise<void> = Promise.resolve();
  private sending: boolean = false;
  private storageUncertain: boolean = false;
  async load(context:common.Context):Promise<void>{
    if(this.storageUncertain)throw new Error('上一轮存储结果不确定，请重新启动应用后复核资料');
    if(this.ready)return;this.context=context;
    try{
      const prefs=await preferences.getPreferences(context,{name:'turboio_workspace_v1'});
      const raw=await prefs.get('data','');
      if(raw!==''){
        if(typeof raw!=='string'||raw.length>2000000)throw new Error('invalid-store');
        const data=JSON.parse(raw) as WorkspaceData;
        if(data.version!==1||!Array.isArray(data.todos)||data.todos.length>200||!Array.isArray(data.entries)||data.entries.length>500)throw new Error('invalid-store');
        const ids:number[]=[];
        for(const row of data.todos){
          if(!Number.isSafeInteger(row.id)||row.id<=0||ids.includes(row.id)||typeof row.title!=='string'||row.title.length>60||!row.title.trim()||typeof row.completed!=='boolean'||typeof row.important!=='boolean'||!Number.isSafeInteger(row.revision)||row.revision<1||!Number.isSafeInteger(row.created)||!Number.isSafeInteger(row.modified)||!['local','pending','submitted','confirmed','conflict'].includes(row.delivery)||typeof row.peer!=='string'||(row.peer!==''&&!/^[0-9a-f]{12}$/.test(row.peer))||![-1,0,1].includes(row.observed))throw new Error('invalid-store');
          ids.push(row.id);
        }
        for(const row of data.entries){if(typeof row.id!=='string'||!['conversation','manuscript'].includes(row.kind)||typeof row.text!=='string'||row.text.length>100000||typeof row.answer!=='string'||row.answer.length>8000||typeof row.title!=='string'||row.title.length>100||typeof row.model!=='string'||row.model.length>200||!Number.isSafeInteger(row.created))throw new Error('invalid-store');}
        this.todos=data.todos;this.entries=data.entries;
      }
      this.ready=true;this.note='资料仅保存在本机';
    }catch(_){this.ready=false;this.note='资料读取失败，保留原数据，不自动重建或覆盖';}
    this.changed();
  }
  private mutate(edit:(data:WorkspaceData)=>void):Promise<void>{
    const job=this.chain.catch(()=>{}).then(async()=>{
      if(!this.ready||!this.context)throw new Error('本机资料尚未就绪');
      const current=new WorkspaceData();current.todos=this.todos;current.entries=this.entries;
      const data=JSON.parse(JSON.stringify(current)) as WorkspaceData;edit(data);
      const serialized=JSON.stringify(data);if(serialized.length>1900000)throw new Error('本机资料接近容量上限，请先导出并整理');
      const prefs=await preferences.getPreferences(this.context,{name:'turboio_workspace_v1'});
      try{await prefs.put('data',serialized);await prefs.flush();}
      catch(_){this.storageUncertain=true;this.ready=false;this.note='存储结果未确认，已停止后续写入；请重启应用复核，原数据不清除';this.changed();throw new Error(this.note);}
      this.todos=data.todos;this.entries=data.entries;this.note='本机修改已保存';this.changed();
    });this.chain=job;return job;
  }
  private id():number{
    const bytes=cryptoFramework.createRandom().generateRandomSync(6).data;
    let id=0;for(const b of bytes)id=id*256+b;bytes.fill(0);return id;
  }
  addTodo(title:string):Promise<void>{
    title=title.trim();if(!title||title.length>60)return Promise.reject(new Error('待办标题限 1–60 字'));
    return this.mutate(data=>{if(data.todos.length>=200)throw new Error('待办最多 200 条');
      const row=new WorkspaceTodo();row.id=this.id();if(!row.id||data.todos.some(t=>t.id===row.id))throw new Error('标识生成冲突，请重试');
      row.title=title;row.created=Math.floor(Date.now()/1000);row.modified=row.created;data.todos.unshift(row);
    });
  }
  editTodo(id:number,title:string,completed:boolean):Promise<void>{
    if(!title.trim()||title.trim().length>60)return Promise.reject(new Error('待办标题限 1–60 字'));
    return this.mutate(data=>{const row=data.todos.find(t=>t.id===id);if(!row)throw new Error('待办不存在');
      row.title=title.trim();row.completed=completed;row.modified=Math.floor(Date.now()/1000);row.revision++;
      row.delivery=row.observed>=0?'conflict':row.peer?'pending':'local';
    });
  }
  resolveTodo(id:number,acceptGlasses:boolean):Promise<void>{
    return this.mutate(data=>{const row=data.todos.find(t=>t.id===id);if(!row||row.observed<0)throw new Error('没有待处理冲突');
      if(acceptGlasses)row.completed=row.observed===1;
      row.observed=-1;row.revision++;row.modified=Math.floor(Date.now()/1000);row.delivery=acceptGlasses?'confirmed':'pending';
    });
  }
  async sendTodo(id:number,peer:string,send:(business:number,payload:Uint8Array)=>Promise<void>):Promise<void>{
    peer=this.normalizePeer(peer);
    if(this.sending)throw new Error('上一条仍在发送');if(!/^[0-9a-f]{12}$/.test(peer))throw new Error('尚未确认眼镜身份');
    this.sending=true;
    try{
      await this.mutate(data=>{const row=data.todos.find(t=>t.id===id);if(!row)throw new Error('待办不存在');
        if(row.peer&&row.peer!==peer)throw new Error('这条待办属于另一副眼镜，未发送');
        if(row.delivery==='conflict')throw new Error('请先处理完成状态冲突');
        row.peer=peer;row.delivery='pending';
      });
      const row=this.todos.find(t=>t.id===id);if(!row)throw new Error('待办不存在');const revision=row.revision;
      const body:TodoBody={eventType:1,eventID:row.id,createTime:row.created,title:row.title,isImportant:row.important,status:row.completed?1:0,lastModifiedTime:row.modified};
      const packet=businessEnvelope(2,new util.TextEncoder().encodeInto(JSON.stringify(body)));
      try{await send(22,packet);}finally{packet.fill(0);}
      await this.mutate(data=>{const current=data.todos.find(t=>t.id===id);if(current&&current.revision===revision&&current.delivery==='pending')current.delivery='submitted';});
      this.note='已提交单条；等待眼镜状态回传，不代表镜片已显示';this.changed();
    }finally{this.sending=false;}
  }
  receiveTodo(peer:string,bytes:Uint8Array):void{
    peer=this.normalizePeer(peer);
    if(!this.ready||!/^[0-9a-f]{12}$/.test(peer))return;
    try{
      const envelope=readLauncherEnvelope(bytes);if(![4,10].includes(envelope.type))return;
      const json=JSON.parse(new util.TextDecoder().decodeToString(envelope.json)) as Record<string,Object>;
      let rows:Record<string,Object>[]=[];
      if(envelope.type===4)rows=[json];
      else if(Array.isArray(json['eventList']))rows=(json['eventList'] as Record<string,Object>[]).filter(r=>r['eventType']===1);
      if(rows.length>200)return;
      const updates=rows.filter(r=>Number.isSafeInteger(r['eventID'])&&[0,1].includes(r['status'] as number)&&this.todos.some(t=>t.id===r['eventID']&&t.peer===peer));
      if(!updates.length)return;
      this.mutate(data=>{for(const update of updates){const row=data.todos.find(t=>t.id===update['eventID']&&t.peer===peer);if(!row)continue;
        const completed=update['status']===1;
        if(['pending','conflict'].includes(row.delivery)){row.observed=completed?1:0;row.delivery='conflict';continue;}
        row.completed=completed;row.delivery='confirmed';row.observed=-1;
        if(typeof update['isImportant']==='boolean')row.important=update['isImportant'] as boolean;
      }}).catch(()=>{this.note='眼镜状态尚未保存，本机数据未覆盖';this.changed();});
    }catch(_){/* Invalid/unknown IDs never import or overwrite tasks. */}
  }
  private normalizePeer(peer:string):string {
    if(/^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(peer))return peer.replace(/:/g,'').toLowerCase();
    return /^[0-9a-fA-F]{12}$/.test(peer)?peer.toLowerCase():'';
  }
  conversation(id:string,text:string,answer:string,model:string):Promise<void>{
    if(!id||!text||!answer)return Promise.resolve();
    return this.mutate(data=>{if(data.entries.some(e=>e.id===id))return;if(data.entries.length>=500)throw new Error('资料已达 500 条，请先导出整理');
      const row=new WorkspaceEntry();row.id=id;row.title=text.slice(0,50);row.text=text.slice(0,4000);row.answer=answer.slice(0,8000);row.model=model.slice(0,200);row.created=Date.now();data.entries.unshift(row);
    });
  }
  manuscript(title:string,text:string):Promise<void>{
    if(!text.trim()||text.length>100000)return Promise.reject(new Error('稿件须有正文且不超过 10 万字'));
    return this.mutate(data=>{if(data.entries.length>=500)throw new Error('资料已达上限');const row=new WorkspaceEntry();row.id=`manuscript-${this.id()}`;row.kind='manuscript';row.title=title.trim().slice(0,100)||'未命名稿件';row.text=text;row.created=Date.now();data.entries.unshift(row);});
  }
  markdown(entry:WorkspaceEntry):string{
    return `# ${entry.title}\n\n${new Date(entry.created).toISOString()}\n\n${entry.kind==='conversation'?`## 我\n\n${entry.text}\n\n## 回答 · ${entry.model}\n\n${entry.answer}`:entry.text}\n`;
  }
}
export const localWorkspace: LocalWorkspace = new LocalWorkspace();
