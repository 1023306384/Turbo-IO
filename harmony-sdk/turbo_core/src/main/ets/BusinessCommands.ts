// Original V1 wire contracts ported to native Harmony. No vendor binaries.
// Each returned JSON document is an explicit command, never model-generated wire.
function finite(n: number, min: number, max: number): void {
  if (!Number.isInteger(n) || n < min || n > max) throw new Error('invalid-value');
}
function quoted(text: string, max: number): string {
  if (!text.trim() || text.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(text)) throw new Error('invalid-text');
  return JSON.stringify(text);
}
export function businessEnvelope(type: number, json: Uint8Array, sequence: number = 0): Uint8Array {
  finite(type, 1, 65535); finite(sequence, 0, 2147483647);
  if (json.length < 2 || json.length > 7500) throw new Error('business-size');
  const out: number[] = [8, 1, 16];
  const variable = (value: number): void => { do { const b = value % 128; value = Math.floor(value / 128); out.push(b | (value ? 128 : 0)); } while (value); };
  variable(type); out.push(26); variable(json.length);
  for (const byte of json) out.push(byte);
  if (sequence) { out.push(40); variable(sequence); }
  return new Uint8Array(out);
}
export function launcherCommand(command: string, value: number, mode: number = 0, data: string = ''): string {
  if (!['request_general_status', 'request_general_settings', 'brightness_change', 'auto_lock_time', 'set_ai_voice_wakeup', 'sync_time'].includes(command)) throw new Error('command-not-supported');
  finite(value, 0, 2147483647); finite(mode, 0, 1);
  return `{"cmd":${JSON.stringify(command)},"payload":{"value":${value},"mode":${mode},"data":${JSON.stringify(data)}}`;
}
export function currentWeather(city: string, temp: number, icon: number, timestamp: number): string {
  quoted(city, 40); finite(temp, -80, 60); finite(icon, 0, 999); finite(timestamp, 1, 2147483647);
  const data = `{"location":${JSON.stringify(city)},"temp":${temp},"icon":${icon}}`;
  return `{"cmd":"current_weather_update","payload":{"value":0,"mode":0,"data":${JSON.stringify(data)},"ts":"${timestamp}"}}`;
}
export function dashboardQuery(): string { return '{"cmd":"dashboard_config","payload":{"version":1,"value":0}}'; }
export const HARMONY_WIDGET_ID: string = 'turbo_ui_hm';
// Short, single Text widget intentionally fits the current MTU512 frame.
// Full A2UI layout needs independently validated large-message transport.
export function installTextWidget(text: string): string {
  const id = HARMONY_WIDGET_ID;
  const component = `{"id":"root","component":"Text","text":${quoted(text, 20)},"variant":"body"}`;
  const extra = `{"widgetId":"${id}","name":"IO","uiContent":{"createSurface":{"surfaceId":"${id}","catalogId":"https://rayneo.com/a2ui/catalogs/glasses-base/v1/catalog.json"},"updateComponents":{"surfaceId":"${id}","components":[${component}]}}}`;
  return `{"cmd":"widget_install","payload":{"data":{"type":"a2ui","id":"${id}","name":"IO","extras":${JSON.stringify(extra)}}}}`;
}
export function removeTextWidget(): string { return `{"cmd":"widget_uninstall","payload":{"data":{"id":"${HARMONY_WIDGET_ID}"}}}`; }
function session(sid: string): string { if (!/^[a-f0-9]{32}$/.test(sid)) throw new Error('invalid-session'); return JSON.stringify(sid); }
export function displayStart(sid: string): string {
  return `{"sid":${session(sid)},"force":false,"scope":"temporary","config":{"font_size":2,"content_width":100,"max_lines":5,"position":"center","is_display":true,"straight_view":"original"}}`;
}
export function displayText(sid: string, text: string): string {
  return `{"sid":${session(sid)},"mode":3,"status":0,"content":{"source_transcript":${quoted(text, 96)}}}`;
}
export function displayStop(sid: string): string { return `{"sid":${session(sid)},"reason_code":10,"text":""}`; }
