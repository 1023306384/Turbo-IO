import { TeleprompterSession } from './TeleprompterSession';
import { probeSession } from './ProbeSession';
export const teleprompter:TeleprompterSession=new TeleprompterSession(
  (business:number,payload:Uint8Array)=>probeSession.auth.sendBusiness(business,payload),
  ()=>probeSession.features.state.connected?probeSession.peerDeviceId:'',
  ()=>probeSession.foreground&&!probeSession.voice.active&&!probeSession.features.displayActive&&!probeSession.recordingOccupied()
);
