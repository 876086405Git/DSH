import 'dart:async';

import 'package:dsh_app/links/launcher_entries.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Siri entries arriving inside ready wait for the Dart listener exactly once', () async {
    const channel = MethodChannel('dsh/shortcuts');
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final ready = Completer<void>();
    final calls = <String>[];
    const text = '测试 DSH\nsecond line';

    Future<void> push(Map<String, Object?> args) async {
      final answer = Completer<void>();
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall('entry', args)),
        (reply) {
          expect(reply, isNotNull);
          expect(codec.decodeEnvelope(reply!), isNull);
          answer.complete();
        },
      );
      await answer.future;
    }

    // This supplies platform messages, not a replacement for Dart's decoder or queue.
    // It does not execute the Swift plugin's held queue or Siri system dispatch.
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'ready');
      await push({'kind': 'new', 'text': text});
      await push({'kind': 'new', 'text': text});
      await push({'kind': 'voice'});
      await push({'kind': 'new'});
      ready.complete();
      return true;
    });
    final bridge = LauncherBridge();
    addTearDown(() {
      bridge.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await ready.future;
    expect(calls, ['ready']);
    final received = <LauncherEntry>[];
    final first = bridge.entries.listen(received.add);
    await Future<void>.delayed(Duration.zero);
    expect(received.cast<NewChatEntry>().map((entry) => (entry.text, entry.voice)), [
      (text, false), (text, false), ('', true), ('', false),
    ]);
    await first.cancel();

    received.clear();
    final second = bridge.entries.listen(received.add);
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty, reason: 'drained cold-start entries must not replay');
    await push({'kind': 'new', 'text': 'live'});
    await Future<void>.delayed(Duration.zero);
    expect(received.single, isA<NewChatEntry>().having((entry) => entry.text, 'text', 'live'));
    expect(calls, ['ready']);
    await second.cancel();
  });
}
