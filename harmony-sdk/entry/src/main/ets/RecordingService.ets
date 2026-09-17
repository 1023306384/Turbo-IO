import { RecordingSession } from './RecordingSession';
import { probeSession } from './ProbeSession';
export const recordings:RecordingSession=new RecordingSession(
  (business:number,payload:Uint8Array)=>probeSession.auth.sendBusiness(business,payload),
  ()=>probeSession.features.state.connected?probeSession.peerDeviceId:'',
  ()=>!probeSession.voice.active&&!probeSession.features.displayActive&&!probeSession.prompterOccupied()
);
