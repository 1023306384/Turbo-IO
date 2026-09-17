import { BleHandshakeTransport, BleHandshakeReport } from './BleHandshakeTransport';
import { GuestAuthExchange } from './GuestAuthExchange';
import { HarmonySha256 } from './HarmonySha256';
import { HarmonyHandshakeRuntime } from './HarmonyHandshakeRuntime';
import { AndroidVersionRequest, androidVersionRequest } from './AndroidVersionExchange';
import { FrameStream, FramePacket, encodeFrame, decodeTlvs } from './ProtocolCodec';
import { connection } from '@kit.ConnectivityKit';
import { util } from '@kit.ArkTS';
import { generalStatusQuery, readLauncherEnvelope } from './LauncherStatus';

export class GuestAuthProbeReport {
  stage: string = 'idle';
  reason: string = '';
  mtu: number = 23;
  txBytes: number = 0;
  rxBytes: number = 0;
  bonded: boolean = false;
  peerPairStatus: number = -1;
  connectedSeconds: number = 0;
  lastMessage: string = '';
  battery: number = -1;
  statusReplies: number = 0;
  statusQuery: string = 'not-sent';
}

// Default remains a proof-only probe. Explicit maintain=true performs system
// pairing, retains the foreground connection and reads general status.
// Explicit unbound confirmation + protocol peer ID are required from the owner.
// Correlation: per-client generation, protocol ID, stage and proof. Peer message
// numbers are not assumed to echo TX. Profile flags=0, no ACK or protocol fragments.
// No official account or SDK reuse. A connected link does not imply all services.
export class BleGuestAuthProbe {
  onBusiness: (business: number, payload: Uint8Array) => void = (_b: number, _p: Uint8Array): void => {};
  private transport: BleHandshakeTransport | undefined = undefined;
  private exchange: GuestAuthExchange = new GuestAuthExchange(new HarmonySha256());
  private runtime: HarmonyHandshakeRuntime = new HarmonyHandshakeRuntime();
  private stream: FrameStream = new FrameStream();
  private attempt: number = 0;
  private active: boolean = false;
  private maintain: boolean = false;
  private deviceId: string = '';
  private sessionKey: Uint8Array = new Uint8Array();
  private bondListener: ((state: connection.BondStateParam) => void) | undefined = undefined;
  private statusTimer: number = -1;
  private authenticatedAt: number = 0;
  private queryTimer: number = -1;
  private busy: boolean = false;
  private timer: number = -1;
  private messageNumber: number = 0;
  private transportToken: number = 0;
  private queue: Uint8Array[] = [];
  private queuedBytes: number = 0;
  private input: AndroidVersionRequest | undefined = undefined;
  private peer: Uint8Array = new Uint8Array();
  private report: GuestAuthProbeReport = new GuestAuthProbeReport();
  private update: (report: GuestAuthProbeReport) => void;
  constructor(update: (report: GuestAuthProbeReport) => void) { this.update = update; }
  private emit(): void {
    const copy = new GuestAuthProbeReport(); copy.stage = this.report.stage; copy.reason = this.report.reason;
    copy.mtu = this.report.mtu; copy.txBytes = this.report.txBytes; copy.rxBytes = this.report.rxBytes;
    copy.bonded = this.report.bonded; copy.peerPairStatus = this.report.peerPairStatus;
    copy.connectedSeconds = this.report.connectedSeconds; copy.lastMessage = this.report.lastMessage;
    copy.battery = this.report.battery; copy.statusReplies = this.report.statusReplies; copy.statusQuery = this.report.statusQuery;
    this.update(copy);
  }
  private current(token: number): boolean { return this.active && token === this.attempt; }
  start(deviceId: string, input: AndroidVersionRequest, protocolPeerIdentifier: Uint8Array, confirmedUnbound: boolean, maintain: boolean = false): void {
    if (this.active) throw new Error('auth-probe-busy');
    if (!confirmedUnbound) throw new Error('unbound-confirmation-required');
    if (!deviceId || deviceId.length > 128 || protocolPeerIdentifier.length !== 6 || this.attempt >= Number.MAX_SAFE_INTEGER - 1) throw new Error('auth-probe-input');
    if (input.accountUTF8 !== null || input.publicKey !== null) throw new Error('guest-explicit-only');
    androidVersionRequest(input); // Validate before opening a radio connection.
    this.maintain = maintain; this.deviceId = deviceId;
    this.input = {phoneIdentifier: input.phoneIdentifier.slice(), phoneNameUTF8: input.phoneNameUTF8.slice(),
      manufacturerUTF8: input.manufacturerUTF8.slice(), modelUTF8: input.modelUTF8.slice(),
      accountUTF8: null, publicKey: null, pairValue: input.pairValue};
    this.peer = protocolPeerIdentifier.slice(); this.exchange = new GuestAuthExchange(new HarmonySha256());
    this.stream.reset(); this.report = new GuestAuthProbeReport(); this.report.stage = 'connecting';
    const token = ++this.attempt; this.active = true; this.busy = false;
    this.transport = new BleHandshakeTransport((r: BleHandshakeReport): void => { this.onTransport(token, r); },
      (_transportToken: number, bytes: Uint8Array): void => {
        if (!this.current(token)) return;
        // A final proof can close transport before its next report callback.
        this.report.rxBytes += bytes.length;
        if (this.queue.length >= 64 || this.queuedBytes + bytes.length > 8192) { this.finish('failed', 'receive-queue-limit'); return; }
        this.queue.push(bytes.slice()); this.queuedBytes += bytes.length; this.drain(token);
      });
    this.transportToken = this.transport.open(deviceId);
  }
  private onTransport(token: number, report: BleHandshakeReport): void {
    if (!this.current(token)) return;
    this.transportToken = report.generation;
    this.report.mtu = report.mtu; this.report.txBytes = report.txBytes; this.report.rxBytes = report.rxBytes;
    if (report.stage === 'failed' || report.stage === 'closed') { this.finish('failed', report.reason); return; }
    if (report.stage === 'ready' && this.report.stage === 'connecting') {
      if (this.input === undefined) { this.finish('failed', 'missing-input'); return; }
      let random = new Uint8Array(); let sequence = new Uint8Array();
      try {
        random = this.runtime.random(4); sequence = this.runtime.random(2);
        this.messageNumber = sequence[0] * 256 + sequence[1];
        const payload = this.exchange.begin(this.input, this.peer, random, this.runtime.now());
        this.report.stage = 'version';
        this.timer = setTimeout(() => { if (this.current(token)) this.finish('failed', 'auth-timeout'); }, 5000);
        this.transmit(token, payload);
      } catch (_) { this.finish('failed', 'auth-start-failed'); }
      finally { random.fill(0); sequence.fill(0); }
    }
    if (this.current(token)) this.emit();
  }
  private transmit(token: number, payload: Uint8Array, businessID: number = 0x10): void {
    if (!this.current(token) || this.transport === undefined) { payload.fill(0); return; }
    let bytes: Uint8Array;
    try {
      bytes = encodeFrame({messageNumber:this.messageNumber, flags:0, address:null,
        slices:new Uint8Array(), businessID:businessID, payload:payload});
      this.messageNumber = (this.messageNumber + 1) & 65535;
    } finally { payload.fill(0); }
    if (bytes.length > this.report.mtu - 3) {
      bytes.fill(0); this.finish('failed', 'mtu-too-small-no-fragmentation'); return;
    }
    this.busy = true;
    this.transport.send(this.transportToken, bytes).then(() => {
      bytes.fill(0); if (!this.current(token)) return;
      this.busy = false; this.drain(token);
    }).catch(() => { bytes.fill(0); if (this.current(token)) this.finish('failed', 'send-failed'); });
  }
  private drain(token: number): void {
    while (this.current(token) && !this.busy && this.queue.length > 0) {
      const bytes = this.queue.shift()!; this.queuedBytes -= bytes.length;
      try {
        const packets = this.stream.feed(bytes);
        try {
          for (const packet of packets) {
            if (!this.current(token)) break;
            if (this.busy) throw new Error('unexpected-response-batch');
            this.process(token, packet);
          }
        } finally { for (const packet of packets) packet.payload.fill(0); }
      } catch (_) { if (this.current(token)) this.finish('failed', 'response-frame-invalid'); }
      finally { bytes.fill(0); }
    }
  }
  private process(token: number, packet: FramePacket): void {
    if (this.sessionKey.length > 0) {
      // Observe metadata only; no audio/body logging and no guessed ACKs.
      this.report.lastMessage = `business=${packet.businessID}, bytes=${packet.payload.length}, flags=${packet.flags}`;
      if (packet.businessID === 0x10 && packet.flags === 0 && packet.slices.length === 0) {
        for (const field of decodeTlvs(packet.payload)) {
          if (field.tag === 0x17 && field.value.length >= 1) this.report.peerPairStatus = field.value[0];
          this.report.lastMessage = `handshake=0x${field.tag.toString(16)}, bytes=${field.value.length}`;
        }
      }
      if (packet.businessID === 15 && packet.flags === 0 && packet.slices.length === 0) {
        this.observeLauncher(packet.payload);
      }
      if (packet.flags === 0 && packet.address === null && packet.slices.length === 0) this.onBusiness(packet.businessID, packet.payload);
      this.emit(); return;
    }
    if (packet.businessID !== 0x10 || packet.flags !== 0 || packet.address !== null || packet.slices.length !== 0) throw new Error('response-profile');
    const generation = this.exchange.generation(); const now = this.runtime.now();
    if (this.exchange.stage() === 'version') {
      const payload = this.exchange.receiveVersion(generation, now, packet.payload);
      if (payload === null) { this.finish('failed', this.exchange.failure() || 'unexpected-version'); return; }
      this.report.stage = 'proof'; this.transmit(token, payload);
    } else if (this.exchange.stage() === 'proof') {
      if (!this.exchange.receiveProof(generation, now, packet.payload)) { this.finish('failed', this.exchange.failure() || 'unexpected-proof'); return; }
      const key = this.exchange.takeSessionKey(generation, this.runtime.now());
      if (key === null) { this.finish('failed', 'session-handoff-failed'); return; }
      if (!this.maintain) { key.fill(0); this.finish('verified', 'proof-only-not-paired-or-initialized'); }
      else {
        this.sessionKey = key;
        this.transport!.retainAuthenticatedSession(this.transportToken);
        if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1;
        this.authenticatedAt = this.runtime.now();
        this.report.stage = 'pairing'; this.report.reason = 'peer-verified-awaiting-system-bond';
        this.beginPairing(token); this.tickStatus(token);
      }
    } else throw new Error('unexpected-state');
  }
  cancel(): void { if (this.active) this.finish('closed', 'cancelled'); }
  async sendBusiness(business: number, payload: Uint8Array): Promise<void> {
    if (!this.active || !this.report.bonded || this.sessionKey.length !== 32 || this.transport === undefined) throw new Error('not-connected');
    if(this.outboundCount>=32)throw new Error('业务发送队列已满，请稍后重试');
    const token = this.attempt;
    const bytes = encodeFrame({messageNumber:this.messageNumber, flags:0, address:null, slices:new Uint8Array(), businessID:business, payload:payload});
    if (bytes.length > (business === 18 ? 22010 : this.report.mtu - 3)) { bytes.fill(0); throw new Error('内容超过当前蓝牙单帧容量，请缩短文字'); }
    this.messageNumber = (this.messageNumber + 1) & 65535;this.outboundCount++;
    const task=this.outbound.then(async():Promise<void>=>{
      if(!this.current(token)||!this.report.bonded||this.transport===undefined)throw new Error('连接已变化，未重放旧指令');
      if(this.busy)throw new Error('连接初始化仍在发送，请稍后');
      this.busy=true;
      try{await this.transport.send(this.transportToken,bytes);}
      finally{if(this.current(token)){this.busy=false;this.drain(token);}}
    });
    this.outbound=task.catch(()=>{});
    try{await task;}finally{bytes.fill(0);this.outboundCount--;}
  }
  private outbound:Promise<void>=Promise.resolve();
  private outboundCount:number=0;
  private beginPairing(token: number): void {
    this.bondListener = (state: connection.BondStateParam): void => {
      if (!this.current(token) || state.deviceId.toLowerCase() !== this.deviceId.toLowerCase()) return;
      if (state.state === connection.BondState.BOND_STATE_BONDED) this.acceptBond(token);
    };
    try {
      connection.on('bondStateChange', this.bondListener);
      if (connection.getPairState(this.deviceId) === connection.BondState.BOND_STATE_BONDED) { this.acceptBond(token); return; }
      this.timer = setTimeout(() => { if (this.current(token) && !this.report.bonded) this.finish('failed', 'system-pair-timeout'); }, 60000);
      connection.pairDevice(this.deviceId).then(() => {
        if (this.current(token) && connection.getPairState(this.deviceId) === connection.BondState.BOND_STATE_BONDED) this.acceptBond(token);
      }).catch(() => { if (this.current(token) && !this.report.bonded) this.finish('failed', 'system-pair-failed'); });
    } catch (_) { if (this.current(token)) this.finish('failed', 'system-pair-unavailable'); }
    if (this.current(token)) this.emit();
  }
  private acceptBond(token: number): void {
    if (!this.current(token)) return;
    if (this.report.bonded) return;
    if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1;
    this.report.bonded = true; this.report.stage = 'connected';
    this.report.reason = 'authenticated-system-bonded-business-init-pending'; this.emit();
    this.queryTimer = setTimeout(() => {
      this.queryTimer = -1;
      if (!this.current(token) || !this.report.bonded) return;
      this.report.statusQuery = 'submitted-awaiting-type1'; this.emit();
      this.transmit(token, generalStatusQuery(), 15);
    }, 0);
  }
  private observeLauncher(payload: Uint8Array): void {
    try {
      const message = readLauncherEnvelope(payload);
      this.report.lastMessage = `launcher type=${message.type}, bytes=${payload.length}`;
      if (message.type !== 1 || message.json.length === 0) return;
      const text = new util.TextDecoder('utf-8', {fatal:true}).decodeToString(message.json);
      const body = JSON.parse(text) as Record<string, Object>;
      const state = (body['generalStatus'] ?? body) as Record<string, Object>;
      const battery = state['battery'];
      if (typeof battery === 'number' && Number.isInteger(battery) && battery >= 0 && battery <= 100) this.report.battery = battery;
      this.report.statusReplies++;
      if (this.report.statusQuery === 'submitted-awaiting-type1') this.report.statusQuery = 'type1-received-after-query';
    } catch (_) { this.report.lastMessage = 'launcher-envelope-not-recognized'; }
  }
  private tickStatus(token: number): void {
    if (!this.current(token)) return;
    this.report.connectedSeconds = Math.floor((this.runtime.now() - this.authenticatedAt) / 1000); this.emit();
    this.statusTimer = setTimeout(() => { this.tickStatus(token); }, 1000);
  }
  private finish(stage: string, reason: string): void {
    this.active = false;
    if (this.timer !== -1) clearTimeout(this.timer); this.timer = -1;
    if (this.statusTimer !== -1) clearTimeout(this.statusTimer); this.statusTimer = -1;
    if (this.queryTimer !== -1) clearTimeout(this.queryTimer); this.queryTimer = -1;
    if (this.bondListener !== undefined) {
      try { connection.off('bondStateChange', this.bondListener); } catch (_) {}
      this.bondListener = undefined;
    }
    this.sessionKey.fill(0); this.sessionKey = new Uint8Array();
    this.exchange.cancel(); this.stream.reset();
    for (const bytes of this.queue) bytes.fill(0); this.queue = []; this.queuedBytes = 0;
    this.peer.fill(0); this.peer = new Uint8Array();
    if (this.input !== undefined) {
      this.input.phoneIdentifier.fill(0); this.input.phoneNameUTF8.fill(0);
      this.input.manufacturerUTF8.fill(0); this.input.modelUTF8.fill(0); this.input = undefined;
    }
    this.busy = false; this.transport?.close(); this.transport = undefined;
    this.report.stage = stage; this.report.reason = reason; this.emit();
  }
}
