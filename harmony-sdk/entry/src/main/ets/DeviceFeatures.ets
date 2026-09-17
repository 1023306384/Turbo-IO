import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { businessEnvelope, launcherCommand, currentWeather, dashboardQuery, installTextWidget,
  removeTextWidget, HARMONY_WIDGET_ID, displayStart, displayText, displayStop, readLauncherEnvelope } from 'turbo_core';

export class FeatureState {
  connected: boolean = false;
  battery: number = -1;
  note: string = '请先连接眼镜';
  weather: string = '天气未下发';
  dashboard: string = '仪表盘未读取';
  display: string = '显示会话未开启';
  displayReady: boolean = false;
  received: number = 0;
}
export class DeviceFeatures {
  state: FeatureState = new FeatureState();
  changed: () => void = (): void => {};
  private send: (business: number, payload: Uint8Array) => Promise<void>;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private sequence: number = 1000;
  private pending: string = '';
  private pendingSequence: number = 0;
  private timer: number = -1;
  private baselineAt: number = 0;
  private baselineHasOwned: boolean = false;
  private installedThisSession: boolean = false;
  private sid: string = '';
  private desiredText: string = '';
  private displayTimer: number = -1;
  private displayDeadline: number = -1;
  private continuousDisplay: boolean = false;
  private closing:boolean=false;
  private sending: boolean = false;
  constructor(send: (business: number, payload: Uint8Array) => Promise<void>) { this.send = send; }
  get displayActive(): boolean { return this.sid.length > 0; }
  get displayClosing():boolean{return this.closing;}
  confirmDisplayExited():void {
    if(!this.closing)throw new Error('只能确认正在退出的会话');
    this.clearDisplay();this.state.display='用户确认眼镜已回首页（非设备回执）';this.changed();
  }
  get launcherBusy(): boolean { return this.pending.length > 0 || this.sending; }
  connected(connected: boolean, battery: number): void {
    this.state.connected = connected; this.state.battery = battery;
    if (!connected) {
      this.baselineAt = 0;
      this.installedThisSession=false;this.baselineHasOwned=false;
      if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1; this.pending = '';
      if (this.sid) this.state.display = '连接已断；如镜片未退出，请按实体按钮';
      this.clearDisplay();
    }
    this.changed();
  }
  private async submit(business: number, type: number, json: string, sequence: number = 0): Promise<void> {
    if (!this.state.connected) throw new Error('请先连接眼镜');
    if (this.sending) throw new Error('上一条仍在发送，请稍后');
    const packet = businessEnvelope(type, this.encoder.encodeInto(json), sequence);
    this.sending = true;
    try { await this.send(business, packet); }
    finally { packet.fill(0); this.sending = false; }
  }
  private async launcher(type: number, json: string, command: string): Promise<void> {
    if (this.pending) throw new Error('上一条指令仍在等待回执');
    this.pending = command; this.pendingSequence = ++this.sequence;
    this.state.note = `${command}：正在发送`;
    this.timer = setTimeout(() => {
      this.timer = -1; this.state.note = `${this.pending}：8 秒未收到匹配回报，不代表成功`;
      this.pending = ''; this.changed();
    }, 8000);
    try {
      await this.submit(15, type, json, this.pendingSequence);
      if (this.pending) this.state.note = `${command}：已提交，等待眼镜回执`;
    } catch (e) {
      if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1; this.pending = '';
      this.state.note = '未提交：请检查连接和内容长度'; throw new Error('蓝牙指令未提交，请检查连接或缩短内容');
    } finally { this.changed(); }
  }
  async refreshStatus(): Promise<void> { await this.launcher(1, launcherCommand('request_general_status', 0), 'request_general_status'); }
  async refreshSettings(): Promise<void> { await this.launcher(4, launcherCommand('request_general_settings', 0), 'request_general_settings'); }
  async voiceWakeup(): Promise<void> { await this.launcher(16, launcherCommand('set_ai_voice_wakeup', 0, 1), 'set_ai_voice_wakeup'); }
  async brightness(value: number): Promise<void> {
    if (![7,8].includes(value)) throw new Error('仅开放 V1 已测亮度档位 7 / 8');
    await this.launcher(2, launcherCommand('brightness_change', value), 'brightness_change');
  }
  async sleepTime(value: number): Promise<void> {
    if (![15,25].includes(value)) throw new Error('仅开放 V1 已测休眠档位');
    await this.launcher(5, launcherCommand('auto_lock_time', value), 'auto_lock_time');
  }
  async weather(city: string, temp: number, icon: number): Promise<void> {
    await this.launcher(18, currentWeather(city, temp, icon, Math.floor(Date.now()/1000)), 'current_weather_update');
    this.state.weather = `${city} ${temp}°：已提交首页天气，镜片效果待确认`; this.changed();
  }
  async dashboardRead(): Promise<void> { await this.launcher(18, dashboardQuery(), 'dashboard_config'); }
  async widget(text: string): Promise<void> {
    if (!this.baselineAt || Date.now()-this.baselineAt > 120000) throw new Error('请先读取新仪表盘基线');
    if (this.baselineHasOwned && !this.installedThisSession) throw new Error('已有同名卡片，拒绝覆盖未知来源内容');
    const json=installTextWidget(text),packet=businessEnvelope(18,this.encoder.encodeInto(json),this.sequence+1);
    const tooLarge=packet.length+10>509;packet.fill(0);
    if(tooLarge)throw new Error('卡片文字编码后超过单帧容量，请缩短到约 15 个汉字；符号也占容量');
    await this.launcher(18, json, 'widget_install');
  }
  async removeWidget(): Promise<void> {
    if (!this.installedThisSession) throw new Error('只能删除本次会话成功安装的测试卡');
    await this.launcher(18, removeTextWidget(), 'widget_uninstall');
  }
  receive(business: number, bytes: Uint8Array): void {
    if (![15,19].includes(business)) return;
    try {
      const packet = readLauncherEnvelope(bytes);
      if (business === 19 && packet.type === 4 && this.sid) { this.stopDisplay().catch(()=>{}); return; }
      if (!packet.json.length) return;
      const j = JSON.parse(new util.TextDecoder('utf-8',{fatal:true}).decodeToString(packet.json)) as Record<string,Object>;
      this.state.received++;
      if (business === 19) { this.displayReceived(packet.type, j); return; }
      const command = typeof j['cmd'] === 'string' ? j['cmd'] as string : '';
      if (packet.type === 19 && ['widget_install','widget_uninstall'].includes(this.pending) && packet.sequence === this.pendingSequence && typeof j['code'] === 'number') {
        const ok = j['code'] === 0;
        if (ok) this.installedThisSession = this.pending === 'widget_install';
        this.complete(this.pending, ok); this.changed(); return;
      }
      if (packet.type === 1 && this.pending === 'request_general_status') this.complete('request_general_status', true);
      if (packet.type === 4 && this.pending === 'request_general_settings') this.complete('request_general_settings', true);
      if (packet.type === 19 && command === 'dashboard_config' && this.pending === command) {
        const payload = j['payload'] as Record<string,Object>;
        let data: Object = payload?.['data'];
        if (typeof data === 'string') data = JSON.parse(data) as Object;
        if (data && typeof data === 'object' && Array.isArray((data as Record<string,Object>)['widgets_v2'])) {
          this.baselineAt = Date.now(); this.baselineHasOwned = JSON.stringify(data).includes(`"${HARMONY_WIDGET_ID}"`);
          this.state.dashboard = this.baselineHasOwned ? '已回读，包含 Turbo IO 卡片' : '已回读原配置；安装只添加自己的单卡';
        }
      }
      if (command && command === this.pending && [3,6,17,19].includes(packet.type)) {
        const payload = j['payload'] as Record<string,Object>;
        if(command==='current_weather_update'){
          if(typeof payload?.['value']!=='number')return;
          const accepted=payload['value']===0;
          this.state.weather=accepted?this.state.weather.replace('已提交首页天气，镜片效果待确认','眼镜回执成功，镜片效果待确认'):'眼镜未接受天气 · value='+String(payload['value']);
          this.complete(command,accepted);this.changed();return;
        }
        // value meanings differ by command: preserve the literal ACK summary,
        // never interpret an arbitrary numeric value as success.
        if (command !== 'widget_install' && command !== 'widget_uninstall') this.complete(command, true);
      }
      this.changed();
    } catch (_) { /* Unrecognized business payload is not a transport failure. */ }
  }
  private complete(command: string, accepted: boolean): void {
    if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1;
    this.pending = ''; this.state.note = `${command}：${accepted ? '收到眼镜回报；镜片效果待验收' : '回执值未确认成功，请勿重复覆盖'}`;
  }
  async show(text: string, continuous: boolean = false): Promise<void> {
    if (!this.state.connected) throw new Error('请先连接眼镜');
    if (this.sid) throw new Error('请先退出当前显示会话');
    const random = cryptoFramework.createRandom().generateRandomSync(16).data;
    this.sid = Array.from(random).map((b:number)=>b.toString(16).padStart(2,'0')).join(''); random.fill(0);
    this.continuousDisplay = continuous;
    this.desiredText = text.slice(0,96); this.state.displayReady = false;
    this.state.display = '正在开启临时纯显示；不启动麦克风'; this.changed();
    this.displayTimer = setTimeout(() => { this.stopDisplay().catch(()=>{}); }, 10000);
    try { await this.submit(19, 7, displayStart(this.sid)); }
    catch (e) { this.clearDisplay(); this.state.display = '显示启动未提交'; this.changed(); throw new Error('显示启动未提交'); }
  }
  async updateDisplay(text: string): Promise<void> {
    if (!this.sid || !this.state.displayReady) throw new Error('请先开启显示，等待眼镜确认');
    await this.submit(19, 5, displayText(this.sid, text.slice(0,96)));
    this.state.display = '文字已提交 · 以镜片实际显示为准'; this.changed();
  }
  private displayReceived(type: number, body: Record<string,Object>): void {
    if (body['sid'] !== this.sid || !this.sid) return;
    if (type === 8 && !this.state.displayReady && !this.closing) {
      if (body['code'] !== 1 && body['code'] !== 2) { this.stopDisplay().catch(()=>{}); return; }
      if (this.displayTimer !== -1) clearTimeout(this.displayTimer); this.displayTimer = -1;
      this.state.displayReady = true;
      if (!this.continuousDisplay) this.displayDeadline = setTimeout(() => { this.stopDisplay().catch(()=>{}); }, 180000);
      // Next task avoids reentrant writes inside the native RX callback.
      this.displayTimer = setTimeout(() => {
        this.displayTimer = -1;
        this.updateDisplay(this.desiredText).catch(()=>{this.state.display='文字发送失败，请退出后重试';this.changed();});
      }, 0);
    }
    if (type === 3) { this.clearDisplay(); this.state.display = '收到同会话退出消息'; }
    if (type === 4) { this.stopDisplay().catch(()=>{}); this.state.display = '检测到音频，停止纯显示测试'; }
    this.changed();
  }
  async stopDisplay(): Promise<void> {
    const sid = this.sid;if(!sid||this.closing)return;
    this.closing=true;this.state.displayReady=false;
    if(this.displayTimer!==-1)clearTimeout(this.displayTimer);if(this.displayDeadline!==-1)clearTimeout(this.displayDeadline);
    this.displayTimer=-1;this.displayDeadline=setTimeout(()=>{
      this.displayDeadline=-1;if(this.sid===sid&&this.closing){this.state.display='退出未确认，请按眼镜按钮回首页后确认；未释放显示占用';this.changed();}
    },8000);
    try { await this.submit(19, 3, displayStop(sid)); this.state.display = '退出已提交；若仍显示请按实体按钮'; }
    finally { this.changed(); }
  }
  private clearDisplay(): void {
    if (this.displayTimer !== -1) clearTimeout(this.displayTimer);
    if (this.displayDeadline !== -1) clearTimeout(this.displayDeadline);
    this.displayTimer = -1; this.displayDeadline = -1; this.sid = ''; this.desiredText = ''; this.state.displayReady = false;
    this.continuousDisplay = false;this.closing=false;
  }
}
