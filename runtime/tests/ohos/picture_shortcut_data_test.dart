// Actual production Dart channel consumer. Only the native messenger boundary
// is substituted; no AppGallery/device or UI-enablement claim.
import 'dart:async';

import 'package:dsh_app/state/icon_shortcut_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/picture_shortcut');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    _channel.setMethodCallHandler(null);
  });

  test('pin sends the exact native method, label and PNG byte array', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return {'supported': true, 'requested': true};
    });
    final png = Uint8List.fromList([137, 80, 78, 71]);
    expect(await IconShortcutChannel().pin('用户图片', png), PinRequest.asked);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'pin');
    expect(calls.single.arguments, {'label': '用户图片', 'png': png});
  });

  test('cancel/refusal is failed and missing capability is unsupported', () async {
    final consumer = IconShortcutChannel();
    messenger.setMockMethodCallHandler(_channel, (_) async => {'supported': true, 'requested': false});
    expect(await consumer.pin('DSH Go', Uint8List(1)), PinRequest.failed);
    messenger.setMockMethodCallHandler(_channel, (_) async => {'supported': false, 'requested': false});
    expect(await consumer.pin('DSH Go', Uint8List(1)), PinRequest.unsupported);
  });

  test('null response and platform error never become asked', () async {
    final consumer = IconShortcutChannel();
    messenger.setMockMethodCallHandler(_channel, (_) async => null);
    expect(await consumer.pin('DSH Go', Uint8List(1)), PinRequest.failed);
    messenger.setMockMethodCallHandler(_channel, (_) async => throw PlatformException(code: 'invalid', message: 'no picture'));
    expect(await consumer.pin('DSH Go', Uint8List(1)), PinRequest.failed);
  });

  test('missing native plugin keeps the existing unsupported result', () async {
    expect(await IconShortcutChannel().pin('DSH Go', Uint8List(1)), PinRequest.unsupported);
  });

  test('the actual consumer waits for the OH system-result future', () async {
    final answer = Completer<Map<String, bool>>();
    messenger.setMockMethodCallHandler(_channel, (_) => answer.future);
    var completed = false;
    final pending = IconShortcutChannel().pin('DSH Go', Uint8List(1)).then((value) { completed = true; return value; });
    await pumpEventQueue();
    expect(completed, isFalse);
    answer.complete({'supported': true, 'requested': false});
    expect(await pending, PinRequest.failed);
  });

  test('only the pinned native event reaches the broadcast consumer', () async {
    final consumer = IconShortcutChannel();
    var received = 0;
    final subscription = consumer.pinned.listen((_) { received++; });
    Future<void> emit(String method) async {
      final reply = Completer<void>();
      messenger.handlePlatformMessage(_channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)), (_) => reply.complete());
      await reply.future;
      await pumpEventQueue();
    }
    await emit('requested'); expect(received, 0);
    await emit('pinned'); expect(received, 1);
    await subscription.cancel();
  });
}
