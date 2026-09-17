import { Candidate, Discovery, DiscoveryReport, TransportProbe, ProbeReport, BleHandshakeTransport, BleHandshakeReport } from 'turbo_core';
import { BleVersionProbe, VersionProbeReport, AndroidVersionReply, LocalProtocolIdentity, AndroidVersionRequest } from 'turbo_core';
import { BleGuestAuthProbe, GuestAuthProbeReport } from 'turbo_core';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DeviceFeatures } from './DeviceFeatures';
import { VoiceSession } from './VoiceSession';
import { ConnectionStore, SavedGlasses } from './ConnectionStore';
import { BluetoothBackground } from './BluetoothBackground';

export class ConnectionView {
  phase: string = 'idle';
  note: string = '添加你的眼镜，开始连接';
  name: string = 'RayNeo iO';
  saved: boolean = false;
  autoConnect: boolean = true;
  battery: number = -1;
  seconds: number = 0;
  backgroundReport: string = '后台保持尚未测试';
}

class ProbeSession {
  background: BluetoothBackground = new BluetoothBackground();
  private backgroundAt: number = 0;
  private backgroundIntent: number = 0;
  connection: ConnectionView = new ConnectionView();
  onConnection: () => void = (): void => {};
  private store: ConnectionStore = new ConnectionStore();
  private saved: SavedGlasses = new SavedGlasses();
  private context: common.Context | undefined = undefined;
  private loaded: Promise<void> | undefined = undefined;
  private managed: boolean = false;
  private paused: boolean = false;
  private selected: Candidate | undefined = undefined;
  private retry: number = -1;
  private initializeTimer: number = -1;
  private retries: number = 0;
  private saving: boolean = false;
  private storeFailed: boolean = false;
  foreground: boolean = true;
  onDiscovery: (report: DiscoveryReport) => void = (_: DiscoveryReport): void => {};
  onProbe: (report: ProbeReport) => void = (_: ProbeReport): void => {};
  onHandshake: (report: BleHandshakeReport) => void = (_: BleHandshakeReport): void => {};
  onVersion: (report: VersionProbeReport) => void = (_: VersionProbeReport): void => {};
  identity: LocalProtocolIdentity = new LocalProtocolIdentity();
  peerInfo: AndroidVersionReply | null = null;
  peerDeviceId: string = '';
  onAuth: (report: GuestAuthProbeReport) => void = (_: GuestAuthProbeReport): void => {};
  onTodo: (peer:string,payload:Uint8Array)=>void = (_peer:string,_payload:Uint8Array):void=>{};
  onNavigationSuspend: ()=>void = ():void=>{};
  onFileTranscriptionSuspend: ()=>void = ():void=>{};
  onRecording: (peer:string,payload:Uint8Array)=>void = (_peer:string,_payload:Uint8Array):void=>{};
  onRecordingDisconnected: ()=>void = ():void=>{};
  recordingOccupied: ()=>boolean = ():boolean=>false;
  onPrompter: (peer:string,business:number,payload:Uint8Array)=>void = (_peer:string,_business:number,_payload:Uint8Array):void=>{};
  onPrompterDisconnected: ()=>void = ():void=>{};
  onPrompterSuspend: ()=>void = ():void=>{};
  prompterOccupied: ()=>boolean = ():boolean=>false;
  onNotification: (peer:string,payload:Uint8Array)=>void = (_peer:string,_payload:Uint8Array):void=>{};
  onNotificationDisconnected: ()=>void = ():void=>{};
  features: DeviceFeatures = new DeviceFeatures((business: number, payload: Uint8Array): Promise<void> => this.auth.sendBusiness(business,payload));
  voice: VoiceSession = new VoiceSession((business: number, payload: Uint8Array): Promise<void> => this.auth.sendBusiness(business,payload));
  auth: BleGuestAuthProbe = new BleGuestAuthProbe((report: GuestAuthProbeReport): void => {
    if(report.stage!=='connected')this.onRecordingDisconnected();
    if(report.stage!=='connected')this.onPrompterDisconnected();
    if(report.stage!=='connected')this.onNotificationDisconnected();
    this.features.connected(report.stage === 'connected',report.battery); this.voice.connected(report.stage === 'connected'); this.onAuth(report);
    this.authChanged(report);
  });
  constructor() {
    this.voice.canBegin=():boolean=>!this.recordingOccupied()&&!this.prompterOccupied()&&!this.features.displayActive;
    this.auth.onBusiness = (business: number, payload: Uint8Array): void => { this.features.receive(business,payload);this.voice.receive(business,payload);if(business===22)this.onTodo(this.peerDeviceId,payload);if(business===14)this.onRecording(this.peerDeviceId,payload);if(business===18||business===20)this.onPrompter(this.peerDeviceId,business,payload);if(business===21)this.onNotification(this.peerDeviceId,payload); };
    this.background.changed = (): void => this.onConnection();
    this.background.revoked = (): void => {
      this.connection.backgroundReport = '后台任务被系统收回；未继续后台连接';
      if (!this.foreground) this.stop();
      this.onConnection();
    };
  }
  version: BleVersionProbe = new BleVersionProbe((report: VersionProbeReport): void => { this.onVersion(report); this.versionChanged(report); },
    (reply: AndroidVersionReply): void => { this.peerInfo = reply; });
  private intent: number = 0;
  discovery: Discovery = new Discovery((report: DiscoveryReport): void => { this.onDiscovery(report); });
  probe: TransportProbe = new TransportProbe((report: ProbeReport): void => { this.onProbe(report); });
  handshake: BleHandshakeTransport = new BleHandshakeTransport(
    (report: BleHandshakeReport): void => { this.onHandshake(report); },
    (_token: number, _bytes: Uint8Array): void => {});

