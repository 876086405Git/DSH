export class FixturePlugin {
  sanitize(value: string): string { return value.replace(/[{}\[\]\/]/g, '_'); }
  first?: MethodChannel;
  second?: MethodChannel;
  events?: EventChannel;
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.first = new MethodChannel(binding.getBinaryMessenger(), 'dsh/first');
    this.second = new MethodChannel(binding.getBinaryMessenger(), 'dsh/second');
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/events');
    this.first.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      this.firstCall(call, result);
    }});
    this.second.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      this.secondCall(call, result);
    }});
    this.events.setStreamHandler(this);
  }
  firstCall(call: MethodCall, result: MethodResult): void {
    if (!['read', 'readAll'].includes(call.method)) { result.notImplemented(); return; }
    if (call.method === 'read') result.success(null);
    if (call.method === 'readAll') result.success({});
  }
  secondCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'list': result.success([]); break;
      default: result.notImplemented();
    }
    switch ('mime') {
      case 'unrelatedCase': break;
    }
  }
  neverDispatched(call: MethodCall): void {
    switch (call.method) { case 'unreachable': break; }
  }
  onListen(args: Any, sink: EventSink): void {}
}
