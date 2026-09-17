import { notifications } from '../NotificationService';
@Component
export struct NotificationPanel {
  @State notificationEnabled:boolean=false;@State busy:boolean=false;@State note:string='';@State titleText:string='Turbo IO 测试';@State content:string='通知校验 5826';
  private visible:boolean=false;
  aboutToAppear():void{this.visible=true;notifications.changed=():void=>this.refresh();this.refresh();}
  aboutToDisappear():void{this.visible=false;notifications.changed=():void=>{};}
  private refresh():void{if(!this.visible)return;this.notificationEnabled=notifications.enabled;this.busy=notifications.busy||notifications.waiting;this.note=notifications.note;}
  private run(work:()=>Promise<void>):void{work().catch((error:Error)=>{if(this.visible){this.refresh();this.note=error.message;}});}
  build(){
    Column({space:16}){
      Text('消息，抬眼即见').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#F1F8FC').width('100%')
      Text('手机手动发送 → 眼镜通知模板').fontSize(13).fontColor('#93B2C3').width('100%')
      Row(){Column({space:6}){Text('允许眼镜通知').fontSize(18).fontColor('#E6F2F8');Text('仅提交通知总开关').fontSize(12).fontColor('#93B2C3')}.alignItems(HorizontalAlign.Start);Blank();Toggle({type:ToggleType.Switch,isOn:this.notificationEnabled}).selectedColor('#62E9B1').enabled(!this.busy).onChange((v:boolean)=>{if(notifications.busy||notifications.waiting||v===notifications.enabled)return;this.notificationEnabled=v;this.run(()=>notifications.setEnabled(v));})}.width('100%').padding(18).backgroundColor('#1B3040').borderRadius(20)
      Column({space:12}){
        Text('手动测试').fontSize(17).fontColor('#D6E8F1').width('100%')
        TextInput({text:this.titleText,placeholder:'通知标题，最多 16 字'}).maxLength(16).backgroundColor('#102431').fontColor('#EDF6FA').onChange((v:string)=>{this.titleText=v;})
        TextArea({text:this.content,placeholder:'正文，最多 48 字'}).maxLength(48).height(110).backgroundColor('#102431').fontColor('#EDF6FA').onChange((v:string)=>{this.content=v;})
        Button('发送到眼镜').height(48).width('100%').backgroundColor('#62E9B1').fontColor('#0B3125').enabled(this.notificationEnabled&&!this.busy).onClick(()=>this.run(()=>notifications.notify(this.titleText,this.content)))
        Text(this.note).fontSize(13).fontColor('#C4DAE6').width('100%')
      }.width('100%').padding(18).backgroundColor('#1B3040').borderRadius(20)
      Text('这是独立业务通知，不经过手机系统通知中心。保留眼镜原有来源过滤与停留时长，发送成功不等于镜片已显示。').fontSize(12).fontColor('#A6BECC')
      Column({space:8}){Text('其他 App 通知转发').fontSize(17).fontColor('#D6E8F1').width('100%');Text('尚未启用：需要华为通知订阅权限与证书授权。当前版本不会读取微信或其他 App 的通知，也不展示假的应用白名单。').fontSize(13).fontColor('#C9B18C')}.padding(18).backgroundColor('#243038').borderRadius(20).width('100%')
    }.padding(16).width('100%').backgroundColor('#142431').borderRadius(22).alignItems(HorizontalAlign.Start)
  }
}