  private publish(phase: string, note: string): void {
    this.connection.phase = phase; this.connection.note = note; this.onConnection();
  }
  async prepare(context: common.Context): Promise<void> {
    this.context = context;
    if (this.loaded === undefined) this.loaded = this.restore(context);
    await this.loaded;
  }
  private async restore(context: common.Context): Promise<void> {
    try {
      this.saved = await this.store.load(context);
      this.connection.saved = !!this.saved.id; this.connection.autoConnect = this.saved.autoConnect;
      this.connection.name = this.saved.name;
      this.publish('idle', this.saved.id ? '已记住眼镜，准备连接' : '首次连接请先完成权限与配对');
    } catch (_) { this.storeFailed = true; this.paused = true; this.publish('failed', '已保存的连接信息无法读取；不会覆盖原身份，请检查诊断'); }
  }
  private permitted(): boolean {
    if (!this.context) return false;
    try { return abilityAccessCtrl.createAtManager().checkAccessTokenSync(this.context.applicationInfo.accessTokenId,
      'ohos.permission.ACCESS_BLUETOOTH') === 0; } catch (_) { return false; }
  }
  async resume(context: common.Context): Promise<void> {
    if (this.backgroundAt > 0) {
      const seconds = Math.max(0, Math.floor((Date.now() - this.backgroundAt) / 1000));
      const retained = this.backgroundIntent === this.intent && this.connection.phase === 'ready' && this.background.active;
      this.connection.backgroundReport = '上次后台 ' + seconds + ' 秒 · ' + (retained ? '同一连接保持，未重新认证' : '未确认连续保持');
      this.backgroundAt = 0;
    }
    this.foreground = true; await this.prepare(context);
    this.onConnection();
    if (!this.foreground || this.managed || this.retry !== -1 || this.paused || !this.saved.id || !this.saved.autoConnect) return;
    if (!this.permitted()) { this.publish('permission', '请先允许蓝牙权限'); return; }
    this.retries = 0; await this.connect(this.savedCandidate(), context);
  }
  private savedCandidate(): Candidate {
    const c = new Candidate(); c.id = this.saved.id; c.deviceName = this.saved.name; c.serviceMatched = true; return c;
  }
  async reconnect(context: common.Context): Promise<void> {
    await this.prepare(context);
    if (!this.saved.id) { this.publish('idle', '请先扫描并选择你的眼镜'); return; }
    await this.connect(this.savedCandidate(), context);
  }
  async setAutoConnect(value: boolean): Promise<void> {
    const old = this.saved.autoConnect; this.saved.autoConnect = value;
    try { if (this.saved.id && this.context) await this.store.save(this.context, this.saved); }
    catch (_) { this.saved.autoConnect = old; this.publish(this.connection.phase, '自动连接设置未保存，请重试'); return; }
    this.connection.autoConnect = value;
    if (!value && this.connection.phase === 'retrying') this.stop();
    this.onConnection();
  }
  async connect(candidate: Candidate, context: common.Context): Promise<void> {
    await this.prepare(context);
    if (this.storeFailed) { this.publish('failed', '原连接信息不可读，已停止；不会覆盖原身份'); return; }
    if (!this.foreground || candidate.classic || !candidate.id || this.connection.phase === 'ready') return;
    if (!this.permitted()) { this.publish('permission', '请先允许蓝牙权限'); return; }
    if (this.saved.id && this.saved.id !== candidate.id) { this.publish('failed', '已有绑定眼镜；不会自动替换，请先核对设备'); return; }
    this.stop(); this.paused = false; this.managed = true; this.selected = candidate; this.retries = 0;
    await this.beginManaged();
  }
  private async beginManaged(): Promise<void> {
    if (!this.context || !this.selected || !this.canRun() || !this.managed) return;
    const generation = this.intent;
    this.publish('connecting', '正在连接眼镜并核对设备身份…');
    try {
      const phone = await this.identity.get(this.context);
      try {
        if (generation !== this.intent || !this.managed || !this.canRun() || !this.selected) return;
        this.peerInfo = null; this.peerDeviceId = this.selected.id;
        this.version.start(this.selected.id, this.versionInput(phone));
      } finally { phone.fill(0); }
    } catch (_) { if (generation === this.intent) this.failed('local-identity-unavailable', false); }
  }
  private versionInput(phone: Uint8Array): AndroidVersionRequest {
    const encoder = new util.TextEncoder();
    return { phoneIdentifier: phone, phoneNameUTF8: encoder.encodeInto('Turbo IO'),
      manufacturerUTF8: encoder.encodeInto('HUAWEI'), modelUTF8: encoder.encodeInto('HarmonyOS'),
      accountUTF8: null, publicKey: null, pairValue: null };
  }
  private versionChanged(report: VersionProbeReport): void {
    if (!this.managed) return;
    if (report.stage === 'failed') { this.failed(report.reason, this.transient(report.reason)); return; }
    if (report.stage !== 'received' || !this.peerInfo) return;
    const peer = this.peerInfo.peerIdentifier.slice();
    const hex = Array.from(peer).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
    if (this.saved.peer && this.saved.peer !== hex) { peer.fill(0); this.failed('peer-mismatch', false); return; }
    const generation = this.intent;
    this.publish('authenticating', '身份匹配，正在认证和完成系统配对…');
    // Version probe closes its transport before delivering received. Yield before reopening.
    Promise.resolve().then(async (): Promise<void> => {
      try {
        if (!this.context || !this.selected || generation !== this.intent || !this.managed) return;
        const phone = await this.identity.get(this.context);
        try {
          if (generation !== this.intent || !this.managed || !this.canRun() || !this.selected) return;
          this.auth.start(this.selected.id, this.versionInput(phone), peer, true, true);
        } finally { phone.fill(0); }
      } catch (_) { if (generation === this.intent) this.failed('auth-start-failed', false); }
      finally { peer.fill(0); }
    });
  }
  private authChanged(report: GuestAuthProbeReport): void {
    if (!this.managed) return;
    this.connection.battery = report.battery; this.connection.seconds = report.connectedSeconds;
    if (report.stage === 'failed' || report.stage === 'closed') { this.failed(report.reason, this.transient(report.reason)); return; }
    if (report.stage === 'connected' && report.bonded) {
      if (report.statusReplies > 0) {
        const becameReady=this.connection.phase!=='ready';
        this.retries = 0;
        if (this.initializeTimer !== -1) clearTimeout(this.initializeTimer); this.initializeTimer = -1;
        this.publish('ready', '已连接 · 认证与状态回读完成');
        if(becameReady&&this.saved.backgroundEnabled&&this.foreground)this.setBackground(true);
        if (!this.saving && !this.saved.id) this.saveVerified();
      } else {
        this.publish('initializing', '配对完成，正在读取电量与设备状态…');
        if (this.initializeTimer === -1) {
          const generation = this.intent;
          this.initializeTimer = setTimeout((): void => {
            this.initializeTimer = -1;
            if (generation === this.intent && this.managed) this.failed('status-timeout', true);
          }, 12000);
        }
      }
    }
  }
  private async saveVerified(): Promise<void> {
    if (!this.context || !this.selected || !this.peerInfo) return;
    this.saving = true; const generation = this.intent;
    const value = new SavedGlasses(); value.id = this.selected.id;
    value.peer = Array.from(this.peerInfo.peerIdentifier).map((b: number): string => b.toString(16).padStart(2, '0')).join('');
    value.name = (this.selected.deviceName || 'RayNeo iO').slice(0,64); value.autoConnect = this.connection.autoConnect;
    try {
      await this.store.save(this.context, value); this.saved = value;
      this.connection.saved = true; this.connection.name = value.name; this.onConnection();
    } catch (_) { if (generation === this.intent) this.publish('ready', '已连接，但自动连接信息未保存'); }
    finally { this.saving = false; }
  }
  private transient(reason: string): boolean {
    return ['transport-timeout', 'version-timeout', 'auth-timeout', 'status-timeout', 'connection-state-0',
      'disconnected', 'connection-failed', 'connect-failed', 'version-send-failed', 'send-failed'].includes(reason);
  }
  private failed(reason: string, retryable: boolean): void {
    if (!this.managed) return;
    this.managed = false; this.intent++; this.closeRadios();
    if (this.initializeTimer !== -1) clearTimeout(this.initializeTimer); this.initializeTimer = -1;
    const delays: number[] = [2000, 5000, 10000];
    if (retryable && this.saved.id && this.saved.autoConnect && this.canRun() && !this.paused && this.retries < delays.length) {
      const delay = delays[this.retries++]; const generation = this.intent;
      this.publish('retrying', `连接中断，${delay / 1000} 秒后重试（${this.retries}/3）`);
      this.retry = setTimeout((): void => {
        this.retry = -1; if (generation !== this.intent || !this.canRun() || this.paused || !this.permitted()) return;
        this.managed = true; this.beginManaged();
      }, delay);
    } else {
      this.background.stop('连接已结束，后台任务已释放');
      this.publish('failed', reason === 'peer-mismatch' ? '眼镜身份与原绑定不符，已停止连接' : '连接未完成，请确认眼镜在附近、蓝牙开启后重试');
    }
  }
  private canRun(): boolean { return this.foreground || this.background.active; }
  async setBackground(enabled: boolean): Promise<void> {
    if (!enabled) { await this.background.stop();await this.saveBackgroundPreference(false);if (!this.foreground) this.stop(); return; }
    if (!this.foreground || this.connection.phase !== 'ready' || !this.context) {
      this.background.note='请保持 App 前台并等待眼镜连接完成';this.onConnection();return;
    }
    const generation = this.intent; await this.background.start(this.context);
    if (generation !== this.intent || this.connection.phase !== 'ready') await this.background.stop('连接已变化，请重新开启后台保持');
    else if(this.background.active)await this.saveBackgroundPreference(true);
  }
  private async saveBackgroundPreference(enabled:boolean):Promise<void>{
    if(!this.context||!this.saved.id||this.saved.backgroundEnabled===enabled)return;
    const old=this.saved.backgroundEnabled;this.saved.backgroundEnabled=enabled;
    try{await this.store.save(this.context,this.saved);}
    catch(_){this.saved.backgroundEnabled=old;this.background.note+=' · 偏好保存失败，下次启动需手动开启';this.onConnection();}
  }
  suspend(): void {
    this.onNavigationSuspend();
    this.onFileTranscriptionSuspend();
    this.onPrompterSuspend();
    this.foreground = false; this.backgroundAt = Date.now(); this.backgroundIntent = this.intent;
    if (this.background.active && this.managed) { this.connection.backgroundReport = '后台保持中'; this.onConnection(); return; }
    const paused = this.paused; this.stop(); this.paused = paused;
  }

