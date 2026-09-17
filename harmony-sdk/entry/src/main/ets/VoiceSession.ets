import * as audio from 'libturbo_audio.so';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { businessEnvelope, readLauncherEnvelope, recorder, transcript, answerChunk, voiceChunks } from 'turbo_core';
import { ServiceConfig, RemoteServices } from './RemoteServices';
import { CloudASR } from './CloudASR';

export class VoiceState {
  enabled: boolean = false;
  phase: string = 'disabled';
  note: string = '语音未开启';
  transcript: string = '';
  answer: string = '';
  packets: number = 0;
  pcmBytes: number = 0;
  modelRequests: number = 0;
  modelReplies: number = 0;
  completedRounds: number = 0;
  lastResult: string = '';
}
// Wake interrupts immediately. A firmware next-turn offer listens without
// cancelling the answer/EOF deadline until real ASR text arrives.
export class VoiceSession {
  state: VoiceState = new VoiceState();
  canBegin: ()=>boolean = ():boolean=>true;
  get active():boolean { return ['recording','processing','displaying'].includes(this.state.phase); }
  changed: ()=>void = ():void=>{};
  completed: (id:string,text:string,answer:string,model:string)=>void = (_id:string,_text:string,_answer:string,_model:string):void=>{};
  private sender:(business:number,payload:Uint8Array)=>Promise<void>;
  private config:ServiceConfig = new ServiceConfig();
  private asr:CloudASR = new CloudASR();
  private model:RemoteServices = new RemoteServices();
  private epoch:number = 0;
  private ready:boolean = false;
  private timer:number = -1;
  private audioTimer:number = -1;
  private tail:Promise<void> = Promise.resolve();
  private queueCount:number = 0;
  private lastPartial:number = 0;
  private sid:string = '';
  private processing:boolean = false;
  private testReply:boolean = false;
  private listening:boolean = false;
  private listenSerial:number = 0;
  private followupEligible:boolean = false;
  private listenTimer:number = -1;
  constructor(sender:(business:number,payload:Uint8Array)=>Promise<void>){this.sender=sender;}
  connected(ready:boolean):void{this.ready=ready;if(!ready&&this.state.enabled)this.disable('连接已断，语音已停止');}
  enable(config:ServiceConfig,testReply:boolean=false):void{
    if(!this.ready)throw new Error('请先连接眼镜');
    if(!config.asrKey||(!testReply&&!config.modelKey)||!config.asrHost||!config.asrModel)throw new Error('请先保存 ASR 配置；真实问答另需模型 Key');
    this.disable('配置更新');this.testReply=testReply;this.config=config;this.state.enabled=true;this.state.phase='idle';this.state.note=testReply?'等待唤醒 · ASR + 本地校验文字（不是模型回答）':'等待眼镜唤醒 · 云端断句 · 支持再次唤醒打断';this.changed();
  }
  disable(note:string='语音已关闭'):void{
    const wasActive=['recording','processing','displaying'].includes(this.state.phase);
    this.epoch++;this.cleanup();this.state.enabled=false;this.state.phase='disabled';this.state.note=note;
    if(wasActive&&this.ready)this.exitCommands();this.changed();
  }
  private cleanup():void{
    this.closeListening();this.model.cancel();this.followupEligible=false;
    if(this.timer!==-1)clearTimeout(this.timer);if(this.audioTimer!==-1)clearTimeout(this.audioTimer);
    this.timer=-1;this.audioTimer=-1;this.processing=false;
  }
  private closeListening():void{
    this.listenSerial++;this.listening=false;this.asr.close();
    if(this.listenTimer!==-1)clearTimeout(this.listenTimer);this.listenTimer=-1;
    try{audio.close();}catch(_){}
  }
  private async write(type:number,json:string,token:number):Promise<void>{
    if(this.queueCount>=32)throw new Error('语音发送队列已满');this.queueCount++;
    let packet:Uint8Array;
    try{packet=businessEnvelope(type,new util.TextEncoder().encodeInto(json));}catch(_){this.queueCount--;throw new Error('语音消息编码失败');}
    const job=this.tail.then(async()=>{if(token!==this.epoch)throw new Error('stale-turn');await this.sender(13,packet);});
    this.tail=job.catch(()=>{});
    try{await job;}finally{packet.fill(0);this.queueCount--;}
  }
  private exitCommands():void{
    const token=this.epoch;
    this.write(2,recorder(false),token).then(()=>this.write(7,'{"rc":1}',token)).catch(()=>{});
  }
  receive(business:number,bytes:Uint8Array):void{
    if(business!==13||!this.state.enabled||!this.ready)return;
    try{
      const message=readLauncherEnvelope(bytes);
      try{
        if(message.type===1){if(this.state.phase!=='recording')this.begin();return;}
        if(message.type===11){
          if(this.followupEligible&&!this.listening&&this.canBegin()&&
            (this.state.phase==='processing'||this.state.phase==='displaying'))this.listen(true);
          return;
        }
        if(message.type===8){this.endRound('眼镜主动退出',false);return;}
        if(message.type!==3||!this.listening)return;
        if(message.binary.length===0)throw new Error('empty-audio');
        const pcm=new Uint8Array(audio.decode(message.binary.buffer));
        this.state.packets++;this.state.pcmBytes+=pcm.length;
        try{this.asr.append(pcm);}finally{pcm.fill(0);}
        if(this.state.packets===1||this.state.packets%50===0)this.changed();
      }finally{message.binary.fill(0);message.json.fill(0);}
    }catch(_){this.endRound('音频解码或协议异常，本轮已停止',true);}
  }
  private begin():void{
    if(!this.state.enabled||!this.ready||!this.canBegin())return;
    this.epoch++;this.cleanup();const token=this.epoch;
    const random=cryptoFramework.createRandom().generateRandomSync(16).data;
    this.sid=Array.from(random).map((b:number)=>b.toString(16).padStart(2,'0')).join('');random.fill(0);
    this.state.phase='recording';this.state.transcript='';this.state.answer='';this.state.packets=0;this.state.pcmBytes=0;
    this.state.note='唤醒已收到，正在连接阿里 ASR';this.lastPartial=0;
    this.listen(false);
    if(token!==this.epoch)return;
    this.audioTimer=setTimeout(()=>{if(token===this.epoch&&this.state.packets===0)this.endRound('6秒未收到眼镜音频，未伪造识别结果',true);},6000);
    this.timer=setTimeout(()=>{if(token===this.epoch)this.endRound('35秒收音保护到期',true);},35000);
    this.changed();
  }
  private listen(followup:boolean):void{
    this.closeListening();this.listening=true;
    const serial=this.listenSerial;let token=this.epoch;let waiting=followup;
    const random=cryptoFramework.createRandom().generateRandomSync(16).data;
    const task=Array.from(random).map((b:number)=>b.toString(16).padStart(2,'0')).join('');random.fill(0);
    const failed=(reason:string):void=>{
      if(serial!==this.listenSerial||token!==this.epoch)return;
      if(waiting){
        this.closeListening();this.followupEligible=false;
        this.write(2,recorder(false),token).catch(()=>{});
        this.state.note='后续收音暂不可用；原回答与自动关闭继续，可再次唤醒';this.changed();
      }else this.endRound(reason,true);
    };
    this.asr.onText=(text:string,final:boolean):void=>{
      if(serial!==this.listenSerial||token!==this.epoch||!text.trim())return;
      if(waiting){
        // Commit the interruption only on speech, not type11/PCM/heartbeat.
        waiting=false;this.epoch++;token=this.epoch;this.model.cancel();
        if(this.timer!==-1)clearTimeout(this.timer);if(this.audioTimer!==-1)clearTimeout(this.audioTimer);
        this.timer=-1;this.audioTimer=-1;this.processing=false;this.followupEligible=false;
        this.sid=task;this.state.phase='recording';this.state.answer='';this.lastPartial=0;
        this.state.note='已识别插话，旧回答已停止，正在收取新问题';
      }
      if(this.processing)return;
      this.state.transcript=text;this.changed();
      if(final){this.processing=true;this.respond(text,token).catch(()=>{if(token===this.epoch)this.endRound('识别或模型请求失败，本轮已停止',true);});}
      else if(Date.now()-this.lastPartial>=450){this.lastPartial=Date.now();this.write(5,transcript(voiceChunks(text,100)[0],false),token).catch(()=>{if(token===this.epoch)this.endRound('识别文字未发送',true);});}
    };
    this.asr.onError=failed;
    try{
      audio.reset();this.asr.start(this.config,task);
      const commandToken=token;
      this.write(2,recorder(true),commandToken).catch(()=>{if(commandToken===this.epoch)failed('收音启动未发送');});
      if(followup)this.listenTimer=setTimeout(()=>failed('35秒收音保护到期'),35000);
    }catch(_){failed('ASR或解码器启动失败');}
  }
  private async respond(text:string,token:number):Promise<void>{
    this.closeListening();this.followupEligible=false;this.state.phase='processing';
    if(this.timer!==-1)clearTimeout(this.timer);if(this.audioTimer!==-1)clearTimeout(this.audioTimer);
    this.timer=-1;this.audioTimer=-1;
    await this.write(5,transcript(voiceChunks(text,100)[0],true),token);
    await this.write(2,recorder(false),token);
    if(/^(退下吧|关闭窗口|关闭|没事了|结束)[。！!\s]*$/.test(text.trim())){this.endRound('语音关闭指令已识别',true);return;}
    if(token!==this.epoch)return;
    this.followupEligible=true;
    this.state.phase='processing';this.state.note='云端已断句，正在请求当前自定义模型';this.changed();
    this.timer=setTimeout(()=>{if(token===this.epoch)this.endRound('模型或显示超时',true);},120000);
    if(!this.testReply){this.state.modelRequests++;this.changed();}
    this.model.onToolStatus=(status:string):void=>{if(token===this.epoch){this.state.note=status;this.changed();}};
    const answer=this.testReply?`ASR识别成功 · 校验 ${this.sid.slice(-4).toUpperCase()}。这是本地测试文字，不是模型回答。`:await this.model.chat(this.config,text);if(token!==this.epoch)return;
    if(!this.testReply)this.state.modelReplies++;
    this.state.answer=answer;this.changed();
    if(!this.testReply)this.completed(this.sid,text,answer,this.config.model);
    const clipped=answer.length>600?answer.slice(0,560)+'（镜片内容已截短，完整回答请看手机）':answer;
    const chunks=voiceChunks(clipped,24);const sid=this.sid;
    for(const chunk of chunks){
      if(token!==this.epoch)return;
      await this.write(32,answerChunk(chunk,sid,voiceChunks(text,16)[0],Date.now()),token);
    }
    if(token!==this.epoch)return;
    await this.write(12,'{}',token); // Not answer.isFinal: reproduce V1 EOF contract.
    if(token!==this.epoch)return;
    this.state.completedRounds++;
    this.state.lastResult=`${new Date().toLocaleTimeString()} · ${this.testReply?'本地校验':this.config.model} · 回答 ${answer.length} 字 · 完成标记已提交`;
    if(this.timer!==-1)clearTimeout(this.timer);
    this.state.phase='displaying';this.state.note='回答与完成标记已提交，10秒后退出；镜片排版待验收';this.changed();
    this.timer=setTimeout(()=>{if(token===this.epoch)this.endRound('本轮结束，等待下次唤醒',true);},10000);
  }
  private endRound(note:string,sendExit:boolean):void{
    this.epoch++;this.cleanup();this.state.phase=this.state.enabled?'idle':'disabled';this.state.note=note;
    if(sendExit&&this.ready)this.exitCommands();this.changed();
  }
}
