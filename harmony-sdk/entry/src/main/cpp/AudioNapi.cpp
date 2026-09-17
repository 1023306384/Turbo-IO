#include "napi/native_api.h"
#include "opus.h"
#include "RecordingDecode.h"
#include <cstdint>
#include <cstring>
#include <mutex>
static OpusDecoder *decoder = nullptr;
static std::mutex lock;
static OpusDecoder *recordingDecoder = nullptr;
static napi_value Fail(napi_env env, const char *message) { napi_throw_error(env, nullptr, message); return nullptr; }
static napi_value Reset(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> guard(lock);
  if (decoder) opus_decoder_destroy(decoder);
  int error = 0; decoder = opus_decoder_create(16000, 1, &error);
  if (!decoder || error != OPUS_OK) return Fail(env, "opus-init-failed");
  napi_value result; napi_get_undefined(env,&result); return result;
}
static napi_value Close(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> guard(lock);
  if (decoder) opus_decoder_destroy(decoder); decoder=nullptr;
  napi_value result; napi_get_undefined(env,&result); return result;
}
static napi_value Decode(napi_env env, napi_callback_info info) {
  size_t count=1; napi_value args[1];
  if(napi_get_cb_info(env,info,&count,args,nullptr,nullptr)!=napi_ok||count!=1)return Fail(env,"opus-input");
  bool array=false; void *bytes=nullptr; size_t length=0;
  if(napi_is_arraybuffer(env,args[0],&array)!=napi_ok||!array||napi_get_arraybuffer_info(env,args[0],&bytes,&length)!=napi_ok||length==0||length>4096)return Fail(env,"opus-input");
  std::lock_guard<std::mutex> guard(lock);
  if(!decoder)return Fail(env,"opus-not-ready");
  int expected=opus_packet_get_nb_samples(static_cast<unsigned char*>(bytes),static_cast<opus_int32>(length),16000);
  if(expected<=0||expected>1920||expected%160)return Fail(env,"opus-frame-size");
  opus_int16 pcm[1920]={0};
  int samples=opus_decode(decoder,static_cast<unsigned char*>(bytes),static_cast<opus_int32>(length),pcm,1920,0);
  if(samples!=expected){std::memset(pcm,0,sizeof(pcm));return Fail(env,"opus-decode-failed");}
  void *out=nullptr;napi_value result;
  if(napi_create_arraybuffer(env,static_cast<size_t>(samples)*2,&out,&result)!=napi_ok){std::memset(pcm,0,sizeof(pcm));return Fail(env,"pcm-allocation-failed");}
  auto dst=static_cast<uint8_t*>(out);
  for(int i=0;i<samples;i++){dst[2*i]=static_cast<uint16_t>(pcm[i])&255;dst[2*i+1]=(static_cast<uint16_t>(pcm[i])>>8)&255;}
  std::memset(pcm,0,sizeof(pcm));return result;
}
// Recording uses a separate 16 kHz stereo decoder. Never reuse/reset live ASR's
// mono state. 240-byte packet size is the inspected V1 recording profile only.
static napi_value RecordingReset(napi_env env,napi_callback_info){
  std::lock_guard<std::mutex> guard(lock);
  if(recordingDecoder)opus_decoder_destroy(recordingDecoder);
  int error=0;recordingDecoder=opus_decoder_create(16000,2,&error);
  if(!recordingDecoder||error!=OPUS_OK)return Fail(env,"recording-init-failed");
  napi_value result;napi_get_undefined(env,&result);return result;
}
static napi_value RecordingClose(napi_env env,napi_callback_info){
  std::lock_guard<std::mutex> guard(lock);if(recordingDecoder)opus_decoder_destroy(recordingDecoder);recordingDecoder=nullptr;
  napi_value result;napi_get_undefined(env,&result);return result;
}
static napi_value RecordingDecode(napi_env env,napi_callback_info info){
  size_t count=1;napi_value args[1];bool array=false;void* bytes=nullptr;size_t length=0;
  if(napi_get_cb_info(env,info,&count,args,nullptr,nullptr)!=napi_ok||count!=1||
     napi_is_arraybuffer(env,args[0],&array)!=napi_ok||!array||
     napi_get_arraybuffer_info(env,args[0],&bytes,&length)!=napi_ok||length!=240)return Fail(env,"recording-packet-size");
  std::lock_guard<std::mutex> guard(lock);if(!recordingDecoder)return Fail(env,"recording-not-ready");
  uint8_t pcm[1280]={0};
  if(!DecodeRecordingPacket(recordingDecoder,static_cast<const uint8_t*>(bytes),length,pcm,sizeof(pcm)))return Fail(env,"recording-decode-failed");
  void* output=nullptr;napi_value result;
  if(napi_create_arraybuffer(env,1280,&output,&result)!=napi_ok){std::memset(pcm,0,sizeof(pcm));return Fail(env,"recording-allocation-failed");}
  std::memcpy(output,pcm,sizeof(pcm));
  std::memset(pcm,0,sizeof(pcm));return result;
}
static napi_value Init(napi_env env,napi_value exports){
  napi_property_descriptor props[]={ {"reset",nullptr,Reset,nullptr,nullptr,nullptr,napi_default,nullptr}, {"decode",nullptr,Decode,nullptr,nullptr,nullptr,napi_default,nullptr}, {"close",nullptr,Close,nullptr,nullptr,nullptr,napi_default,nullptr} };
  napi_define_properties(env,exports,3,props);
  napi_property_descriptor recording[]={ {"recordingReset",nullptr,RecordingReset,nullptr,nullptr,nullptr,napi_default,nullptr}, {"recordingDecode",nullptr,RecordingDecode,nullptr,nullptr,nullptr,napi_default,nullptr}, {"recordingClose",nullptr,RecordingClose,nullptr,nullptr,nullptr,napi_default,nullptr} };
  napi_define_properties(env,exports,3,recording);return exports;
}
static napi_module module={1,0,nullptr,Init,"turbo_audio",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterTurboAudio(){napi_module_register(&module);}
