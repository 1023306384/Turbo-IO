import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import * as audio from 'libturbo_audio.so';
import { businessEnvelope,readLauncherEnvelope } from 'turbo_core';
import { RecordingCoverage,stereoWavHeader } from './RecordingCoverage';

export class RecordingItem { name:string='';created:number=0;bytes:number=0;complete:boolean=false;note:string='';textFile:string=''; }
class RecordingManifest {
  version:number=1;uuid:string='';peer:string='';created:number=0;completed:boolean=false;
  valid:boolean=true;wavReady:boolean=false;coverage:number[][]=[];
}
interface RecordCommand { uuid?:string;action?:number;code?:number;mode?:number;type?:number;isAppForeground?:boolean; }

// Explicit opt-in online profile. No cloud upload, deletion, offline catch-up or
// microphone permission. Partial files are retained; completion is never guessed.
export class RecordingSession {
  enabled:boolean=false;active:boolean=false;busy:boolean=false;bytes:number=0;
  starting:boolean=false;
  note:string='录音接收未开启';items:RecordingItem[]=[];
  changed:()=>void=():void=>{};
  private root:string='';private directory:string='';private raw:fs.File|undefined=undefined;
  private manifest:RecordingManifest=new RecordingManifest();private coverage:RecordingCoverage=new RecordingCoverage();
  private sender:(business:number,payload:Uint8Array)=>Promise<void>;
  private device:()=>string;private idle:()=>boolean;
  private timer:number=-1;private grace:number=-1;private startDeadline:number=-1;private generation:number=0;
  private queue:Promise<void>=Promise.resolve();private queued:number=0;private finalizing:boolean=false;
  constructor(sender:(business:number,payload:Uint8Array)=>Promise<void>,device:()=>string,idle:()=>boolean){this.sender=sender;this.device=device;this.idle=idle;}
  initialize(context:common.Context):void{
    this.root=context.filesDir+'/recordings';if(!fs.accessSync(this.root))fs.mkdirSync(this.root);this.refresh();
  }
  refresh():void{
    if(!this.root)return;const rows:RecordingItem[]=[];
    for(const name of fs.listFileSync(this.root)){
      if(!/^take-[0-9a-f]{32}$/.test(name))continue;
      try{
        const path=this.root+'/'+name,raw=fs.readTextSync(path+'/manifest.json');if(raw.length>100000)continue;
        const m=JSON.parse(raw) as RecordingManifest;if(m.version!==1||!Number.isSafeInteger(m.created))continue;
        const row=new RecordingItem();row.name=name;row.created=m.created;row.bytes=fs.statSync(path+'/source.rawopus').size;
        row.complete=this.validWav(path,m,row.bytes);
        row.note=row.complete?'已完成覆盖校验与立体声解码':'原始录音已保留 · 未通过完整封装';rows.push(row);
        row.textFile=fs.listFileSync(path).filter(p=>/^transcript-\d+\.md$/.test(p)).sort().pop()||'';
      }catch(_){/* Preserve unreadable directories, never repair by deletion. */}
    }
    this.items=rows.sort((a,b)=>b.created-a.created);this.changed();
  }
  file(item:RecordingItem,wav:boolean):string{
    if(!this.root||!/^take-[0-9a-f]{32}$/.test(item.name))throw new Error('录音标识无效');
    const path=this.root+'/'+item.name;
    if(wav){
      const raw=fs.readTextSync(path+'/manifest.json');if(raw.length>100000)throw new Error('录音清单无效');
      if(!this.validWav(path,JSON.parse(raw) as RecordingManifest,fs.statSync(path+'/source.rawopus').size))throw new Error('此录音没有完整 WAV');
    }
    return path+(wav?'/audio.wav':'/source.rawopus');
  }
  private validWav(path:string,m:RecordingManifest,size:number):boolean{
    if(m.version!==1||m.wavReady!==true||m.completed!==true||m.valid!==true||!Number.isSafeInteger(size)||size<=0||size>33554432||size%240!==0)return false;
    if(!Array.isArray(m.coverage)||m.coverage.length!==1||m.coverage[0].length!==2||m.coverage[0][0]!==0||m.coverage[0][1]!==size)return false;
    return fs.accessSync(path+'/audio.wav')&&fs.statSync(path+'/audio.wav').size===44+size/240*1280;
  }
  textPath(item:RecordingItem):string{
    this.file(item,false);if(!/^transcript-\d+\.md$/.test(item.textFile))throw new Error('没有已保存的转写');return this.root+'/'+item.name+'/'+item.textFile;
  }
  saveTranscript(item:RecordingItem,text:string):void{
    this.file(item,true);if(!text.trim()||text.length>100000)throw new Error('转写文字无效');
    const path=this.root+'/'+item.name+'/transcript-'+Date.now()+'.md';if(fs.accessSync(path))throw new Error('已有同名转写，未覆盖');
    const file=fs.openSync(path,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY);
    try{this.write(file.fd,new util.TextEncoder().encodeInto(`# 眼镜录音转写\n\n录音时间：${new Date(item.created).toISOString()}\n\n${text}\n`),0);fs.fsyncSync(file.fd);}finally{fs.closeSync(file);}
    this.refresh();
  }
  private random():string{const b=cryptoFramework.createRandom().generateRandomSync(16).data;const id=Array.from(b).map((n:number)=>n.toString(16).padStart(2,'0')).join('');b.fill(0);return id;}
  private persist():void{
    this.manifest.coverage=this.coverage.ranges.map(r=>[r.start,r.end]);this.manifest.valid=!this.coverage.invalid;
    // Same directory temporary manifest + rename: a torn journal never labels raw audio complete.
    const path=this.directory+'/manifest.next';const file=fs.openSync(path,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
    try{this.write(file.fd,new util.TextEncoder().encodeInto(JSON.stringify(this.manifest)),0);fs.fsyncSync(file.fd);}finally{fs.closeSync(file);}
    fs.renameSync(path,this.directory+'/manifest.json');
  }
  private write(fd:number,data:Uint8Array,position:number):void{
    fs.lseek(fd,position,fs.WhenceType.SEEK_SET);
    let written=0;while(written<data.length){const n=fs.writeSync(fd,data.slice(written).buffer);if(n<=0)throw new Error('录音写入不完整');written+=n;}
  }
  private read(fd:number,position:number,length:number):Uint8Array{
    fs.lseek(fd,position,fs.WhenceType.SEEK_SET);
    const out=new Uint8Array(length);let count=0;while(count<length){const part=new ArrayBuffer(length-count);const n=fs.readSync(fd,part,{length:length-count});if(n<=0)throw new Error('录音读取不完整');out.set(new Uint8Array(part,0,n),count);count+=n;}return out;
  }
  private async send(type:number,body:RecordCommand):Promise<void>{
    const payload=businessEnvelope(type,new util.TextEncoder().encodeInto(JSON.stringify(body)));try{await this.sender(14,payload);}finally{payload.fill(0);}
  }
  autoReceiveAllowed:boolean=true;
  async enable(enabled:boolean,automatic:boolean=false):Promise<void>{
    if(automatic&&!this.autoReceiveAllowed)return;
    if(this.active||this.finalizing)throw new Error('请先停止录音并等待归档');
    if(enabled){if(!this.root||!this.device()||!this.idle())throw new Error('请先连接眼镜，并关闭语音和其他显示任务');await this.send(14,{isAppForeground:true});}
    if(!automatic)this.autoReceiveAllowed=enabled;
    this.enabled=enabled;this.note=enabled?'已允许眼镜菜单发起录音 · 只存本机':'录音接收已关闭';this.changed();
  }
  private begin(uuid:string,peer:string):void{
    if(!this.root||!this.enabled||this.active||this.finalizing||!this.idle()||!peer||!/^[A-Za-z0-9-]{1,64}$/.test(uuid))throw new Error('不能开始录音');
    this.directory=this.root+'/take-'+this.random();fs.mkdirSync(this.directory);
    this.raw=fs.openSync(this.directory+'/source.rawopus',fs.OpenMode.CREATE|fs.OpenMode.READ_WRITE);
    this.coverage=new RecordingCoverage();this.manifest=new RecordingManifest();this.manifest.uuid=uuid;this.manifest.peer=peer;this.manifest.created=Date.now();
    try{this.persist();}catch(error){fs.closeSync(this.raw);this.raw=undefined;throw new Error('录音目录初始化失败，未请求眼镜开始');}
    this.active=true;this.starting=true;this.bytes=0;this.note='接收目录已准备 · 等待眼镜开始确认';
    const generation=this.generation;this.timer=setTimeout(()=>{if(generation===this.generation)this.stop().catch(()=>this.fail('自动停止未确认，请在眼镜结束录音'));},600000);this.changed();
  }
  async start():Promise<void>{
    if(this.busy)throw new Error('录音操作繁忙');this.busy=true;
    try{await this.enable(true);const id=this.random();this.begin(id,this.device());
      const generation=this.generation;
      this.startDeadline=setTimeout(()=>{this.startDeadline=-1;if(generation===this.generation&&this.active)this.fail('10 秒未收到开始回报；请在眼镜确认是否仍在录音');},10000);
      await this.send(1,{uuid:id,action:1,mode:1,code:1,type:1});if(this.startDeadline!==-1)this.note='开始指令已提交，等待眼镜确认';}
    catch(error){if(this.active)this.fail('开始未确认，原始目录已保留');throw new Error((error as Error).message);}
    finally{this.busy=false;this.changed();}
  }
  async stop():Promise<void>{
    if(!this.active)return;this.clearStartDeadline();await this.send(4,{uuid:this.manifest.uuid,action:1,code:2});this.note='停止已请求，等待音频尾包与完成回报';
    if(this.timer!==-1)clearTimeout(this.timer);const generation=this.generation;
    this.timer=setTimeout(()=>{if(generation===this.generation&&this.active&&!this.manifest.completed)this.fail('30 秒未收到完成回报；原始录音保留');},30000);this.changed();
  }
  disconnected():void{if(this.active||this.finalizing)this.fail('连接中断；保留原始录音，不自动宣布补传完成');this.enabled=false;}
  private clearStartDeadline():void{if(this.startDeadline!==-1)clearTimeout(this.startDeadline);this.startDeadline=-1;}
  private fail(note:string):void{
    this.generation++;this.coverage.invalid=true;this.active=false;this.starting=false;this.finalizing=false;this.note=note;
    this.clearStartDeadline();
    if(this.timer!==-1)clearTimeout(this.timer);if(this.grace!==-1)clearTimeout(this.grace);this.timer=-1;this.grace=-1;
    try{if(this.directory)this.persist();}catch(_){}
    if(this.raw){try{fs.closeSync(this.raw);}catch(_){}this.raw=undefined;}
    try{audio.recordingClose();}catch(_){}try{this.refresh();}catch(_){}this.changed();
  }
  receive(peer:string,bytes:Uint8Array):void{
    if(!this.enabled||!peer||peer!==this.device())return;
    if(this.queued>=32){this.fail('录音队列溢出，原始数据已保留');return;}
    const copy=bytes.slice(),generation=this.generation;this.queued++;
    const task=this.queue.then(async()=>{if(generation!==this.generation)return;await this.handle(peer,copy);});
    this.queue=task.catch(()=>{this.fail('录音包、存储或协议处理失败；不标记为完整');}).finally(()=>{copy.fill(0);this.queued--;});
  }
  private async handle(peer:string,bytes:Uint8Array):Promise<void>{
    const packet=readLauncherEnvelope(bytes);
    try{
      const j=JSON.parse(new util.TextDecoder().decodeToString(packet.json)) as Record<string,Object>;
      const uuid=j['uuid'];if(typeof uuid!=='string'||!/^[A-Za-z0-9-]{1,64}$/.test(uuid))return;
      if(packet.type===1&&j['action']===1){
        if(!this.active)this.begin(uuid,peer);
        if(uuid===this.manifest.uuid&&peer===this.manifest.peer)await this.send(1,{uuid:uuid,action:2,mode:1,code:1,type:1});
        return;
      }
      if(uuid!==this.manifest.uuid||peer!==this.manifest.peer)return;
      if(packet.type===3&&!this.active){this.fail('完成或中断后仍收到音频，请复核原始副本');return;}
      if(!this.active)return;
      if(packet.type===1&&j['action']===2){if(j['code']!==1)throw new Error('start-rejected');this.clearStartDeadline();this.starting=false;this.note='眼镜已确认开始录音';}
      if(packet.type===3){
        this.starting=false;
        this.clearStartDeadline();
        if(this.finalizing)throw new Error('late-audio');if(!this.raw)throw new Error('file-closed');
        const offset=j['offset'] as number,length=packet.binary.length;this.coverage.validate(offset,length);
        for(const range of this.coverage.overlap(offset,length)){const previous=this.read(this.raw.fd,range.start,range.end-range.start);const incoming=packet.binary.slice(range.start-offset,range.end-offset);if(!previous.every((b,i)=>b===incoming[i]))throw new Error('conflicting-overlap');}
        this.write(this.raw.fd,packet.binary,offset);fs.fsyncSync(this.raw.fd);this.coverage.accept(offset,length);this.persist();this.bytes=this.coverage.length();this.note='正在接收原始音频 · '+this.bytes+' B';
      }
      if(packet.type===4&&j['action']===1){await this.send(4,{uuid:uuid,action:2,code:typeof j['code']==='number'?j['code'] as number:1});this.note='收到停止，等待完成回报';}
      if([8,9,11].includes(packet.type)&&j['action']===1)await this.send(packet.type,{uuid:uuid,action:2,code:1});
      if(packet.type===6&&j['completed']===true&&!this.manifest.completed){
        this.clearStartDeadline();
        this.manifest.completed=true;this.persist();if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;const generation=this.generation;
        this.grace=setTimeout(()=>{this.grace=-1;this.queue.then(async():Promise<void>=>{if(generation===this.generation)await this.finish(generation);}).catch(()=>this.fail('封装失败，原始音频已保留'));},1000);
      }
      this.changed();
    }finally{packet.binary.fill(0);packet.json.fill(0);}
  }
  private async finish(generation:number):Promise<void>{
    if(!this.coverage.complete()||!this.manifest.completed||!this.raw)throw new Error('incomplete-coverage');
    this.finalizing=true;this.note='接收覆盖已通过，正在逐包解码';this.changed();
    const pcmLength=this.coverage.length()/240*1280;
    if(fs.accessSync(this.directory+'/decoded.partial'))throw new Error('保留已有未完成封装，请勿覆盖');
    const output=fs.openSync(this.directory+'/decoded.partial',fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY);
    let success=false;
    try{
      audio.recordingReset();this.write(output.fd,stereoWavHeader(pcmLength),0);
      for(let offset=0;offset<this.coverage.length();offset+=240){
        if(generation!==this.generation||!this.raw)throw new Error('cancelled');
        const raw=this.read(this.raw.fd,offset,240);let pcm=new Uint8Array();
        try{pcm=new Uint8Array(audio.recordingDecode(raw.buffer));if(pcm.length!==1280)throw new Error('wrong-pcm');this.write(output.fd,pcm,44+offset/240*1280);}
        finally{raw.fill(0);pcm.fill(0);}
        if(offset%12000===0)await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,0);});
      }
      fs.fsyncSync(output.fd);success=true;
    }finally{fs.closeSync(output);audio.recordingClose();}
    if(!success||generation!==this.generation)throw new Error('cancelled');
    fs.renameSync(this.directory+'/decoded.partial',this.directory+'/audio.wav');
    this.manifest.wavReady=true;this.persist();if(this.raw){fs.closeSync(this.raw);this.raw=undefined;}
    this.active=false;this.starting=false;this.finalizing=false;this.note='已保存原始音频与立体声 WAV；未上传、未转写。不能据此承诺无线原音无损。';this.refresh();
  }
}
