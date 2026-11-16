import 'dart:async';

import 'package:dsh_app/clipboard/paste_reader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/paste');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('OH result preserves Chinese, newlines, whitespace and special characters', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {'status': 'text', 'text': '  中文🔐\n+/%  '});
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    final result = await reader.begin().result;
    expect(result.status, PasteStatus.text);
    expect(result.text, '  中文🔐\n+/%  ');
  });

  test('all non-text native outcomes remain distinct and never expose text', () async {
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    for (final status in PasteStatus.values.where((value) => value != PasteStatus.text)) {
      messenger.setMockMethodCallHandler(channel, (call) async => {'status': status.name, 'text': 'must-not-escape'});
      final result = await reader.begin().result;
      expect(result.status, status);
      expect(result.text, isNull);
    }
  });

  test('malformed successful response is a read failure', () async {
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    for (final value in [
      null,
      {'status': 'unknown'},
      {'status': 'text'},
      {'status': 'text', 'text': ''},
      {'status': 'text', 'text': 3},
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => value);
      final result = await reader.begin().result;
      expect(result.status, PasteStatus.readFailed);
      expect(result.text, isNull);
    }
  });

  test('missing native plugin is unavailable, never falls back to unrestricted OH clipboard', () async {
    var ordinary = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      ordinary++;
      return {'text': 'forbidden fallback'};
    });
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    expect((await reader.begin().result).status, PasteStatus.unavailable);
    expect(ordinary, 0);
  });

  test('native error is observable without exposing private exception details', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: '201', message: 'private key'),
    );
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    final result = await reader.begin().result;
    expect(result.status, PasteStatus.readFailed);
    expect(result.text, isNull);
  });

  test('cancel identifies exact request and discards late text', () async {
    final reply = Completer<Object?>();
    final started = Completer<String>();
    final cancelled = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map)['requestId'] as String;
      if (call.method == 'readText') {
        started.complete(id);
        return reply.future;
      }
      cancelled.complete(id);
      return true;
    });
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    final operation = reader.begin();
    final id = await started.future;
    operation.cancel();
    expect((await operation.result).status, PasteStatus.cancelled);
    expect(await cancelled.future, id);
    reply.complete({'status': 'text', 'text': 'late secret'});
    await Future<void>.delayed(Duration.zero);
    expect((await operation.result).text, isNull);
  });

  test('after text delivery explicit cleanup uses same id and preserves result', () async {
    final cancelled = Completer<String>();
    String? originalId;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map)['requestId'] as String;
      if (call.method == 'readText') {
        originalId = id;
        return {'status': 'text', 'text': 'already delivered'};
      }
      cancelled.complete(id);
      return true;
    });
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    final operation = reader.begin();
    expect((await operation.result).text, 'already delivered');
    operation.cancel();
    expect(await cancelled.future, originalId);
    expect((await operation.result).status, PasteStatus.text);
    expect((await operation.result).text, 'already delivered');
  });

  test('dispose cancels active requests and rejects later reads', () async {
    final reply = Completer<Object?>();
    final started = Completer<void>();
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readText') {
        reads++;
        started.complete();
        return reply.future;
      }
      return true;
    });
    final reader = PasteReader(ohos: true);
    final operation = reader.begin();
    await started.future;
    reader.dispose();
    expect((await operation.result).status, PasteStatus.cancelled);
    expect((await reader.begin().result).status, PasteStatus.cancelled);
    expect(reads, 1);
    reply.complete({'status': 'text', 'text': 'late'});
    await Future<void>.delayed(Duration.zero);
  });

  test('a toast the native side put up is carried over, for one voice', () async {
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    messenger.setMockMethodCallHandler(channel, (call) async => {'status': 'denied', 'shown': true});
    expect((await reader.begin().result).shown, isTrue);
    messenger.setMockMethodCallHandler(channel, (call) async => {'status': 'denied'});
    expect((await reader.begin().result).shown, isFalse);
  });

  test('what a failed read says: silent when cancelled or already toasted, otherwise what happened', () {
    String? say(PasteStatus status, {bool shown = false}) => pasteFailureText(PasteResult(status, shown: shown));
    expect(say(PasteStatus.text), isNull);
    expect(say(PasteStatus.cancelled), isNull);
    expect(say(PasteStatus.empty), '剪贴板中没有可粘贴的文本。');
    expect(say(PasteStatus.denied), '系统未授予粘贴权限，请重新点击粘贴按钮。');
    expect(say(PasteStatus.busy), '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。');
    expect(say(PasteStatus.readFailed), '无法读取剪贴板，请重试或手动输入。');
    expect(say(PasteStatus.unavailable), '无法读取剪贴板，请重试或手动输入。');
    for (final status in PasteStatus.values) {
      expect(say(status, shown: true), isNull, reason: status.name);
    }
  });

  test('finish closes the native window behind a delivered text, without reading again', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'readText' ? {'status': 'text', 'text': 'k'} : true;
    });
    final reader = PasteReader(ohos: true);
    addTearDown(reader.dispose);
    expect((await reader.begin().finish()).text, 'k');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['readText', 'cancel']);
  });

  test('Android uses only the original Flutter Clipboard.getData contract', () async {
    var ordinary = 0;
    messenger.setMockMethodCallHandler(channel, (call) async => fail('Android must not open OH UI'));
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      expect(call.method, 'Clipboard.getData');
      expect(call.arguments, Clipboard.kTextPlain);
      ordinary++;
      return {'text': 'Android原文\n'};
    });
    final reader = PasteReader(ohos: false);
    addTearDown(reader.dispose);
    final result = await reader.begin().result;
    expect(result.text, 'Android原文\n');
    expect(ordinary, 1);
  });
}
