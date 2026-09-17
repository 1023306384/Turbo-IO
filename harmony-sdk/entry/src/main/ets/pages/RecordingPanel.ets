import { common } from '@kit.AbilityKit';
import { fileIo as fs,picker } from '@kit.CoreFileKit';
import { RecordingItem } from '../RecordingSession';
import { recordings } from '../RecordingService';
import { probeSession } from '../ProbeSession';
import { RecordingASR } from '../RecordingASR';
import { SecureServiceConfig } from '../RemoteServices';

@Component
export struct RecordingPanel {
  @State note:string='';@State receiverEnabled:boolean=false;@State active:boolean=false;
  @State busy:boolean=false;@State bytes:number=0;@State items:RecordingItem[]=[];
  @State starting:boolean=false;
  @State asrActive:boolean=false;@State asrProgress:number=0;@State transcript:string='';
  private visible:boolean=false;
  private asr:RecordingASR=new RecordingASR();
  aboutToAppear():void{this.visible=true;recordings.changed=():void=>this.refresh();recordings.refresh();this.refresh();
    this.asr.changed=():void=>{if(this.visible){this.asrActive=this.asr.active;this.asrProgress=this.asr.progress;this.transcript=this.asr.text;}};
    probeSession.onFileTranscriptionSuspend=():void=>this.asr.cancel();
  }
  aboutToDisappear():void{this.visible=false;recordings.changed=():void=>{};probeSession.onFileTranscriptionSuspend=():void=>{};this.asr.cancel();}
  private refresh():void{if(!this.visible)return;this.note=recordings.note;this.receiverEnabled=recordings.enabled;this.active=recordings.active;this.starting=recordings.starting;this.bytes=recordings.bytes;this.items=[...recordings.items];}
  private run(action:()=>Promise<void>):void{if(this.busy)return;this.busy=true;this.note='正在处理…';action().then(()=>{if(this.visible){this.note=recordings.note;this.getUIContext().getPromptAction().showToast({message:this.note,duration:3000});}}).catch((error:Error)=>{if(this.visible){this.note=error.message;this.getUIContext().getPromptAction().showToast({message:this.note,duration:3000});}}).finally(()=>{if(this.visible)this.busy=false;});}
  private async exportFile(item:RecordingItem,wav:boolean,text:boolean=false):Promise<void>{
    const source=text?recordings.textPath(item):recordings.file(item,wav),context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uris=await new picker.DocumentViewPicker(context).save({newFileNames:[`TurboIO-recording-${item.created}.${text?'md':wav?'wav':'rawopus'}`]});if(!uris.length)return;
    if(wav&&!text)recordings.file(item,true); // Recheck after time spent in the system picker.
    const input=fs.openSync(source,fs.OpenMode.READ_ONLY);let output:fs.File|undefined=undefined;
    try{output=fs.openSync(uris[0],fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);const length=fs.statSync(input.fd).size;let offset=0;while(offset<length){const part=new ArrayBuffer(Math.min(65536,length-offset));const n=fs.readSync(input.fd,part,{length:part.byteLength});if(n<=0)throw new Error('源录音读取不完整');let written=0;while(written<n){const count=fs.writeSync(output.fd,part.slice(written,n));if(count<=0)throw new Error('导出写入不完整');written+=count;}offset+=n;await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,0);});}fs.fsyncSync(output.fd);}
    finally{fs.closeSync(input);if(output)fs.closeSync(output);}
    if(this.visible)this.note='已保存到选择的位置；App 中原件保留';
  }
  private confirmTranscription(item:RecordingItem):void{
    this.getUIContext().showAlertDialog({title:'上传这条录音进行转写？',message:'只上传你选中的录音到本机配置的阿里 ASR。原始录音保留，双声道会合并为单声道；请保持应用前台，离开本页或退到后台即取消。',
      primaryButton:{value:'取消',action:():void=>{}},secondaryButton:{value:'开始转写',action:():void=>this.run(async()=>{
        const config=await new SecureServiceConfig().load();if(!this.visible)return;
        const text=await this.asr.transcribe(recordings.file(item,true),config);recordings.saveTranscript(item,text);this.note='转写完成，已保存 Markdown；原始录音未改动';
      })}});
  }
  build(){
    Column({space:16}) {
      Text('录下此刻，留在本机').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#EFF8FF')
      Text('眼镜收音 · 原始副本 + 立体声 WAV').fontSize(13).fontColor('#8FAEBD')
      Column({space:12}) {
        Text(this.starting?'◌ 等待眼镜开始确认':this.active?'● 正在接收':'○ 录音待命').fontSize(21).fontColor(this.active?'#62E9B1':'#BED0DB')
        Text(`${Math.round(this.bytes/1024)} KB`).fontSize(36).fontColor('#EFF8FF')
        Text(this.note).fontSize(13).fontColor('#ADC4D2')
        Button(this.receiverEnabled?'关闭眼镜录音接收':'开启眼镜录音接收').width('100%').enabled(!this.busy&&!this.active).onClick(()=>this.run(()=>recordings.enable(!this.receiverEnabled)))
        Button('在眼镜开始录音').width('100%').height(46).backgroundColor('#62E9B1').fontColor('#052C21').enabled(!this.busy&&!this.active&&probeSession.features.state.connected).onClick(()=>this.run(()=>recordings.start()))
        if(this.active){Button(this.starting?'取消开始请求':'停止并保存').width('100%').backgroundColor('#703544').enabled(!this.busy).onClick(()=>this.run(()=>recordings.stop()))}
      }.padding(20).width('100%').backgroundColor('#1B3040').borderRadius(20)
      Text('语音待命不影响录音，无需手动关闭。录音期间暂不接受新语音唤醒；请先结束进行中的对话、导航或提词。10 分钟停止保护；不自动转写或上传。').fontSize(12).fontColor('#C9B38D')
      if(this.asrActive){Text(`转写上传进度 ${this.asrProgress}% · 上传结束后仍需等服务完成`).fontSize(13).fontColor('#62E9B1');Button('取消转写').onClick(()=>this.asr.cancel())}
      if(this.transcript){Text(this.transcript).fontColor('#D2E2EB').fontSize(14).copyOption(CopyOptions.LocalDevice)}
      Row(){Text('本机录音').fontSize(19).fontColor('#EFF8FF');Blank();Button('刷新').fontSize(12).enabled(!this.active&&!this.busy).onClick(()=>{try{recordings.refresh();}catch(_){this.note='录音目录暂不可读取';}})}.width('100%')
      if(!this.items.length){Text('暂无录音。录完后会出现在这里。').fontColor('#8FAEBD').fontSize(14).padding(18)}
      ForEach(this.items,(item:RecordingItem)=>{
        Column({space:10}) {
          Text(new Date(item.created).toLocaleString()).fontSize(17).fontColor('#ECF5FA')
          Text(`${Math.round(item.bytes/1024)} KB · ${item.note}`).fontSize(12).fontColor(item.complete?'#62E9B1':'#D7BA8E')
          Row({space:8}) {
            Button('导出 WAV').fontSize(12).enabled(item.complete&&!this.busy&&!this.active).onClick(()=>this.run(()=>this.exportFile(item,true)))
            Button('导出原始副本').fontSize(12).enabled(!this.busy&&!this.active).onClick(()=>this.run(()=>this.exportFile(item,false)))
          }
          Row({space:8}) {
            Button('云端转写').fontSize(12).enabled(item.complete&&!this.busy&&!this.active).onClick(()=>this.confirmTranscription(item))
            if(item.textFile){Button('导出文字 MD').fontSize(12).enabled(!this.busy&&!this.active).onClick(()=>this.run(()=>this.exportFile(item,false,true)))}
          }
        }.padding(16).backgroundColor('#1B3040').borderRadius(18).width('100%').alignItems(HorizontalAlign.Start)
      },(item:RecordingItem)=>item.name)
    }.padding(16).width('100%').backgroundColor('#142431').borderRadius(22).alignItems(HorizontalAlign.Start)
  }
}
