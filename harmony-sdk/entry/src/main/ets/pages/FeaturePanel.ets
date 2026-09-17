import { probeSession } from '../ProbeSession';
import { ServiceConfig, SecureServiceConfig, RemoteServices } from '../RemoteServices';
import { CloudASR } from '../CloudASR';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { NavigationPanel } from './NavigationPanel';
import { LibraryPanel } from './LibraryPanel';
import { RecordingPanel } from './RecordingPanel';
import { TeleprompterPanel } from './TeleprompterPanel';
import { NotificationPanel } from './NotificationPanel';
import { connectedServices } from '../ConnectedServices';

@Component
export struct FeaturePanel {
  @Prop initialTab: string = '设备';
  onTabChanged:()=>void=():void=>{};
  @State tab: string = '设备';
  @State status: string = '';
  @State link: string = '未连接';
  @State connected: boolean = false;
  @State busy: boolean = false;
  @State note: string = '';
  @State weatherNote: string = '';
  @State dashboardNote: string = '';
  @State displayNote: string = '';
  @State city: string = '北京';
  @State temp: string = '27';
  @State icon: string = '101';
  @State widgetText: string = 'Turbo IO 7392';
  @State question: string = '用一句话介绍你自己';
  @State answer: string = '';
  @State modelURL: string = 'https://api.deepseek.com';
  @State modelName: string = 'deepseek-flash';
  @State modelKey: string = '';
  @State tinyfishKey: string = '';
  @State tinyfishEnabled: boolean = false;
  @State tinyfishConfigured: boolean = false;
  @State asrHost: string = 'dashscope.aliyuncs.com';
  @State asrModel: string = 'qwen-audio-3.0-asr-flash-streaming';
  @State asrKey: string = '';
  @State voiceEnabled: boolean = false;
  @State voiceNote: string = '未开启';
  @State voiceTranscript: string = '';
  @State voiceAnswer: string = '';
  @State voiceAudit: string = '';
  @State showServiceConfig: boolean = false;
  @State showVoiceDiagnostics: boolean = false;
  @State prompt: string = '';
  @State weatherHost: string = '';
  @State weatherKey: string = '';
  @State latitude: string = '39.92';
  @State longitude: string = '116.41';
  @State amapKey: string = '';
  @State configStatus: string = '尚未读取配置';
  @State autoWeather: boolean = true;
  private config: ServiceConfig = new ServiceConfig();
  private vault: SecureServiceConfig = new SecureServiceConfig();
  private services: RemoteServices = new RemoteServices();
  private asrCheck: CloudASR = new CloudASR();
  private weatherAt: number = 0;
  private epoch: number = 0;
  private active: boolean = false;
  private pageTimer: number = -1;

