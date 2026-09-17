import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { localWorkspace, WorkspaceEntry, WorkspaceTodo } from '../LocalWorkspace';
import { probeSession } from '../ProbeSession';

@Component
export struct LibraryPanel {
  @Prop category: string = '待办';
  @State todos: WorkspaceTodo[] = [];
  @State entries: WorkspaceEntry[] = [];
  @State note: string = '';
  @State titleText: string = '';
  @State manuscriptTitle: string = '';
  @State manuscriptText: string = '';
  @State tab: string = 'conversation';
  @State busy: boolean = false;
  @State selected: string = '';
  @State editing: number = 0;
  private visible: boolean = false;
  aboutToAppear():void{this.visible=true;localWorkspace.changed=():void=>this.refresh();this.refresh();}
  aboutToDisappear():void{this.visible=false;localWorkspace.changed=():void=>{};}
  private refresh():void{if(!this.visible)return;this.todos=[...localWorkspace.todos];this.entries=[...localWorkspace.entries];this.note=localWorkspace.note;}
  private run(action:()=>Promise<void>):void {
    if(this.busy)return;this.busy=true;this.note='正在处理…';action().then(()=>{if(this.visible){this.note=localWorkspace.note;this.getUIContext().getPromptAction().showToast({message:this.note,duration:3000});}}).catch((error:Error)=>{if(this.visible){this.note=error.message;this.getUIContext().getPromptAction().showToast({message:this.note,duration:3000});}}).finally(()=>{if(this.visible)this.busy=false;});
  }
  private delivery(row:WorkspaceTodo):string {
    if(row.delivery==='conflict')return '状态冲突';if(row.delivery==='submitted')return '已提交 · 未确认';
    if(row.delivery==='confirmed')return '眼镜已回报';if(row.delivery==='pending')return '待发送';return '仅本机';
  }
  private async saveMarkdown(entry:WorkspaceEntry):Promise<void>{
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uris=await new picker.DocumentViewPicker(context).save({newFileNames:[`TurboIO-${entry.kind}-${entry.created}.md`]});
    if(!uris.length)return;
    const content=new util.TextEncoder().encodeInto(localWorkspace.markdown(entry));
    const file=fs.openSync(uris[0],fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
    try{let offset=0;while(offset<content.length){const written=fs.writeSync(file.fd,content.slice(offset).buffer);if(written<=0)throw new Error('文件未完整写入');offset+=written;}fs.fsyncSync(file.fd);}
    finally{fs.closeSync(file);content.fill(0);}
    if(this.visible)this.note='Markdown 已保存到你选择的文件位置';
  }
  private async importText():Promise<void>{
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uris=await new picker.DocumentViewPicker(context).select({maxSelectNumber:1,fileSuffixFilters:['纯文本|.txt,.md']});if(!uris.length)return;
    const file=fs.openSync(uris[0],fs.OpenMode.READ_ONLY);
    try{
      const size=fs.statSync(file.fd).size;if(size<=0||size>400000)throw new Error('文本文件须小于 400 KB');
      const buffer=new ArrayBuffer(size);let offset=0;
      while(offset<size){const part=new ArrayBuffer(size-offset);const count=fs.readSync(file.fd,part,{length:size-offset});if(count<=0)throw new Error('文本读取不完整');new Uint8Array(buffer).set(new Uint8Array(part,0,count),offset);offset+=count;}
      const text=new util.TextDecoder('utf-8',{fatal:true}).decodeToString(new Uint8Array(buffer));
      if(text.includes('\u0000')||text.length>100000)throw new Error('需要 UTF-8 文本，正文不超过 10 万字');
      if(this.visible){this.manuscriptText=text;this.note='已读取文本，请确认标题并保存；未发送到眼镜';}
    }finally{fs.closeSync(file);}
  }
  @Builder
  private todoCard(row:WorkspaceTodo) {
    Column({space:12}) {
      Row({space:10}) {
        Button(row.completed?'✓':'○').width(38).height(38).fontColor(row.completed?'#05291F':'#B6D0DE').backgroundColor(row.completed?'#62E9B1':'#294454').enabled(!this.busy)
          .onClick(()=>this.run(()=>localWorkspace.editTodo(row.id,row.title,!row.completed)))
        Text(row.title).fontColor('#F0F7FA').fontSize(17).layoutWeight(1)
      }.width('100%')
      Row({space:8}) {
        Text(this.delivery(row)).fontColor(row.delivery==='conflict'?'#F0C891':'#8FAEBC').fontSize(11).layoutWeight(1)
        Button('修改').fontSize(11).height(30).backgroundColor('#294454').enabled(!this.busy).onClick(()=>{this.editing=row.id;this.titleText=row.title;})
        Button(this.busy?'处理中…':'发送眼镜').fontSize(11).height(30).backgroundColor('#24634E').enabled(!this.busy&&row.delivery!=='conflict')
          .onClick(()=>this.run(()=>localWorkspace.sendTodo(row.id,probeSession.peerDeviceId,(business:number,payload:Uint8Array)=>probeSession.auth.sendBusiness(business,payload))))
      }.width('100%')
      if(row.delivery==='conflict') {
        Text(`眼镜回报：${row.observed===1?'完成':'未完成'}；手机修改未被覆盖`).fontSize(12).fontColor('#EBC78E')
        Row({space:8}) {
          Button('采用眼镜').fontSize(12).enabled(!this.busy).onClick(()=>this.run(()=>localWorkspace.resolveTodo(row.id,true)))
          Button('保留本机待发送').fontSize(12).enabled(!this.busy).onClick(()=>this.run(()=>localWorkspace.resolveTodo(row.id,false)))
        }
      }
    }.padding(16).borderRadius(18).backgroundColor('#1A303F').width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({space:16}) {
      Text(this.category==='待办'?'今天，从一件事开始':'我的资料').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#F0F7FA')
      Text(this.note).fontColor('#9DB6C5').fontSize(12).width('100%')
      if(this.category==='待办') {
        Row({space:8}) {
          TextInput({text:this.titleText,placeholder:this.editing?'修改待办标题':'添加新的待办事项…'}).maxLength(60).height(48).layoutWeight(1).backgroundColor('#1B3040').fontColor('#E9F4FB').onChange((v:string)=>{this.titleText=v;})
          Button(this.editing?'保存':'添加').height(48).backgroundColor('#62E9B1').fontColor('#062C21').enabled(!this.busy&&localWorkspace.ready&&this.titleText.trim().length>0).onClick(()=>this.run(async()=>{
            const row=this.todos.find(t=>t.id===this.editing);
            if(this.editing&&row)await localWorkspace.editTodo(row.id,this.titleText,row.completed);else await localWorkspace.addTodo(this.titleText);
            this.titleText='';this.editing=0;
          }))
        }.width('100%')
        if(this.todos.length===0){Text('暂无待办\n新增后可逐条发送到眼镜，不改动眼镜上其他内容。').fontSize(15).fontColor('#91ACBE').padding(20)}
        ForEach(this.todos,(row:WorkspaceTodo)=>{this.todoCard(row)},(row:WorkspaceTodo)=>String(row.id))
      }else {
        Row({space:8}) {
          Button('对话时间轴').layoutWeight(1).backgroundColor(this.tab==='conversation'?'#24634E':'#223848').onClick(()=>{this.tab='conversation';})
          Button('稿件').layoutWeight(1).backgroundColor(this.tab==='manuscript'?'#24634E':'#223848').onClick(()=>{this.tab='manuscript';})
        }.width('100%')
        if(this.tab==='manuscript') {
          TextInput({text:this.manuscriptTitle,placeholder:'稿件标题'}).height(46).maxLength(100).backgroundColor('#1B3040').fontColor('#EDF6FF').onChange((v:string)=>{this.manuscriptTitle=v;})
          TextArea({text:this.manuscriptText,placeholder:'粘贴稿件正文，或从文件导入 UTF-8 TXT / MD'}).height(170).maxLength(100000).backgroundColor('#1B3040').fontColor('#EDF6FF').onChange((v:string)=>{this.manuscriptText=v;})
          Row({space:8}) {
            Button('导入 TXT / MD').layoutWeight(1).enabled(!this.busy).onClick(()=>this.run(()=>this.importText()))
            Button('保存稿件').layoutWeight(1).enabled(!this.busy&&this.manuscriptText.trim().length>0).onClick(()=>this.run(async()=>{await localWorkspace.manuscript(this.manuscriptTitle,this.manuscriptText);this.manuscriptTitle='';this.manuscriptText='';}))
          }
          Text('保存后可在「提词器」选择并完整传稿。首次支持 UTF-8 TXT / MD；EPUB 尚未迁移。').fontColor('#CAA97C').fontSize(12)
        }
        if(!this.entries.some(e=>e.kind===this.tab)){Text(this.tab==='conversation'?'真实语音回答会自动保存在这里。旧版未保存的会话无法追溯恢复。':'暂无稿件').fontColor('#9DB6C5').fontSize(14).padding(16)}
        ForEach(this.entries.filter(e=>e.kind===this.tab),(entry:WorkspaceEntry)=>{
          Column({space:12}) {
            Text(new Date(entry.created).toLocaleString()).fontSize(11).fontColor('#8DADBE')
            Text(entry.title).fontSize(17).fontColor('#EDF5FA').fontWeight(FontWeight.Medium)
            Text(this.selected===entry.id?localWorkspace.markdown(entry):(entry.answer||entry.text).slice(0,120)).fontSize(14).fontColor('#B1C7D6').copyOption(CopyOptions.LocalDevice)
            Row({space:8}) {
              Button(this.selected===entry.id?'收起':'展开').fontSize(12).height(34).onClick(()=>{this.selected=this.selected===entry.id?'':entry.id;})
              Button('导出 Markdown').fontSize(12).height(34).enabled(!this.busy).onClick(()=>this.run(()=>this.saveMarkdown(entry)))
            }
          }.padding(18).width('100%').backgroundColor('#1A303F').borderRadius(18).alignItems(HorizontalAlign.Start)
        },(entry:WorkspaceEntry)=>entry.id)
      }
    }.padding(16).width('100%').backgroundColor('#142431').borderRadius(22).alignItems(HorizontalAlign.Start)
  }
}
