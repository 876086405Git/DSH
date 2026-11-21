import 'dart:async';

import 'package:dsh_app/companion/companion_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/companion-memory-widget');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('a queued old line cannot follow a newer unconditional clear', () async {
    final calls = <Map<Object?, Object?>>[];
    final first = Completer<bool>();
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(Map<Object?, Object?>.from(call.arguments as Map));
      if (calls.length == 1) {
        started.complete();
        return first.future;
      }
      return true;
    });
    final widget = CompanionWidget(channel);
    final sent = widget.update({'memoryArchiveId': 'phone', 'memoryControlRevision': 1, 'line': '旧回答', 'saidAt': 10});
    await started.future;
    final queued = widget.update({'memoryArchiveId': 'phone', 'memoryControlRevision': 1, 'line': '旧回包', 'saidAt': 11});
    final clear = widget.clearMemoryLine(archiveId: 'phone', controlRevision: 2);
    first.complete(true);
    expect(await sent, isTrue);
    expect(await queued, isFalse);
    expect(await clear, isTrue);
    expect(calls, hasLength(2));
    expect(calls.last, {'memoryArchiveId': 'phone', 'memoryControlRevision': 2, 'line': null, 'saidAt': null});
    expect(await widget.update({'memoryArchiveId': 'phone', 'memoryControlRevision': 1, 'line': '又晚到'}), isFalse);
    expect(await widget.update({'line': '旧版本无修订'}), isFalse);
    expect(calls, hasLength(2));
  });

  test('missing, older and failed native handlers never acknowledge deletion', () async {
    final widget = CompanionWidget(channel);
    expect(await widget.clearMemoryLine(archiveId: 'phone', controlRevision: 1), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await widget.clearMemoryLine(archiveId: 'phone', controlRevision: 1), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'disk-full'));
    expect(await widget.clearMemoryLine(archiveId: 'phone', controlRevision: 1), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    expect(await widget.clearMemoryLine(archiveId: 'phone', controlRevision: 1), isTrue);
  });
}
