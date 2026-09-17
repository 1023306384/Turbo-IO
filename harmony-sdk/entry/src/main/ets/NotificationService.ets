import { NotificationSession } from './NotificationSession';
import { probeSession } from './ProbeSession';
export const notifications:NotificationSession=new NotificationSession(
  (business:number,payload:Uint8Array)=>probeSession.auth.sendBusiness(business,payload),
  ()=>probeSession.features.state.connected?probeSession.peerDeviceId:'',
  ()=>!probeSession.voice.active&&!probeSession.features.displayActive&&!probeSession.recordingOccupied()&&!probeSession.prompterOccupied()
);