  aboutToAppear(): void {
    this.tab = this.initialTab;
    this.active = true;
    probeSession.features.changed = ():void => this.refresh(); this.refresh();
    probeSession.voice.changed = ():void => this.refreshVoice(); this.refreshVoice();
    this.vault.load().then((config:ServiceConfig)=>{
      if (!this.active) return; this.config = config; this.modelURL = config.modelURL; this.modelName = config.model;
      this.prompt = config.systemPrompt; this.weatherHost = config.weatherHost; this.city = config.weatherCity;
      this.latitude = config.weatherLatitude; this.longitude = config.weatherLongitude;
      this.asrHost=config.asrHost||this.asrHost;this.asrModel=config.asrModel||this.asrModel;
      this.autoWeather=config.automaticWeather!==false;
      this.tinyfishEnabled=config.tinyfishEnabled===true;this.tinyfishConfigured=!!config.tinyfishKey;
      this.configStatus = `ASR ${config.asrKey ? '已配置':'未配置'} · 模型 ${config.modelKey ? '已配置':'未配置'} · 和风 ${config.weatherKey ? '已配置':'未配置'} · 高德 ${config.amapKey ? '已配置':'未配置'}`;
    }).catch(()=>{if(this.active)this.configStatus='暂无可读安全配置，请填写并保存';});
  }
  aboutToDisappear(): void {
    this.active = false; this.epoch++; this.services.cancel();
    this.asrCheck.close();
    if (this.pageTimer !== -1) clearTimeout(this.pageTimer); this.pageTimer = -1;
    probeSession.features.changed = ():void=>{};
    probeSession.voice.changed = ():void=>{};
  }
  private refreshVoice():void {
    const v=probeSession.voice.state;this.voiceEnabled=v.enabled;
    this.voiceNote=`${v.phase} · ${v.note} · 音频 ${v.packets} 包 / PCM ${v.pcmBytes} B`;
    this.voiceTranscript=v.transcript;this.voiceAnswer=v.answer;
    this.voiceAudit=`模型请求 ${v.modelRequests} / 返回 ${v.modelReplies} / 完成 ${v.completedRounds}\n${v.lastResult}`;
  }
  private async enableVoice(test:boolean):Promise<void> {
    if(probeSession.recordingOccupied())throw new Error('请先结束录音并等待归档');
    if(probeSession.prompterOccupied())throw new Error('请先退出提词器');
    await this.saveConfig();
    this.config.automaticVoice=true;await this.vault.save(this.config);connectedServices.invalidate();
    if(probeSession.features.displayActive)await probeSession.features.stopDisplay();
    probeSession.voice.enable(this.config,test);
    try{await probeSession.features.voiceWakeup();}
    catch(_){probeSession.voice.disable('唤醒初始化未提交');throw new Error('唤醒初始化未提交');}
    this.refreshVoice();
  }
  private async checkASR():Promise<void> {
    await this.saveConfig();const epoch=this.epoch;
    const random=cryptoFramework.createRandom().generateRandomSync(16).data;
    const task=Array.from(random).map((b:number)=>b.toString(16).padStart(2,'0')).join('');random.fill(0);
    await new Promise<void>((resolve:()=>void,reject:(error:Error)=>void)=>{
      this.asrCheck.onStatus=(status:string):void=>{if(this.active&&epoch===this.epoch)this.configStatus=status;};
      this.asrCheck.onReady=():void=>{this.asrCheck.close();if(this.active&&epoch===this.epoch)this.configStatus='ASR 创建任务成功 · 没有收音 / 上传音频';resolve();};
      this.asrCheck.onError=(reason:string):void=>{reject(new Error(reason));};
      this.asrCheck.start(this.config,task);
    });
  }
  private refresh(): void {
    const state = probeSession.features.state;
    this.connected = state.connected; this.link = `${state.connected ? '眼镜已连接':'眼镜未连接'} · 电量 ${state.battery < 0 ? '待回报':`${state.battery}%`}`;
    this.note = state.note; this.weatherNote = state.weather; this.dashboardNote = state.dashboard; this.displayNote = state.display;
  }
  private run(action:()=>Promise<void>): void {
    if(this.busy)return; this.busy=true;this.status='处理中…'; const epoch=this.epoch;
    action().then(()=>{if(this.active&&epoch===this.epoch)this.status='操作已完成；蓝牙提交请看下方回执状态';})
      .catch((error:Error)=>{if(this.active&&epoch===this.epoch){this.status=error.message?.slice(0,150)||'操作未完成';this.getUIContext().getPromptAction().showToast({message:this.status,duration:3000});}})
      .finally(()=>{if(this.active&&epoch===this.epoch){this.busy=false;this.refresh();}});
  }
  private async saveConfig(): Promise<void> {
    const c = new ServiceConfig();
    if(probeSession.voice.active)throw new Error('请先结束当前对话再保存配置；待命状态可以直接保存');
    const latest=await this.vault.load();
    c.automaticVoice=latest.automaticVoice!==false;c.automaticWeather=latest.automaticWeather!==false;
    c.modelURL=this.modelURL.trim();c.model=this.modelName.trim();c.systemPrompt=this.prompt || c.systemPrompt;
    c.modelKey=this.modelKey.trim()||latest.modelKey;c.weatherHost=this.weatherHost.trim();c.weatherKey=this.weatherKey.trim()||latest.weatherKey;
    c.weatherCity=this.city;c.weatherLatitude=this.latitude;c.weatherLongitude=this.longitude;c.amapKey=this.amapKey.trim()||latest.amapKey;
    c.amapHarmonyKey=latest.amapHarmonyKey||'';c.amapConsent=latest.amapConsent===true;
    c.asrHost=this.asrHost.trim();c.asrModel=this.asrModel.trim();c.asrKey=this.asrKey.trim()||latest.asrKey;
    c.tinyfishEnabled=this.tinyfishEnabled;c.tinyfishKey=this.tinyfishKey.trim()||latest.tinyfishKey||'';
    if(c.tinyfishEnabled&&!c.tinyfishKey)throw new Error('请先填写 TinyFish Key');
    await this.vault.save(c);this.config=c;this.modelKey='';this.weatherKey='';this.amapKey='';this.asrKey='';this.services.clearHistory();
    this.tinyfishKey='';this.tinyfishConfigured=!!c.tinyfishKey;
    if(probeSession.voice.state.enabled)probeSession.voice.disable('配置已保存，正在恢复自动待命');
    connectedServices.invalidate();
    this.configStatus='已保存在本机安全存储；密钥不会显示在日志或源码';
  }
  private async fetchWeather(): Promise<void> {
    this.config=await this.vault.load();
    const weather=await this.services.weather(this.config);
    this.temp=String(weather.temp);this.icon=String(weather.icon);this.weatherNote=`和风天气：${weather.description}`;
    await probeSession.features.weather(this.config.weatherCity,weather.temp,weather.icon);
  }
  private async chat(): Promise<void> {
    const epoch=this.epoch;
    const result=await this.services.chat(this.config,this.question);
    if(!this.active||epoch!==this.epoch)return;
    this.answer=result;
  }
  @Builder
  private title(text:string) { Text(text).fontSize(20).fontWeight(FontWeight.Bold).fontColor('#F0F8FF').width('100%') }
  @Builder
  private input(label:string,value:string,change:(value:string)=>void,secret:boolean=false) {
    Text(label).fontSize(12).fontColor('#9EB5C5').width('100%')
    TextInput({text:value,placeholder:secret?'留空保留已保存 Key':label}).type(secret?InputType.Password:InputType.Normal)
      .maxLength(secret?512:500).onChange(change).fontColor('#E7F4FF').backgroundColor('#142330').height(46).borderRadius(12)
  }
  build() {
    Column({space:16}) {
      Text(this.link).fontSize(16).fontColor(this.connected?'#62E9B1':'#D9B886').width('100%')
      Scroll() { Row({space:6}) {
        ForEach(['模型','导航','待办','录音','提词器','资料','通知','天气','卡片','设备'],(tab:string)=>{
          Button(tab).fontSize(13).padding({left:10,right:10}).height(36).backgroundColor(this.tab===tab?'#467D66':'#233443')
            .onClick(()=>{this.tab=tab;this.status='';this.onTabChanged();})
        })
      } }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      Text(this.status).fontSize(12).fontColor('#D7B891').width('100%')
      if(this.tab==='设备') {
        this.title('电量与设备设置')
        Button('刷新真实状态').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.refreshStatus()))
        Button('读取通用设置').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.refreshSettings()))
        Row({space:12}) {
          Button('亮度 7').onClick(()=>this.run(()=>probeSession.features.brightness(7))).enabled(this.connected&&!this.busy)
          Button('亮度 8').onClick(()=>this.run(()=>probeSession.features.brightness(8))).enabled(this.connected&&!this.busy)
        }
        Row({space:12}) {
          Button('休眠 15 秒').onClick(()=>this.run(()=>probeSession.features.sleepTime(15))).enabled(this.connected&&!this.busy)
          Button('休眠 25 秒').onClick(()=>this.run(()=>probeSession.features.sleepTime(25))).enabled(this.connected&&!this.busy)
        }
        Text(this.note).fontSize(13).fontColor('#BDD0DD')
        Text('配置完整后连接自动语音待命，唤醒才收音；录音和导航无需手动关闭待命。后台蓝牙保持在设置页开启。').fontSize(12).fontColor('#9EB5C5')
      } else if(this.tab==='天气') {
        this.title('首页天气 · 和风实时数据')
        this.input('地点名称',this.city,(v:string)=>{this.city=v;})
        this.input('和风 API Host',this.weatherHost,(v:string)=>{this.weatherHost=v;})
        this.input('和风 API Key',this.weatherKey,(v:string)=>{this.weatherKey=v;},true)
        this.input('纬度，两位小数',this.latitude,(v:string)=>{this.latitude=v;})
        this.input('经度，两位小数',this.longitude,(v:string)=>{this.longitude=v;})
        Button('保存天气配置').enabled(!this.busy).onClick(()=>this.run(()=>this.saveConfig()))
        Button('拉取实时天气 → 眼镜首页').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>this.fetchWeather()))
        Toggle({type:ToggleType.Switch,isOn:this.autoWeather}).onChange((v:boolean)=>{
          this.autoWeather=v;this.run(async()=>{const c=await this.vault.load();c.automaticWeather=v;await this.vault.save(c);this.config=c;connectedServices.invalidate();});
        })
        Text('默认连接后自动同步：首页天气每 15 分钟更新，不依赖停留在此页；当前自动拉取在手机前台执行。').fontSize(12).fontColor('#9EB5C5')
        this.input('测试温度（非实时天气）',this.temp,(v:string)=>{this.temp=v;})
        this.input('天气图标编号（候选，镜片需确认）',this.icon,(v:string)=>{this.icon=v;})
        Button('发送测试温度').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.weather(this.city,Number(this.temp),Number(this.icon))))
        Text(this.weatherNote).fontSize(13).fontColor('#BDD0DD')
      } else if(this.tab==='卡片') {
        this.title('自定义仪表盘 · 单卡')
        Text('只添加或删除自己的文字卡，不覆盖现有天气和待办。先读取基线；当前单帧适合短文字，复杂布局仍需分包适配。').fontSize(13).fontColor('#BDD0DD')
        this.input('卡片短文字',this.widgetText,(v:string)=>{this.widgetText=v;})
        Button('1 · 读取仪表盘基线').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.dashboardRead()))
        Button('2 · 安装 / 更新文字卡').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.widget(this.widgetText)))
        Button('3 · 删除本次测试卡').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.removeWidget()))
        Text(this.dashboardNote).fontSize(13).fontColor('#BDD0DD')
        Text(this.note).fontSize(13).fontColor('#BDD0DD')
      } else if(this.tab==='模型') {
        this.title('语音与自定义模型')
        Text(this.modelName + ' · 阿里流式 ASR').fontSize(15).fontColor('#62E9B1')
        Column({space:12}) {
          Text('我说').fontSize(12).fontColor('#96AEBD').width('100%')
          Text(this.voiceTranscript || '唤醒眼镜后，识别文字会显示在这里').fontSize(16).fontColor('#D4E7F5').width('100%')
          Text('AI 回答').fontSize(12).fontColor('#62E9B1').width('100%')
          Text(this.voiceAnswer || '等待你的问题').fontSize(16).fontColor('#E7F4FF').width('100%')
        }.padding(18).width('100%').backgroundColor('#243D4E').borderRadius(18)
        Text('回答完整显示后 10 秒退出').fontSize(12).fontColor('#9EB5C5')
        Button(this.voiceEnabled ? '语音已开启 · 等待眼镜唤醒' : '开启语音对话')
          .width('100%').height(52).backgroundColor('#62E9B1').fontColor('#08241F')
          .enabled(this.connected&&!this.busy&&!this.voiceEnabled).onClick(()=>this.run(()=>this.enableVoice(false)))
        if(this.voiceEnabled) {
          Button('关闭自动语音待命').onClick(()=>this.run(async()=>{
            const c=await this.vault.load();c.automaticVoice=false;await this.vault.save(c);connectedServices.invalidate();probeSession.voice.disable();this.refreshVoice();
          }))
        }
        Text(this.voiceNote).fontSize(12).fontColor('#62E9B1')
        Button(this.showServiceConfig ? '收起服务配置' : '服务配置  ›').width('100%')
          .onClick(()=>{this.showServiceConfig=!this.showServiceConfig;})
        if(this.showServiceConfig) {
        Text('唤醒后收音并发送到阿里 ASR，文字交给自有模型，不保存对话音频。再次唤醒可打断；眼镜发起后续收音时，识别到新话语才中断旧回答。没有新话语时回答结束 10 秒退出。TTS 与长时间锁屏待验。').fontSize(13).fontColor('#BDD0DD')
        this.input('阿里 ASR Host',this.asrHost,(v:string)=>{this.asrHost=v;})
        this.input('ASR 模型名称',this.asrModel,(v:string)=>{this.asrModel=v;})
        this.input('ASR API Key',this.asrKey,(v:string)=>{this.asrKey=v;},true)
        Button('保存 ASR 配置').enabled(!this.busy&&!probeSession.voice.active).onClick(()=>this.run(()=>this.saveConfig()))
        Button('检查 ASR 连接（不收音）').enabled(!this.busy&&!probeSession.voice.active).onClick(()=>this.run(()=>this.checkASR()))
        Text(this.configStatus).fontSize(12).fontColor('#9EB5C5')
        this.input('OpenAI 兼容 API Base URL',this.modelURL,(v:string)=>{this.modelURL=v;})
        this.input('模型名称',this.modelName,(v:string)=>{this.modelName=v;})
        this.input('模型 API Key',this.modelKey,(v:string)=>{this.modelKey=v;},true)
        this.input('可编辑系统提示词',this.prompt,(v:string)=>{this.prompt=v;})
        Button('保存模型配置').enabled(!this.busy).onClick(()=>this.run(()=>this.saveConfig()))
        Text(this.configStatus).fontSize(12).fontColor('#9EB5C5')
        }
        this.title('模型 Tools · 联网搜索')
        Text(this.tinyfishEnabled&&this.tinyfishConfigured?'web_search · TinyFish 已配置并启用':'web_search · 尚未启用或缺 Key').fontSize(13).fontColor('#9EB5C5')
        Toggle({type:ToggleType.Switch,isOn:this.tinyfishEnabled}).onChange((v:boolean)=>{this.tinyfishEnabled=v;})
        this.input('TinyFish API Key',this.tinyfishKey,(v:string)=>{this.tinyfishKey=v;},true)
        Text('只搜索公开资料，每轮最多两次。必要检索词发送给 TinyFish，来源摘要回传当前模型；不接管浏览器，不读取其他应用。开关修改需保存。').fontSize(12).fontColor('#9EB5C5')
        Button('保存搜索设置').enabled(!this.busy).onClick(()=>this.run(()=>this.saveConfig()))
        Button('测试联网搜索').enabled(!this.busy).onClick(()=>this.run(async()=>{
          await this.saveConfig();const result=await this.services.search(this.config,'TinyFish Search API 官方文档');
          this.configStatus=`TinyFish 返回 ${result.results.length} 条来源`;this.answer=result.results.map(row=>`${row.title}\n${row.url}`).join('\n');
        }))
        Button(this.showVoiceDiagnostics ? '收起诊断信息' : '诊断与文字测试  ›').width('100%')
          .onClick(()=>{this.showVoiceDiagnostics=!this.showVoiceDiagnostics;})
        if(this.showVoiceDiagnostics) {
        Text(this.voiceAudit).fontSize(12).fontColor('#9EB5C5')
        Button('测试 ASR → 校验文字').enabled(this.connected&&!this.busy&&!this.voiceEnabled).onClick(()=>this.run(()=>this.enableVoice(true)))
        this.input('文字测试问题',this.question,(v:string)=>{this.question=v;})
        Button('请求当前模型').enabled(!this.busy).onClick(()=>this.run(()=>this.chat()))
        Text(this.answer).fontSize(15).fontColor('#E7F4FF').copyOption(CopyOptions.InApp)
        Button('将回答前 96 字显示到眼镜').enabled(this.connected&&!this.busy&&this.answer.length>0)
          .onClick(()=>this.run(async()=>{if(probeSession.prompterOccupied()||probeSession.recordingOccupied()||probeSession.voice.state.enabled)throw new Error('请先结束提词、录音或语音任务');await probeSession.features.show(this.answer.slice(0,96));}))
        Button('退出眼镜文字显示').enabled(this.connected&&!this.busy).onClick(()=>this.run(()=>probeSession.features.stopDisplay()))
        Button('清空本轮模型历史').onClick(()=>{this.services.clearHistory();this.answer='';})
        Text(this.displayNote).fontSize(13).fontColor('#BDD0DD')
        }
      } else if(this.tab==='录音') {
        RecordingPanel()
      } else if(this.tab==='提词器') {
        TeleprompterPanel()
      } else if(this.tab==='通知') {
        NotificationPanel()
      } else if(this.tab==='待办'||this.tab==='资料') {
        LibraryPanel({category:this.tab})
      } else {
        NavigationPanel()
      }
    }.padding(20).width('100%').backgroundColor('#192936').borderRadius(20).alignItems(HorizontalAlign.Start)
  }
}
