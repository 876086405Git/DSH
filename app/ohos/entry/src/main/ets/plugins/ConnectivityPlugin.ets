// 未编译、未在真机核实。公开 SDK / oh-flutter 签名见 core-channels.md。
import connection from '@ohos.net.connection';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import {
  Any, EventChannel, EventSink, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult, StreamHandler
} from '@ohos/flutter_ohos';

export default class ConnectivityPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private methods?: MethodChannel;
  private events?: EventChannel;
  private sink?: EventSink;
  private observer?: connection.NetConnection;
  private registered: boolean = false;
  private generation: number = 0;
  private query: number = 0;
  private last: string = '';

  getUniqueClassName(): string { return 'DshConnectivityPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger = binding.getBinaryMessenger();
    this.methods = new MethodChannel(messenger, 'dev.fluttercommunity.plus/connectivity');
    this.events = new EventChannel(messenger, 'dev.fluttercommunity.plus/connectivity_status');
    this.methods.setMethodCallHandler(this);
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.onCancel(null);
    this.methods?.setMethodCallHandler(null);
    binding.getBinaryMessenger().setMessageHandler('dev.fluttercommunity.plus/connectivity_status', null);
    this.methods = undefined;
    this.events = undefined;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'check') { result.notImplemented(); return; }
    this.read().then((states: string[]) => result.success(states)).catch((_error: BusinessError) => {
      result.error('ohos_network_query', '无法查询系统网络状态，请重试。', null);
    });
  }

  onListen(_arguments: Any, events: EventSink): void {
    this.onCancel(null);
    this.sink = events;
    this.last = '';
    const generation = this.generation;
    try {
      const observer = connection.createNetConnection();
      this.observer = observer;
      observer.on('netAvailable', () => this.refresh(generation));
      observer.on('netCapabilitiesChange', () => this.refresh(generation));
      observer.on('netLost', () => this.refresh(generation));
      observer.on('netUnavailable', () => this.refresh(generation));
      observer.register((error: BusinessError) => {
        if (error) {
          if (this.observer === observer) {
            this.observer = undefined;
            events.error('ohos_network_watch', '无法订阅系统网络变化，请重试。', null);
          }
          return;
        }
        if (this.observer !== observer) {
          this.unregister(observer);
          return;
        }
        this.registered = true;
        this.refresh(generation);
      });
    } catch (_error) {
      this.observer = undefined;
      events.error('ohos_network_watch', '无法订阅系统网络变化，请重试。', null);
    }
  }

  onCancel(_arguments: Any): void {
    this.generation++;
    this.sink = undefined;
    const observer = this.observer;
    this.observer = undefined;
    const registered = this.registered;
    this.registered = false;
    if (registered && observer) this.unregister(observer);
  }

  private unregister(observer: connection.NetConnection): void {
    try {
      observer.unregister((error: BusinessError) => {
        if (error) hilog.warn(0xD003F00, 'DshConnectivity', '网络监听注销失败');
      });
    } catch (_error) {
      hilog.warn(0xD003F00, 'DshConnectivity', '网络监听注销失败');
    }
  }

  private async refresh(generation: number): Promise<void> {
    if (generation !== this.generation || !this.sink) return;
    const query = ++this.query;
    try {
      const states = await this.read();
      if (generation !== this.generation || query !== this.query || !this.sink) return;
      const key = states.join(',');
      if (key !== this.last) { this.last = key; this.sink.success(states); }
    } catch (_error) {
      if (generation === this.generation && query === this.query) {
        this.sink?.error('ohos_network_query', '无法查询系统网络状态，请重试。', null);
      }
    }
  }

  private async read(): Promise<string[]> {
    const net = await connection.getDefaultNet();
    if (net.netId === 0) return ['none'];
    const capabilities = await connection.getNetCapabilities(net);
    const states: string[] = [];
    for (const bearer of capabilities.bearerTypes) {
      let name: string;
      switch (bearer) {
        case connection.NetBearType.BEARER_WIFI: name = 'wifi'; break;
        case connection.NetBearType.BEARER_CELLULAR: name = 'mobile'; break;
        case connection.NetBearType.BEARER_ETHERNET: name = 'ethernet'; break;
        case connection.NetBearType.BEARER_VPN: name = 'vpn'; break;
        case connection.NetBearType.BEARER_BLUETOOTH: name = 'bluetooth'; break;
        default: name = 'other'; break;
      }
      if (!states.includes(name)) states.push(name);
    }
    return states.length === 0 ? ['other'] : states.sort();
  }
}
