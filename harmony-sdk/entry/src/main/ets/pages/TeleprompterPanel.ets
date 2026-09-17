import { teleprompter } from '../TeleprompterService';
import { localWorkspace,WorkspaceEntry } from '../LocalWorkspace';

@Component
export struct TeleprompterPanel {
  @State phase:string='idle';@State note:string='';@State progress:number=0;@State readOffset:number=0;
  @State speed:number=120;@State title:string='';@State text:string='';@State busy:boolean=false;
  @State manuscripts:WorkspaceEntry[]=[];
  private visible:boolean=false;
  aboutToAppear():void{this.visible=true;teleprompter.changed=():void=>this.refresh();this.manuscripts=localWorkspace.entries.filter(e=>e.kind==='manuscript');this.refresh();}
  aboutToDisappear():void{this.visible=false;teleprompter.changed=():void=>{};teleprompter.stop().catch(()=>{});}
  private refresh():void{if(!this.visible)return;this.phase=teleprompter.phase;this.note=teleprompter.note;this.progress=teleprompter.progress;this.readOffset=teleprompter.offset;}
  private run(work:()=>Promise<void>):void{if(this.busy)return;this.busy=true;work().catch((error:Error)=>{if(this.visible)this.note=error.message;}).finally(()=>{if(this.visible)this.busy=false;});}
  build(){
    Column({space:16}) {
      Row(){Column({space:6}){Text('把稿件放进视线').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#F0F8FD');Text('纯文字提词 · 不开启麦克风').fontSize(13).fontColor('#92B2C3')}.alignItems(HorizontalAlign.Start);Blank();Text('▤').fontSize(38).fontColor('#62E9B1')}.width('100%')
      Column({space:12}) {
        Text('01  选择或粘贴稿件').fontSize(16).fontColor('#D5E9F2').width('100%')
        if(this.manuscripts.length){Select(this.manuscripts.map((e:WorkspaceEntry):SelectOption=>({value:e.title}))).value('从我的资料选择').enabled(this.phase==='idle').fontColor('#C4E4D8').onSelect((index:number)=>{if(index>=0&&index<this.manuscripts.length){this.title=this.manuscripts[index].title;this.text=this.manuscripts[index].text;}})}
        TextInput({text:this.title,placeholder:'稿件标题（仅本机）'}).maxLength(100).enabled(this.phase==='idle').backgroundColor('#102431').fontColor('#F0F8FD').onChange((v:string)=>{this.title=v;})
        TextArea({text:this.text,placeholder:'粘贴正文；文件请先在「资料」导入 TXT / MD'}).height(200).maxLength(12000).enabled(this.phase==='idle').backgroundColor('#102431').fontColor('#EDF6FA').onChange((v:string)=>{this.text=v;})
        Row(){Text(`${this.text.length} / 12000 字`).fontSize(12).fontColor('#8EAEBE');Blank();Button('保存到资料').fontSize(12).enabled(!this.busy&&this.phase==='idle'&&this.text.trim().length>0).onClick(()=>this.run(()=>localWorkspace.manuscript(this.title,this.text)))}.width('100%')
      }.padding(18).backgroundColor('#1B3040').borderRadius(20).width('100%')
      Column({space:12}) {
        Row(){Text('02  匀速滚动').fontSize(16).fontColor('#D5E9F2');Blank();Text(`${this.speed}`).fontSize(25).fontColor('#62E9B1')}.width('100%')
        Slider({value:this.speed,min:60,max:240,step:10}).selectedColor('#62E9B1').onChange((v:number)=>{this.speed=Math.round(v);})
        Text('60 慢速                                    240 快速').fontSize(12).fontColor('#8EAEBE').width('100%')
        Button('完整传稿 → 等待就绪').width('100%').height(48).backgroundColor('#62E9B1').fontColor('#0C3125').enabled(!this.busy&&this.phase==='idle'&&this.text.trim().length>0).onClick(()=>this.run(()=>teleprompter.prepare(this.text,this.speed)))
        if(this.phase!=='idle'){
          Progress({value:this.progress,total:100,type:ProgressType.Linear}).color('#62E9B1').width('100%')
          Text(`传输 ${this.progress}% · 阅读偏移 ${this.readOffset} B`).fontSize(12).fontColor('#8EAEBE')
        }
        Text(this.note).fontSize(13).fontColor('#C8DFE8').width('100%')
      }.padding(18).backgroundColor('#1B3040').borderRadius(20).width('100%')
      Row({space:8}){
        Button('开始').layoutWeight(1).enabled(!this.busy&&this.phase==='ready').onClick(()=>this.run(()=>teleprompter.control(3)))
        Button(this.phase==='paused'?'继续':'暂停').layoutWeight(1).enabled(!this.busy&&['running','paused'].includes(this.phase)).onClick(()=>this.run(()=>teleprompter.control(this.phase==='paused'?5:4)))
        Button('调速').layoutWeight(1).enabled(!this.busy&&['ready','running','paused'].includes(this.phase)).onClick(()=>this.run(()=>teleprompter.control(7,this.speed)))
      }.width('100%')
      if(this.phase!=='idle'){Button('退出提词器').width('100%').backgroundColor('#573942').enabled(!this.busy).onClick(()=>this.run(()=>teleprompter.stop()))}
      Text('完整收稿需要文件层与提词业务两项确认。离开本页或退到后台会请求退出；如连接中断，请用眼镜实体按钮退出。Harmony 镜片效果待联合验收。').fontSize(12).fontColor('#C7B18C')
    }.padding(16).width('100%').backgroundColor('#142431').borderRadius(22).alignItems(HorizontalAlign.Start)
  }
}
