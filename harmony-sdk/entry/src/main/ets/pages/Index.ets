import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { Candidate, DiscoveryReport } from 'turbo_core';
import { probeSession } from '../ProbeSession';
import { FeaturePanel } from './FeaturePanel';
import { localWorkspace } from '../LocalWorkspace';
import { recordings } from '../RecordingService';
import { teleprompter } from '../TeleprompterService';
import { notifications } from '../NotificationService';
import { connectedServices } from '../ConnectedServices';

@Entry
@Component
struct Index {
  @StorageLink('turboTopInset') topInset:number=0;
  @StorageLink('turboBottomInset') bottomInset:number=0;
  @State page: string = '眼镜';
  @State feature: string = '设备';
  @State pairing: boolean = false;
  @State phase: string = 'idle';
  @State note: string = '';
  @State battery: number = -1;
  @State seconds: number = 0;
  @State saved: boolean = false;
  @State autoConnect: boolean = true;
  @State backgroundOn: boolean = false;
  @State backgroundBusy: boolean = false;
  @State backgroundNote: string = '';
  @State backgroundReport: string = '';
  @State name: string = 'RayNeo iO';
  @State scanning: boolean = false;
  @State requesting: boolean = false;
  @State scanNote: string = '先允许蓝牙权限，再发现附近的眼镜';
  @State candidates: Candidate[] = [];
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    probeSession.onNotification=(peer:string,payload:Uint8Array):void=>notifications.receive(peer,payload);
    probeSession.onNotificationDisconnected=():void=>notifications.disconnected();
    probeSession.onPrompter=(peer:string,business:number,payload:Uint8Array):void=>teleprompter.receive(peer,business,payload);
    probeSession.onPrompterDisconnected=():void=>teleprompter.disconnected();
    probeSession.onPrompterSuspend=():void=>{teleprompter.stop().catch(()=>{});};
    probeSession.prompterOccupied=():boolean=>teleprompter.active;
    try{recordings.initialize(this.getUIContext().getHostContext() as common.UIAbilityContext);}catch(_){recordings.note='录音目录读取失败，原件保留';}
    probeSession.onRecording=(peer:string,payload:Uint8Array):void=>recordings.receive(peer,payload);
    probeSession.onRecordingDisconnected=():void=>recordings.disconnected();
    probeSession.recordingOccupied=():boolean=>recordings.active||recordings.busy;
    localWorkspace.load(this.getUIContext().getHostContext() as common.UIAbilityContext).catch(()=>{});
    probeSession.onTodo=(peer:string,payload:Uint8Array):void=>localWorkspace.receiveTodo(peer,payload);
    probeSession.voice.completed=(id:string,text:string,answer:string,model:string):void=>{
      localWorkspace.conversation(id,text,answer,model).catch(()=>{localWorkspace.note='回答已收到，但本机存档失败';localWorkspace.changed();});
    };
    probeSession.onConnection = (): void => this.refresh();
    probeSession.onDiscovery = (r: DiscoveryReport): void => {
      this.scanning = r.scanning; this.scanNote = r.status;
      this.candidates = r.candidates.filter((c: Candidate): boolean => !c.classic);
    };
    this.refresh();
    connectedServices.start();
    probeSession.resume(this.getUIContext().getHostContext() as common.UIAbilityContext);
  }
  aboutToDisappear(): void {
    probeSession.onConnection = (): void => {};
    probeSession.onDiscovery = (_: DiscoveryReport): void => {};
  }
  private refresh(): void {
    connectedServices.connectionChanged();
    const c = probeSession.connection;
    this.phase = c.phase; this.note = c.note; this.battery = c.battery; this.seconds = c.seconds;
    this.saved = c.saved; this.autoConnect = c.autoConnect; this.name = c.name;
    this.backgroundOn = probeSession.background.active; this.backgroundBusy = probeSession.background.pending;
    this.backgroundNote = probeSession.background.note; this.backgroundReport = c.backgroundReport;
  }
  private connecting(): boolean { return ['connecting', 'authenticating', 'initializing', 'retrying'].includes(this.phase); }
  private openFeature(tab: string): void {
    this.feature = tab; this.page = '功能'; this.pairing = false; this.scroller.scrollEdge(Edge.Top);
  }
  private async permissionAndScan(): Promise<void> {
    if (this.requesting || this.connecting() || this.phase === 'ready') return;
    this.requesting = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
      if (result.authResults.length !== 1 || result.authResults[0] !== 0) { this.scanNote = '蓝牙权限未允许，请在系统权限设置中开启'; return; }
      if (probeSession.foreground) probeSession.discovery.start();
    } catch (_) { this.scanNote = '无法开始扫描，请确认系统蓝牙已打开'; }
    finally { this.requesting = false; }
  }
  private choose(candidate: Candidate): void {
    if (this.connecting()) return;
    this.getUIContext().showAlertDialog({
      title: '连接这副眼镜',
      message: '首次换用 Turbo IO，请先在原 App 解绑、在原手机蓝牙中忽略，再长按眼镜按钮约 5 秒直到蓝灯闪烁。已绑定本 App 的眼镜无需重复解绑。请确认是你的空闲眼镜；系统配对弹窗请允许。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '确认并连接', action: (): void => {
        probeSession.connect(candidate, this.getUIContext().getHostContext() as common.UIAbilityContext);
      } }
    });
  }
  @Builder
  tile(icon: string, title: string, subtitle: string, target: string) {
    Column({ space: 8 }) {
      Text(icon).fontSize(25).fontColor('#64EAB9')
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#EDF5FA')
      Text(subtitle).fontSize(11).fontColor('#91A9B9').maxLines(2)
    }.alignItems(HorizontalAlign.Start).padding(16).layoutWeight(1).height(120)
      .backgroundColor('#192936').border({ width: 1, color: '#2C4353' }).borderRadius(18)
      .onClick((): void => this.openFeature(target)).accessibilityText(title)
  }
  @Builder
  home() {
    Column({ space: 14 }) {
      Column({ space: 0 }) {
        Image($r('app.media.rayneo_home_hero')).width('100%').height(154).objectFit(ImageFit.Contain)
        Row() {
          Column({ space: 6 }) {
            Text(this.name).fontSize(20).fontWeight(FontWeight.Medium).fontColor('#F0F7FD')
            Text(this.phase === 'ready' ? '● 已连接' : this.connecting() ? '◌ 正在连接' : '○ 未连接')
              .fontSize(13).fontColor(this.phase === 'ready' ? '#62E9B1' : '#A8BDCB')
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Text(this.battery >= 0 && this.phase === 'ready' ? this.battery + '%' : '—')
            .fontSize(24).fontWeight(FontWeight.Medium).fontColor('#BCD5E4')
        }.width('100%').padding({ left: 20, right: 20, bottom: 18 })
      }.width('100%').backgroundColor('#192936').border({ width: 1, color: '#355364' }).borderRadius(22).clip(true)
      Button(this.phase === 'ready' ? '开始语音  →' : this.connecting() ? '正在连接…' : this.saved ? '重新连接眼镜  →' : '连接我的眼镜  →')
        .width('100%').height(54).fontSize(19).fontWeight(FontWeight.Medium).backgroundColor('#62E9B1').fontColor('#08241F')
        .enabled(!this.connecting()).onClick((): void => {
          if (this.phase === 'ready') this.openFeature('模型');
          else if (this.saved) probeSession.reconnect(this.getUIContext().getHostContext() as common.UIAbilityContext);
          else { this.pairing = true; this.scroller.scrollEdge(Edge.Top); }
        })
      if (this.note) { Text(this.note).fontSize(12).fontColor('#9CB6C6').width('100%') }
      Row({ space: 12 }) {
        Text('↗').fontSize(25).fontColor('#62E9B1')
        Column({ space: 5 }) {
          Text('启动自动连接').fontSize(16).fontColor('#EDF5FA')
          Text('打开应用时连接已认证的眼镜').fontSize(11).fontColor('#91A9B9')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoConnect }).selectedColor('#62E9B1')
          .onChange((v: boolean): void => { probeSession.setAutoConnect(v); })
      }.width('100%').padding(17).backgroundColor('#192936').borderRadius(18)
      Row({ space: 12 }) {
        Text('◷').fontSize(25).fontColor('#A7C0CF')
        Column({ space: 5 }) {
          Text('后台蓝牙保持').fontSize(16).fontColor('#EDF5FA')
          Text(this.backgroundNote).fontSize(11).fontColor('#91A9B9')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({type:ToggleType.Switch,isOn:this.backgroundOn}).selectedColor('#62E9B1')
          .enabled(!this.backgroundBusy && this.phase === 'ready').accessibilityText('后台蓝牙保持开关')
          .onChange((v:boolean):void=>{
            if(probeSession.background.pending||v===probeSession.background.active)return;
            this.backgroundOn=v;probeSession.setBackground(v);
          })
      }.width('100%').padding(17).backgroundColor('#152530').borderRadius(18)
      Text('常用功能').fontSize(17).fontWeight(FontWeight.Medium).fontColor('#EFF8FF').width('100%')
      Row({ space: 12 }) { this.tile('☁', '天气', '实时天气与首页显示', '天气'); this.tile('▣', '自定义卡片', '管理眼镜仪表盘', '卡片'); }.width('100%')
      Row({ space: 12 }) { this.tile('➤', '导航', '步行 / 骑行 / 驾车', '导航'); this.tile('☑', '待办清单', '选择下发与双向同步', '待办'); }.width('100%')
      Row({ space: 12 }) { this.tile('◉', '录音', '本机保存 · 手动转写', '录音'); this.tile('≡', '我的资料', '对话时间轴与稿件', '资料'); }.width('100%')
      Row({ space: 12 }) { this.tile('▤', '提词器', '完整传稿与匀速滚动', '提词器'); this.tile('◇', '通知测试', '手动文字直达眼镜', '通知'); }.width('100%')
      Row({ space: 12 }) { this.tile('⚙', '设备设置', '电量、亮度与休眠', '设备'); this.tile('✦', '模型与语音', '自有模型与识别配置', '模型'); }.width('100%')
    }.width('100%')
  }
  @Builder
  wizard() {
    Column({ space: 20 }) {
      Text('权限  →  发现  →  连接  →  完成').fontSize(15).fontColor('#62E9B1')
      Text(this.phase === 'ready' ? '眼镜已准备好' : '找到你的眼镜').fontSize(27).fontWeight(FontWeight.Bold).fontColor('#F0F7FD')
      Text('无需登录。首次连接请先在官方 App 解绑，并忽略原手机蓝牙记录；长按眼镜按钮约 5 秒至蓝灯闪烁。')
        .fontSize(14).fontColor('#A6BDCC').lineHeight(24)
      Text(this.scanNote).fontSize(13).fontColor('#96AEBE')
      if (this.phase !== 'ready') {
        Button(this.scanning ? '停止扫描' : '允许蓝牙并发现眼镜').width('100%').height(50)
          .backgroundColor('#62E9B1').fontColor('#08241F').enabled(!this.requesting && !this.connecting())
          .onClick((): void => { if (this.scanning) probeSession.discovery.stop(); else this.permissionAndScan(); })
        ForEach(this.candidates, (c: Candidate) => {
          Column({ space: 10 }) {
            Text(c.deviceName || c.label).fontSize(20).fontColor('#F0F7FD')
            Text((c.serviceMatched ? '眼镜服务匹配' : '名称匹配') + ' · 信号 ' + c.rssi + ' dBm').fontSize(12).fontColor('#96AEBE')
            Button('连接这副眼镜').enabled(!this.connecting()).onClick((): void => this.choose(c))
          }.width('100%').padding(20).backgroundColor('#192936').borderRadius(20)
        })
      }
      Text(this.note).fontSize(14).fontColor('#62E9B1')
      if (this.connecting()) { Button('取消连接').onClick((): void => probeSession.stop()) }
      Button(this.phase === 'ready' ? '完成，返回首页' : '返回首页').onClick((): void => { this.pairing = false; })
      Text('没有发现？确认蓝灯持续闪烁、手机蓝牙已打开，且其他客户端没有连接。不会自动重置或解绑眼镜。')
        .fontSize(12).fontColor('#91A9B9').lineHeight(22)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  settings() {
    Column({ space: 16 }) {
      Text('连接与服务').fontSize(23).fontWeight(FontWeight.Bold).fontColor('#EFF8FF')
      Text(this.note + ' · 本次连接 ' + this.seconds + ' 秒').fontSize(14).fontColor('#ADC3D2').lineHeight(24)
      Text(this.backgroundNote).fontSize(13).fontColor('#62E9B1')
      Text(this.backgroundReport).fontSize(13).fontColor('#ADC3D2')
      Button(this.backgroundOn ? '关闭后台保持' : '开启蓝牙后台保持').width('100%')
        .enabled(!this.backgroundBusy && this.phase === 'ready')
        .onClick(():void=>{probeSession.setBackground(!this.backgroundOn);})
      Button('语音与模型配置').width('100%').onClick((): void => this.openFeature('模型'))
      Button('连接向导').width('100%').onClick((): void => { this.pairing = true; this.page = '眼镜'; })
      Button('断开本次连接').width('100%').onClick((): void => probeSession.stop())
      Text('主动断开后，本次 App 会话不自动重连；可在首页手动重新连接。').fontSize(12).fontColor('#91A9B9')
      Button('协议诊断').width('100%').onClick((): void => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/Diagnostics' });
      })
      Text('Turbo IO · WORKBENCH 14 · 原生鸿蒙研究版').fontSize(12).fontColor('#91A9B9')
      Text('后台保持需显式开启，系统可能显示持续任务提示。不会自动收音；语音开启并在眼镜唤醒后才上传当轮音频。长时间锁屏、通知转发、实时定位导航仍待验收。').fontSize(12).fontColor('#91A9B9').lineHeight(23)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text(this.pairing ? '连接眼镜' : this.page === '眼镜' ? 'Turbo IO' : this.page === '功能' ? '功能工作台' : '设置')
            .fontSize(29).fontWeight(FontWeight.Bold).fontColor('#EFF8FF')
          Text(this.page === '眼镜' && !this.pairing ? '让眼镜，自然连接。' : 'Turbo IO · 原生鸿蒙').fontSize(13).fontColor('#96AEBD')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text('WORKBENCH 14').fontSize(10).fontColor('#62E9B1')
      }.padding({ left: 22, right: 22, top: 16, bottom: 16 }).width('100%')
      Scroll(this.scroller) {
        Column() {
          if (this.pairing) { this.wizard() }
          else if (this.page === '眼镜') { this.home() }
          else if (this.page === '功能') { FeaturePanel({ initialTab: this.feature, onTabChanged:():void=>{this.scroller.scrollEdge(Edge.Top);} }) }
          else { this.settings() }
        }.padding({ left: 20, right: 20, bottom: 24 }).width('100%').constraintSize({ maxWidth: 720 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      Row() {
        ForEach(['眼镜', '功能', '设置'], (tab: string) => {
          Column({ space: 4 }) {
            Text(tab === '眼镜' ? '▱' : tab === '功能' ? '▦' : '⚙').fontSize(25).fontColor(this.page === tab ? '#62E9B1' : '#8DA6B8')
            Text(tab).fontSize(12).fontColor(this.page === tab ? '#62E9B1' : '#8DA6B8')
          }.layoutWeight(1).height(58).justifyContent(FlexAlign.Center)
            .onClick((): void => { this.page = tab; this.pairing = false; this.scroller.scrollEdge(Edge.Top); }).accessibilityText(tab)
        })
      }.width('100%').padding({ top: 8, bottom: 8+this.bottomInset }).backgroundColor('#12212C').border({ width: { top: 1 }, color: '#243D4D' })
    }.width('100%').height('100%').padding({top:this.topInset}).backgroundColor('#0D1720')
  }
}
