// Dart data ownership only. The MethodChannel receiver records ACKs; the
// real native discard is covered by the separate 435 cross-language case.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/state/compose_inbox.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

var _serial = 0;

class _Input {
  _Input(this.channel, this.intake, this.directory, this.id, this.calls);
  final MethodChannel channel;
  final ShareIntake intake;
  final Directory directory;
  final String id;
  final List<MethodCall> calls;
  Object? ackResult = true;
  bool throwAck = false;

  Future<IncomingShare> receive(List<File> files, {bool withId = true}) async {
    final received = intake.shares.first;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('share', {
          if (withId) 'shareId': id,
          'files': [
            for (final file in files) {'path': file.path, 'name': file.uri.pathSegments.last},
          ],
        }),
      ),
      (_) {},
    );
    return received;
  }

  List<MethodCall> get acks => calls.where((c) => c.method == 'consumed').toList();
}

Future<_Input> _input({bool ohos = true}) async {
  final serial = ++_serial;
  final channel = MethodChannel('test/share-consumption-$serial');
  final directory = await Directory.systemTemp.createTemp('share-consumption-');
  // The handler is installed before ShareIntake's original ready call.
  late _Input input;
  final calls = <MethodCall>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (call.method == 'ready') return true;
    if (call.method != 'consumed') throw MissingPluginException(call.method);
    if (input.throwAck) throw PlatformException(code: 'retired');
    return input.ackResult;
  });
  input = _Input(
    channel,
    ShareIntake(channel: channel, ohos: ohos),
    directory,
    '11111111-2222-4333-8444-${serial.toString().padLeft(12, '0')}',
    calls,
  );
  addTearDown(() async {
    input.intake.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return input;
}

Future<File> _file(_Input input, String name) => File('${input.directory.path}/$name').writeAsString('%PDF-1.7\n$name');
Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OH files stay owned until the whole actual read completes; ACK is one ID only', () async {
    final input = await _input();
    final a = await _file(input, 'a.pdf'), b = await _file(input, 'b.pdf');
    final share = await input.receive([a, b]);
    final entered = Completer<void>(), resume = Completer<void>();
    final reading = ComposeRequest.fromShare(
      share,
      read: (path) async {
        if (path == b.path) {
          entered.complete();
          await resume.future;
        }
        return File(path).readAsBytes();
      },
    );
    try {
      await entered.future;
      expect(input.acks, isEmpty);
      expect(a.existsSync() && b.existsSync(), isTrue);
    } finally {
      resume.complete();
    }
    final request = await reading;
    await share.consumption!.finish();
    expect(request.attachments.map((a) => a.name), ['a.pdf', 'b.pdf']);
    expect(input.acks, hasLength(1));
    expect(input.acks.single.arguments, {'shareId': input.id});
    expect(a.existsSync() && b.existsSync(), isTrue, reason: 'only the native owner may delete these copies');
  });

  test('Android and old OH input retain original deletion without consumed calls', () async {
    for (final ohos in [false, true]) {
      final input = await _input(ohos: ohos);
      final file = await _file(input, 'old.pdf');
      final share = await input.receive([file], withId: !ohos);
      expect(share.consumption, isNull);
      expect(input.calls.where((c) => c.method == 'ready').single.arguments, isNull);
      final result = await ComposeRequest.fromShare(share);
      expect(result.attachments, hasLength(1));
      expect(file.existsSync(), isFalse);
      expect(input.acks, isEmpty);
    }
  });

  test('OH read failure and budget refusal end consumption without direct file deletion', () async {
    for (final budget in [0, 1000]) {
      final input = await _input();
      final file = await _file(input, 'denied.pdf');
      final share = await input.receive([file]);
      if (budget != 0) await file.delete();
      final result = await ComposeRequest.fromShare(share, maxBytes: budget);
      await share.consumption!.finish();
      expect(result.attachments, isEmpty);
      expect(result.problems, hasLength(1));
      expect(input.acks, hasLength(1));
      if (budget == 0) expect(file.existsSync(), isTrue);
    }
  });

  test('discard is synchronous, idempotent and sends no paths to native', () async {
    final input = await _input();
    final file = await _file(input, 'discard.pdf');
    final share = await input.receive([file]);
    ComposeRequest.discardShare(share);
    ComposeRequest.discardShare(share);
    await share.consumption!.finish();
    expect(input.acks, hasLength(1));
    expect(input.acks.single.arguments, {'shareId': input.id});
    expect(file.existsSync(), isTrue);
  });

  test('failed ACK never retries, replays bytes, or falls back to direct deletion', () async {
    for (final throws in [false, true]) {
      final input = await _input();
      input.ackResult = false;
      input.throwAck = throws;
      final file = await _file(input, 'failed-ack.pdf');
      final share = await input.receive([file]);
      final request = await ComposeRequest.fromShare(share);
      await share.consumption!.finish();
      await share.consumption!.finish();
      expect(request.attachments, hasLength(1));
      expect(input.acks, hasLength(1));
      expect(file.existsSync(), isTrue);
    }
  });

  test('file route captures its owner before awaiting the reader, even during router disposal', () async {
    final input = await _input();
    final file = await _file(input, 'import.dshgo');
    final share = await input.receive([file]);
    final links = StreamController<Uri>();
    final router = LinkRouter(links.stream);
    final entered = Completer<void>(), resume = Completer<void>();
    router.registerFileHandler('dshgo', (_) async {
      entered.complete();
      await resume.future;
      await file.readAsString();
      return true;
    });
    final opening = router.open(file.uri);
    await entered.future;
    router.dispose();
    expect(input.acks, isEmpty);
    resume.complete();
    expect(await opening, isTrue);
    await _tick();
    expect(input.acks, hasLength(1));
    expect(file.existsSync(), isTrue);
    await links.close();
    expect(share.consumption, isNotNull);
  });

  test('unhandled file and disposed pending/held file queues complete only owned paths', () async {
    for (final kind in ['unhandled', 'pending', 'held']) {
      final input = await _input();
      final file = await _file(input, 'queued.dshgo');
      await input.receive([file]);
      if (kind == 'held') {
        final links = AppLinks(channel: MethodChannel('test/held-${input.id}'));
        links.add(file.uri);
        expect(input.acks, isEmpty);
        links.dispose();
      } else {
        final links = StreamController<Uri>(sync: true);
        final router = LinkRouter(links.stream);
        if (kind == 'unhandled') {
          expect(await router.open(file.uri), isFalse);
        } else {
          links.add(file.uri);
          expect(input.acks, isEmpty, reason: 'no UI/handler yet is still waiting, not consumed');
        }
        router.dispose();
        await links.close();
      }
      await _tick();
      expect(input.acks, hasLength(1));
      expect(file.existsSync(), isTrue);
    }
  });

  test('a rejected or throwing owned file handler still completes its read attempt', () async {
    for (final throws in [false, true]) {
      final input = await _input();
      final file = await _file(input, 'bad.dshgo');
      await input.receive([file]);
      final links = StreamController<Uri>();
      final router = LinkRouter(links.stream);
      router.registerFileHandler('dshgo', (_) async {
        if (throws) throw const FormatException('invalid share');
        return false;
      });
      expect(await router.open(file.uri), isFalse);
      await _tick();
      expect(input.acks, hasLength(1));
      expect(file.existsSync(), isTrue);
      router.dispose();
      await links.close();
    }
  });

  test('ordinary user file routing and fromFile never delete or create an ACK', () async {
    final input = await _input();
    final file = await _file(input, 'user.pdf');
    final links = StreamController<Uri>();
    final router = LinkRouter(links.stream);
    router.registerFileFallback((uri) async {
      expect((await ComposeRequest.fromFile(uri.toFilePath())).attachments, hasLength(1));
      return true;
    });
    expect(await router.open(file.uri), isTrue);
    router.dispose();
    await links.close();
    await _tick();
    expect(file.existsSync(), isTrue);
    expect(input.acks, isEmpty);
  });
}
