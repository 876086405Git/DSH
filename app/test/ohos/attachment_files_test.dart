import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachment_files_ohos.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = OhosAttachmentPicker();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late List<Map<String, Object?>> selected;
  late List<MethodCall> calls;
  Object? pickError;
  Object? releaseError;
  Object? rawReply;

  Future<Map<String, Object?>> file(String name, List<int> bytes, {int? reportedSize}) async {
    final target = File('${root.path}/${selected.length}');
    await target.writeAsBytes(bytes);
    final value = <String, Object?>{
      'name': name,
      'path': target.path,
      'size': reportedSize ?? bytes.length,
      'problem': null,
    };
    selected.add(value);
    return value;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-ohos-attachment-consumer-');
    selected = [];
    calls = [];
    pickError = null;
    releaseError = null;
    rawReply = null;
    messenger.setMockMethodCallHandler(OhosAttachmentFiles.channel, (call) async {
      calls.add(call);
      if (call.method == 'pick') {
        if (pickError != null) throw pickError!;
        return rawReply ?? selected;
      }
      expect(call.method, 'release');
      if (releaseError != null) throw releaseError!;
      // This boundary double owns only its private files. Real ArkTS copying,
      // partial I/O and lifecycle cleanup are covered by the native channel gate.
      for (final child in await root.list().toList()) {
        await child.delete();
      }
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('miguelruivo.flutter.plugins.filepicker'), (_) async {
      fail('OH attachment consumers must not call the URI-returning file_picker fork');
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(OhosAttachmentFiles.channel, null);
    messenger.setMockMethodCallHandler(const MethodChannel('miguelruivo.flutter.plugins.filepicker'), null);
    await root.delete(recursive: true);
  });

  Future<void> released() async {
    expect(calls.where((call) => call.method == 'release').length, 1);
    expect((calls.first.arguments as Map)['owner'], (calls.last.arguments as Map)['owner']);
    expect(await root.list().toList(), isEmpty);
  }

  test('default factory selects only OH; Android and ordinary platform retain Device picker', () {
    expect(createAttachmentPicker(operatingSystem: 'ohos'), isA<OhosAttachmentPicker>());
    for (final platform in ['android', 'ios', 'linux', 'web']) {
      expect(createAttachmentPicker(operatingSystem: platform).runtimeType, DeviceAttachmentPicker);
    }
  });

  test('chat reads private paths, preserves same display names and actual Unicode bytes, then releases', () async {
    await file('中文.txt', utf8.encode('第一份'));
    await file('中文.txt', utf8.encode('second'));
    final result = await picker.pickFiles();
    expect(result.problem, isNull);
    expect(result.attachments.map((value) => value.name), ['中文.txt', '中文.txt']);
    expect(utf8.decode(result.attachments.first.bytes), '第一份');
    expect(utf8.decode(result.attachments.last.bytes), 'second');
    final args = calls.first.arguments as Map;
    expect(args['maxFileBytes'], 200 * 1024 * 1024);
    expect(args['maxTotalBytes'], 400 * 1024 * 1024);
    expect(args['maxImageBytes'], 20 * 1024 * 1024);
    expect(args['limit'], 9);
    await released();
  });

  test('native per-item rejections keep the first problem and later valid files', () async {
    selected.add({'name': 'too-large', 'path': null, 'size': 0, 'problem': 'file_too_large'});
    await file('good', [1, 2, 3]);
    selected.add({'name': 'unreadable', 'path': null, 'size': 0, 'problem': 'unreadable'});
    final result = await picker.pickFiles();
    expect(result.problem, appL10n.stateAttachmentFileLimit('too-large'));
    expect(result.attachments.single.bytes, [1, 2, 3]);
    await released();
  });

  test('held tray bytes and smaller attachment room are forwarded and enforced again on the stream', () async {
    await file('over-total', [1, 2, 3, 4], reportedSize: 0);
    await file('fits', [1, 2, 3]);
    final result = await picker.pickFiles(limit: 2, heldBytes: maxMessageBytes - 3);
    expect((calls.first.arguments as Map)['maxTotalBytes'], 3);
    expect((calls.first.arguments as Map)['limit'], 2);
    expect(result.problem, appL10n.stateAttachmentTotalLimit);
    expect(result.attachments.single.name, 'fits');
    await released();
  });

  test('metadata rejects oversized file, real image prefix wins over suffix, later ordinary file remains', () async {
    await file('huge', [], reportedSize: maxFileBytes + 1);
    await file('image.txt', [137, 80, 78, 71, 13, 10, 26, 10], reportedSize: maxImageBytes + 1);
    await file('ordinary.png', [65, 66, 67]);
    final result = await picker.pickFiles();
    expect(result.problem, appL10n.stateAttachmentFileLimit('huge'));
    expect(result.attachments.single.name, 'ordinary.png');
    expect(result.attachments.single.isImage, isFalse);
    await released();
  });

  test('files not consumed after the smaller count limit are still released', () async {
    await file('first', [1]);
    await file('unused', [2]);
    final result = await picker.pickFiles(limit: 1);
    expect(result.attachments.single.name, 'first');
    expect(result.problem, appL10n.chatAttachmentLimit(maxAttachments));
    await released();
  });

  test('cancelled selection returns no files/text and releases the request owner', () async {
    expect((await picker.pickFiles()).attachments, isEmpty);
    await released();
    calls.clear();
    expect(await picker.pickTextFile(), isNull);
    await released();
  });

  test('text uses the existing 64 KiB budget, preserves Unicode and malformed UTF8 replacement', () async {
    await file('key', [...utf8.encode('中文\n'), 255]);
    expect(await picker.pickTextFile(), '中文\n�');
    expect((calls.first.arguments as Map)['maxFileBytes'], 64 * 1024);
    expect((calls.first.arguments as Map)['maxTotalBytes'], 64 * 1024);
    expect((calls.first.arguments as Map)['maxImageBytes'], 0);
    expect((calls.first.arguments as Map)['allowEmpty'], isTrue);
    await released();
  });

  test('text custom maxBytes is forwarded and stale cache metadata cannot bypass it', () async {
    await file('key', [65, 66, 67], reportedSize: 0);
    await expectLater(picker.pickTextFile(maxBytes: 2), throwsFormatException);
    expect((calls.first.arguments as Map)['maxFileBytes'], 2);
    expect((calls.first.arguments as Map)['maxTotalBytes'], 2);
    await released();
  });

  test('native text overflow maps to the existing FormatException and empty text remains valid', () async {
    selected.add({'name': 'key', 'path': null, 'size': 0, 'problem': 'file_too_large'});
    await expectLater(
      picker.pickTextFile(),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', appL10n.statePrivateKeyTooLarge)),
    );
    await released();
    selected.clear();
    calls.clear();
    await file('empty', []);
    expect(await picker.pickTextFile(), '');
    await released();
  });

  test('read errors never return a partial key and the batch is released', () async {
    selected.add({'name': 'key', 'path': '${root.path}/missing', 'size': 0, 'problem': null});
    await expectLater(picker.pickTextFile(), throwsA(isA<FileSystemException>()));
    await released();
  });

  test('malformed protocol and picker failure both release, without falling back to fork URIs', () async {
    await file('unconsumed', [1]);
    rawReply = [42];
    await expectLater(picker.pickFiles(), throwsFormatException);
    await released();
    calls.clear();
    rawReply = null;
    pickError = PlatformException(code: 'ohos_attachment_busy');
    await expectLater(
      picker.pickFiles(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'ohos_attachment_busy')),
    );
    await released();
  });
  test('release failure preserves successful attachment bytes and text', () async {
    releaseError = PlatformException(code: 'ohos_attachment_cleanup');
    await file('good.txt', utf8.encode('中文'));
    final files = await picker.pickFiles();
    expect(utf8.decode(files.attachments.single.bytes), '中文');
    expect(files.problem, isNull);
    expect(await picker.pickTextFile(), '中文');
    expect(await root.list().toList(), isNotEmpty);
    expect(calls.where((call) => call.method == 'release').length, 2);
  });

  test('release failure preserves read, protocol and original picker errors', () async {
    releaseError = PlatformException(code: 'ohos_attachment_cleanup');
    selected.add({'name': 'key', 'path': '${root.path}/missing', 'size': 0, 'problem': null});
    await expectLater(picker.pickTextFile(), throwsA(isA<FileSystemException>()));
    rawReply = [42];
    await expectLater(picker.pickFiles(), throwsFormatException);
    rawReply = null;
    pickError = PlatformException(code: 'ohos_attachment_io');
    await expectLater(picker.pickFiles(), throwsA(isA<PlatformException>()
        .having((error) => error.code, 'code', 'ohos_attachment_io')));
    expect(calls.where((call) => call.method == 'release').length, 3);
  });

}
