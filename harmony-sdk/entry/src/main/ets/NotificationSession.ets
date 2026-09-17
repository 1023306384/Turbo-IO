import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { businessEnvelope,readLauncherEnvelope } from 'turbo_core';
interface NoticeBody { notificationUID:string;appId:string;appName:string;title:string;subtitle:string;content:string;timestamp:string;category:number;reply:boolean;type:number; }
export class NotificationSession {
  enabled:boolean=false;busy:boolean=false;waiting:boolean=false;note:string='独立通知通道，未读取其他 App 通知';uid:string='';
  changed:()=>void=():void=>{};
  private peer:string='';private epoch:number=0;private timer:number=-1;
  private send:(business:number,payload:Uint8Array)=>Promise<void>;private device:()=>string;private idle:()=>boolean;
  constructor(send:(business:number,payload:Uint8Array)=>Promise<void>,device:()=>string,idle:()=>boolean){this.send=send;this.device=device;this.idle=idle;}
  private async submit(type:number,json:string):Promise<void>{const bytes=businessEnvelope(type,new util.TextEncoder().encodeInto(json));try{await this.send(21,bytes);}finally{bytes.fill(0);}}
  private check():void{if(this.busy||this.waiting)throw new Error('上一条操作尚未结束');if(!this.device()||!this.idle())throw new Error('请连接眼镜，并结束其他显示、录音或语音任务');}
  async setEnabled(enabled:boolean):Promise<void>{
    this.check();this.busy=true;this.changed();const epoch=this.epoch,peer=this.device();
    try{await this.submit(18,JSON.stringify({notification:enabled}));if(epoch!==this.epoch)return;this.peer=peer;this.enabled=enabled;this.note='通知总开关已提交，未修改来源、停留时长或来电设置';}
    finally{if(epoch===this.epoch){this.busy=false;this.changed();}}
  }
  async notify(title:string,content:string):Promise<void>{
    this.check();if(!this.enabled||this.peer!==this.device())throw new Error('请先向当前眼镜应用通知开关');
    if(!title.trim()||title.length>16||!content.trim()||content.length>48||/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(title+content))throw new Error('测试通知标题 1–16 字，正文 1–48 字');
    const bytes=cryptoFramework.createRandom().generateRandomSync(4).data;let value=0;for(const b of bytes)value=value*256+b;bytes.fill(0);this.uid=String(value%2147483646+1);
    const d=new Date(),pad=(v:number,width:number=2):string=>String(v).padStart(width,'0');
    const timestamp=`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(),3)}`;
    const body:NoticeBody={notificationUID:this.uid,appId:'org.turboio.harmony.research',appName:'Turbo IO',title:title,subtitle:'',content:content,timestamp:timestamp,category:0,reply:false,type:1};
    const epoch=this.epoch;this.waiting=true;this.busy=true;this.note='发送中，等待同 UID 的眼镜状态';this.changed();
    this.timer=setTimeout(()=>{this.timer=-1;if(epoch===this.epoch&&this.waiting){this.waiting=false;this.note='8 秒未收到匹配状态，不代表镜片已显示；未自动重发';this.changed();}},8000);
    try{await this.submit(2,JSON.stringify(body));}
    catch(error){if(epoch===this.epoch){this.clearWait();this.note='通知提交失败，不算显示成功';}throw new Error((error as Error).message);}
    finally{if(epoch===this.epoch){this.busy=false;this.changed();}}
  }
  receive(peer:string,payload:Uint8Array):void{
    if(!this.peer||peer!==this.peer||peer!==this.device())return;
    try{this.read(payload);}catch(_){/* Malformed notifications cannot close the authenticated link. */}
  }
  private read(payload:Uint8Array):void{
    const packet=readLauncherEnvelope(payload);
    try{
      // Never parse/retain ANCS type1 text. Operations are observations, not tools.
      if(![3,4,18].includes(packet.type)||packet.binary.length)return;
      const j=JSON.parse(new util.TextDecoder().decodeToString(packet.json)) as Record<string,Object>;
      if(packet.type===18){if(j['notification']===false)this.enabled=false;this.changed();return;}
      if(j['notificationUID']!==this.uid)return;
      if(packet.type===3&&typeof j['state']==='number'){
        const state=j['state'] as number,labels:string[]=['空闲（不代表已读）','显示中或间隔期，镜片效果待确认','未佩戴','勿扰模式','其他功能占用'];this.clearWait();this.note='同 UID 回报：'+(labels[state]||'未知状态，不算成功');
      }
      if(packet.type===4&&typeof j['cmd']==='number')this.note='收到同 UID 的眼镜操作；未执行任何模型或工具';
      this.changed();
    }catch(_){/* Invalid or private third-party payloads are not logged. */}
    finally{packet.json.fill(0);packet.binary.fill(0);}
  }
  private clearWait():void{if(this.timer!==-1)clearTimeout(this.timer);this.timer=-1;this.waiting=false;}
  disconnected():void{this.epoch++;this.clearWait();this.enabled=false;this.busy=false;this.peer='';this.uid='';this.note='连接已变化；请重新应用通知开关，不自动覆盖';this.changed();}
}
