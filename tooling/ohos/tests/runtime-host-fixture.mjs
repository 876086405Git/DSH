export const native = {
  state: { phase: 'idle', consumed: false, baseUrl: null, token: null, exitCode: null, errorCode: null, errorMessage: null },
  events: [], starts: [], stops: 0, afterDrain: null, lifecycleWrites: [],
  reset() {
    this.state = { phase: 'idle', consumed: false, baseUrl: null, token: null, exitCode: null, errorCode: null, errorMessage: null };
    this.events = []; this.starts = []; this.stops = 0; this.afterDrain = null; this.lifecycleWrites = [];
    Object.assign(hostLifecycle,{ownerGeneration:0,revision:1,available:0,foreground:0,phase:0});
  },
};
export function getState() { return { ...native.state }; }
export function drainEvents() {
  const batch = native.events.splice(0);
  native.afterDrain?.();
  return batch;
}
export function start(options) {
  if (native.state.consumed) throw new Error('one shot');
  native.starts.push(options);
  native.state.phase = 'starting'; native.state.consumed = true;
}
export function stop() { native.stops++; native.state.phase = 'stopping'; }

export const connection = {
  NetCap: { NET_CAPABILITY_NOT_METERED: 11 },
  async getDefaultNet() { return { netId: 1 }; },
  async getNetCapabilities() { return { networkCap: [11] }; },
};

export class MethodCall {
  constructor(method, args) { this.method = method; this.args = args; }
  argument(key) { return this.args?.get(key) ?? null; }
}
export class MethodChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; }
  setMethodCallHandler(handler) { this.handler = handler; }
}
export class EventChannel {
  constructor(messenger, name) { this.messenger = messenger; this.name = name; }
  setStreamHandler(handler) { this.handler = handler; }
}

// Actual Ark dynamic import exposes Native exports under default.
const hostLifecycle={version:1,engineGeneration:1,ownerGeneration:0,revision:1,grantGeneration:0,nowMs:10000,deadlineMs:0,drainAtMs:0,phase:0,available:0,foreground:0,clockFailed:0};
export function lifecycleSnapshot(){return {...hostLifecycle};}
export function lifecycleUpdate(operation,owner,grant,value){
  native.lifecycleWrites.push({operation,owner,grant,value});
  if(operation==='owner'){hostLifecycle.ownerGeneration++;hostLifecycle.foreground=value;hostLifecycle.available=1;hostLifecycle.revision++;return hostLifecycle.ownerGeneration;}
  if(owner!==hostLifecycle.ownerGeneration)return 0;
  if(operation==='foreground'){hostLifecycle.foreground=value;hostLifecycle.phase=4;hostLifecycle.revision++;return 1;}
  if(operation==='retire'){hostLifecycle.available=0;hostLifecycle.phase=4;hostLifecycle.revision++;return 1;}
  if(operation==='release'){hostLifecycle.phase=4;hostLifecycle.revision++;return 1;}
  return 0;
}
export const backgroundTaskManager={requestSuspendDelay(){throw Error('runtime fixture grants no OS task');},cancelSuspendDelay(){}};
export default { start, stop, getState, drainEvents, lifecycleSnapshot, lifecycleUpdate };

export let nativeModuleLoads = 0;
export function markNativeLoad() { nativeModuleLoads++; }

export const nativeModuleControl = { beforeLoad: null };

// The runtime-channel regression retains the actual lifecycle model. Its
// platform HTTP/permission boundary records calls without contacting a server;
// lifecycle-host-http.test.mjs separately exercises the real authenticated route.
export const lifecycleControl = { sends: [], queries: 0, cancels: 0, failure: null };
export class OhosLifecycleTransport {
  async send(baseUrl, token, observation) {
    lifecycleControl.sends.push({ baseUrl, token, observation });
    if (lifecycleControl.failure) throw lifecycleControl.failure;
    return {nativeHost:lifecycleSnapshot(),busy:false,manualPaused:false,confirmedPause:hostLifecycle.foreground===0};
  }
  cancel() { lifecycleControl.cancels++; }
}
// Unrelated channel regressions do not start Linux. Dedicated Linux transport
// and controller-barrier tests exercise the new shutdown protocol separately.
export class LinuxControl {
  async shutdown() {}
  getStatus() { throw Error('Linux status outside runtime-channel fixture'); }
  setEnabled() { throw Error('Linux enable outside runtime-channel fixture'); }
  runPrivateGuest() { throw Error('Linux execution outside runtime-channel fixture'); }
}
export function agentReminderAccess() { return lifecycleControl.reminders ?? 'denied'; }
export function backgroundComputePermission() { lifecycleControl.queries++; return lifecycleControl.permission ?? 'denied'; }
export class FlutterAbility {
  superCalls = [];
  onForeground() { this.superCalls.push('foreground'); }
  onBackground() { this.superCalls.push('background'); }
  onDestroy() { this.superCalls.push('destroy'); }
  configureFlutterEngine() {}
}

// Runtime channel's unrelated methods must never invoke phone SDK work. The
// complete production phone chain has its own phone-bridge/effects test files.
export const phoneCrypto = {createRandom(){throw Error('phone crypto outside runtime-channel fixture');}};
export class PhoneEffectDenied extends Error {}
export class PhoneEffects { execute(){throw Error('phone effect outside runtime-channel fixture');} }