  inspect(candidate: Candidate): void {
    if (!this.foreground) { return; }
    this.stop();
    this.probe.inspect(candidate);
  }

  inspectNotifications(candidate: Candidate): void {
    if (!this.foreground || candidate.classic) return;
    this.stop();
    this.handshake.open(candidate.id);
  }

  async inspectVersion(candidate: Candidate, context: common.Context): Promise<void> {
    if (!this.foreground || candidate.classic) return;
    this.stop(); const intent = this.intent;
    const phone = await this.identity.get(context);
    try {
      if (!this.foreground || intent !== this.intent) return;
      this.peerInfo = null;
      this.peerDeviceId = candidate.id;
      const encoder = new util.TextEncoder();
      const input: AndroidVersionRequest = {phoneIdentifier:phone, phoneNameUTF8:encoder.encodeInto('Turbo IO'),
        manufacturerUTF8:encoder.encodeInto('HUAWEI'), modelUTF8:encoder.encodeInto('HarmonyOS'), accountUTF8:null, publicKey:null, pairValue:null};
      this.version.start(candidate.id, input);
    } finally { phone.fill(0); }
  }

  async inspectAuth(candidate: Candidate, context: common.Context): Promise<void> {
    if (!this.foreground || candidate.classic || this.peerInfo === null || this.peerDeviceId !== candidate.id) throw new Error('version-baseline-required');
    const peer = this.peerInfo.peerIdentifier.slice(); this.stop(); const intent = this.intent;
    const phone = await this.identity.get(context);
    try {
      if (!this.foreground || intent !== this.intent) return;
      const encoder = new util.TextEncoder();
      const input: AndroidVersionRequest = {phoneIdentifier:phone, phoneNameUTF8:encoder.encodeInto('Turbo IO'),
        manufacturerUTF8:encoder.encodeInto('HUAWEI'), modelUTF8:encoder.encodeInto('HarmonyOS'), accountUTF8:null, publicKey:null, pairValue:null};
      this.auth.start(candidate.id, input, peer, true, true);
    } finally { phone.fill(0); peer.fill(0); }
  }

  stop(): void {
    this.intent++; this.managed = false; this.paused = true;
    this.background.stop();
    if (this.retry !== -1) clearTimeout(this.retry); this.retry = -1;
    if (this.initializeTimer !== -1) clearTimeout(this.initializeTimer); this.initializeTimer = -1;
    this.closeRadios(); this.publish('idle', '连接已停止；可点重新连接');
  }
  private closeRadios(): void {
    this.discovery.stop();
    this.probe.close();
    this.handshake.close();
    this.version.cancel();
    this.auth.cancel();
  }
}
export const probeSession: ProbeSession = new ProbeSession();
