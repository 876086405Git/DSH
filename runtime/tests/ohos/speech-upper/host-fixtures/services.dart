// Explicit host-only Flutter MethodChannel boundary; not a Flutter SDK.
import 'dart:async';
export 'dart:typed_data';

class MethodCall {
  const MethodCall(this.method, [this.arguments]);
  final String method;
  final dynamic arguments;
}

class MissingPluginException implements Exception {
  const MissingPluginException([this.message]);
  final String? message;
}

class PlatformException implements Exception {
  const PlatformException({required this.code, this.message, this.details});
  final String code;
  final String? message;
  final dynamic details;
}

typedef HostMethodHandler = FutureOr<Object?> Function(MethodCall call);

class MethodChannel {
  const MethodChannel(this.name);
  final String name;
  static final outbound = <String, HostMethodHandler>{};
  static final inbound = <String, Future<void> Function(MethodCall)>{};

  void setMethodCallHandler(Future<void> Function(MethodCall)? handler) {
    if (handler == null) {
      inbound.remove(name);
    } else {
      inbound[name] = handler;
    }
  }

  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final handler = outbound[name];
    if (handler == null) throw const MissingPluginException();
    return await handler(MethodCall(method, arguments)) as T?;
  }

  Future<Map<K, V>?> invokeMapMethod<K, V>(String method, [Object? arguments]) async =>
      (await invokeMethod<Map>(method, arguments))?.cast<K, V>();
  Future<List<T>?> invokeListMethod<T>(String method, [Object? arguments]) async =>
      (await invokeMethod<List>(method, arguments))?.cast<T>();
}
