import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { OutboundFile,FileMessage,fileMessage,businessEnvelope,readLauncherEnvelope } from 'turbo_core';

interface PrompterBody { did:string;action:number;total?:number;scroll?:number;speed?:number;pageOffset?:number;highLightOffset?:number;offset?:number;code?:number;isCompleted?:boolean;checksum?:string; }
// Same UTF-8 FNV-1a contract as iOS TIONewsTeleChecksum, distinct from file MD5.
export function teleprompterChecksum(bytes:Uint8Array):string {
  let hash=2166136261;for(const b of bytes)hash=Math.imul(hash^b,16777619)>>>0;
  return hash.toString(16).padStart(8,'0');
}
export class TeleprompterSession {
  private checksum:string='';
  phase:string='idle';note:string='选择稿件，完整传输后再开始提词';progress:number=0;offset:number=0;speed:number=120;
  changed:()=>void=():void=>{};
  private did:string='';private peer:string='';private total:number=0;private file:OutboundFile|undefined=undefined;
  private fileStarted:boolean=false;private businessReady:boolean=false;private epoch:number=0;private timer:number=-1;
  private pendingControl:number=0;private beforeControl:string='ready';
  private queue:Promise<void>=Promise.resolve();private queued:number=0;
  private send:(business:number,payload:Uint8Array)=>Promise<void>;private device:()=>string;private idle:()=>boolean;
  constructor(send:(business:number,payload:Uint8Array)=>Promise<void>,device:()=>string,idle:()=>boolean){this.send=send;this.device=device;this.idle=idle;}
  get active():boolean{return this.phase!=='idle';}
  private emit():void{this.changed();}
  private deadline(ms:number,message:string):void{if(this.timer!==-1)clearTimeout(this.timer);const epoch=this.epoch;this.timer=setTimeout(()=>{this.timer=-1;if(epoch===this.epoch&&this.active)this.error(message);},ms);}
  private serialize(action:()=>Promise<void>):Promise<void>{const task=this.queue.catch(()=>{}).then(action);this.queue=task.catch(()=>{});return task;}
  private async command(type:number,body:PrompterBody):Promise<void>{const bytes=businessEnvelope(type,new util.TextEncoder().encodeInto(JSON.stringify(body)));try{await this.send(20,bytes);}finally{bytes.fill(0);}}
  async prepare(text:string,speed:number):Promise<void>{
    if(this.active||!this.device()||!this.idle())throw new Error('请先连接眼镜，关闭语音、录音及其他显示');
    if(!Number.isInteger(speed)||speed<60||speed>240||!text.trim()||text.length>12000)throw new Error('稿件限 12000 字，速度 60–240');
    const bytes=new util.TextEncoder().encodeInto(text);if(bytes.length>48000){bytes.fill(0);throw new Error('稿件 UTF-8 超过 48000 字节');}
    const epoch=++this.epoch;this.phase='preparing';this.peer=this.device();this.total=bytes.length;this.checksum=teleprompterChecksum(bytes);this.speed=speed;this.progress=0;this.offset=0;this.businessReady=false;this.fileStarted=false;
    const random=cryptoFramework.createRandom().generateRandomSync(16).data;random[6]=(random[6]&15)|64;random[8]=(random[8]&63)|128;
    const id=Array.from(random).map((n:number)=>n.toString(16).padStart(2,'0')).join('');random.fill(0);
    this.did=id.slice(0,8)+'-'+id.slice(8,12)+'-'+id.slice(12,16)+'-'+id.slice(16,20)+'-'+id.slice(20);this.note='正在计算稿件摘要，正文不会上传云端';this.emit();
    try{
      const digest=cryptoFramework.createMd('MD5');await digest.update({data:bytes});const hash=await digest.digest();
      if(epoch!==this.epoch)return;
      const md5=Array.from(hash.data).map((n:number)=>n.toString(16).padStart(2,'0')).join('');hash.data.fill(0);
      this.file=new OutboundFile(this.did,bytes,md5);this.deadline(30000,'准备未收到完整回报，请退出本轮再试');
      await this.serialize(async()=>{if(epoch!==this.epoch)return;await this.command(2,{did:this.did,action:1,total:this.total,checksum:this.checksum,scroll:2,speed:speed,pageOffset:0,highLightOffset:0});});
      if(epoch===this.epoch){this.note='准备请求已提交，等待眼镜允许传稿';this.emit();}
    }catch(error){if(epoch===this.epoch)this.error('稿件准备失败，请退出后重试');throw new Error((error as Error).message);}
    finally{bytes.fill(0);}
  }
  receive(peer:string,business:number,payload:Uint8Array):void{
    if(!this.active||peer!==this.peer||peer!==this.device()||![18,20].includes(business))return;
    if(this.queued>=16){this.error('提词器接收队列超限，请退出本轮');return;}
    const copy=payload.slice(),epoch=this.epoch;this.queued++;
    this.serialize(async()=>{if(epoch===this.epoch)await this.handle(business,copy,epoch);}).catch(()=>{if(epoch===this.epoch)this.error('传稿或眼镜回报失败，未宣告完整收稿');}).finally(()=>{copy.fill(0);this.queued--;});
  }
  private async handle(business:number,bytes:Uint8Array,epoch:number):Promise<void>{
    if(business===18){
      if(!this.fileStarted||!this.file||['error','closing'].includes(this.phase))return;
      const file=this.file,m=file.receive(bytes);
      if(m){const payload=fileMessage(m);try{await this.send(18,payload);if(epoch!==this.epoch)return;file.committed(m);}finally{payload.fill(0);m.data.fill(0);}}
      if(epoch!==this.epoch)return;this.progress=Math.floor(file.sentBytes*100/this.total);
      this.note=file.complete?'眼镜文件层确认完整收稿；等待提词业务就绪':'文件传输 '+this.progress+'% · 未宣告镜片显示';
      this.ready();this.emit();return;
    }
    const packet=readLauncherEnvelope(bytes);
    try{
      const body=JSON.parse(new util.TextDecoder().decodeToString(packet.json)) as Record<string,Object>;
      if(body['did']!==this.did)return;
      const action=body['action'],code=body['code'];
      if(packet.type===6&&(action===1||(action===2&&code===1))){if(action===1)await this.command(6,{did:this.did,action:2,code:1});if(epoch===this.epoch)this.clear('提词已退出，稿件仍保存在手机');return;}
      if(['error','closing'].includes(this.phase))return;
      if(packet.type===2&&action===2){
        if(code!==1&&code!==7)throw new Error('prepare-rejected');
        if(!this.fileStarted&&code!==1)throw new Error('completion-before-file');
        if(!this.fileStarted){if(!this.file)throw new Error('file-not-ready');this.fileStarted=true;this.phase='transferring';this.deadline(120000,'两分钟内未确认整稿收取，请退出后重试');const payload=this.file.info();try{await this.send(18,payload);}finally{payload.fill(0);}if(epoch===this.epoch)this.note='文件信息已发送，按眼镜请求分块传稿';}
        else if(code===7){this.businessReady=true;this.ready();}
      }
      if([3,4,5,7].includes(packet.type)&&action===2&&this.phase==='controlling'&&packet.type===this.pendingControl){
        if(code!==1)throw new Error('control-rejected');
        if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;
        if(packet.type===3||packet.type===5)this.phase='running';if(packet.type===4)this.phase='paused';
        if(packet.type===7)this.phase=this.beforeControl;this.pendingControl=0;
        this.note='眼镜已确认'+(this.phase==='running'?'匀速提词':this.phase==='paused'?'暂停':'速度修改');
      }
      if([4,5,7,8].includes(packet.type)&&action===1){
        if(packet.type===8){const value=body['pageOffset'];if(typeof value==='number'&&Number.isSafeInteger(value)&&value>=0&&value<=this.total)this.offset=value;}
        if(packet.type===4)this.phase='paused';if(packet.type===5)this.phase='running';
        if(packet.type===7){const speed=body['speed'];if(typeof speed==='number'&&speed>=60&&speed<=240)this.speed=speed;}
        await this.command(packet.type,{did:this.did,action:2,code:1});
        if(epoch===this.epoch)this.note='已收到眼镜操作 / 阅读位置回传';
      }
      this.emit();
    }finally{packet.json.fill(0);packet.binary.fill(0);}
  }
  private ready():void{if(this.phase==='transferring'&&this.businessReady&&this.file?.complete){this.phase='ready';if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;this.note='文件与提词业务均已确认，点开始匀速提词';}}
  async control(type:number,speed:number=this.speed):Promise<void>{
    if(![3,4,5,7].includes(type)||!['ready','running','paused'].includes(this.phase))throw new Error('请先等整稿就绪，或结束上一项控制');
    if(type===3&&this.phase!=='ready'||type===4&&this.phase!=='running'||type===5&&this.phase!=='paused')throw new Error('当前阶段不能执行此动作');
    if(!Number.isInteger(speed)||speed<60||speed>240)throw new Error('速度 60–240');
    const body:PrompterBody={did:this.did,action:1};if(type===4){body.offset=this.offset;body.code=1;body.isCompleted=false;}if(type===7){body.scroll=2;body.speed=speed;this.speed=speed;}
    if(type===3){body.total=this.total;body.checksum=this.checksum;body.scroll=2;body.speed=this.speed;body.pageOffset=0;body.highLightOffset=0;}
    this.beforeControl=this.phase;this.pendingControl=type;this.phase='controlling';const epoch=this.epoch;this.deadline(10000,'控制回报超时，请先退出本轮');
    try{await this.serialize(async()=>{if(epoch===this.epoch)await this.command(type,body);});}catch(error){if(epoch===this.epoch)this.error('控制未提交，请退出本轮');throw new Error((error as Error).message);}
    this.emit();
  }
  async stop():Promise<void>{
    if(!this.active)return;const did=this.did,started=this.fileStarted,epoch=++this.epoch;this.file?.close();this.phase='closing';this.note='正在退出，请等待眼镜确认';this.deadline(10000,'退出未确认；请按眼镜实体按钮退出后再操作');this.emit();
    await this.serialize(async()=>{if(epoch!==this.epoch)return;
      if(started){const m=new FileMessage();m.type=6;m.uuid=did;m.reason='user-stop';const bytes=fileMessage(m);try{await this.send(18,bytes);}finally{bytes.fill(0);}}
      await this.command(6,{did:did,action:1});
    });
  }
  disconnected():void{if(this.active)this.clear('连接中断；未自动续传或重新开始提词');}
  private error(note:string):void{this.epoch++;if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;this.file?.close();this.phase='error';this.note=note;this.emit();}
  private clear(note:string):void{this.epoch++;if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;this.file?.close();this.file=undefined;this.did='';this.peer='';this.fileStarted=false;this.businessReady=false;this.phase='idle';this.note=note;this.emit();}
}
