// A text field's own 粘贴 reads through flutter/platform. On HarmonyOS that one message is
// answered through the system's paste button; everything else, and every other OS, is untouched.

import 'package:dsh_app/clipboard/paste_button_messenger.dart';
import 'package:dsh_app/clipboard/paste_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_paste.dart';

class _Inner implements BinaryMessenger {
  final sent = <(String, ByteData?)>[];
  final handlers = <String>[];

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    sent.add((channel, message));
    return Future.value();
  }

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data, PlatformMessageResponseCallback? callback) async {}

  @override
  void setMessageHandler(String channel, MessageHandler? handler) => handlers.add(channel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = JSONMethodCodec();
  const platform = 'flutter/platform';
  ByteData call(String method, [Object? args]) => codec.encodeMethodCall(MethodCall(method, args));
  Future<Object?> answer(Future<ByteData?>? reply) async => codec.decodeEnvelope((await reply)!);

  test('only HarmonyOS gets it; Android keeps the messenger it had', () {
    final inner = _Inner();
    expect(clipboardMessengerFor('android', inner), same(inner));
    expect(clipboardMessengerFor('linux', inner), same(inner));
    expect(clipboardMessengerFor('ohos', inner), isA<PasteButtonMessenger>());
  });

  test('Clipboard.getData is answered through the paste button, never reaching the embedding', () async {
    final inner = _Inner();
    var reads = 0;
    final messenger = PasteButtonMessenger(
      inner,
      read: () async {
        reads++;
        return const PasteResult(PasteStatus.text, text: '  中文\n');
      },
    );
    expect(await answer(messenger.send(platform, call('Clipboard.getData', 'text/plain'))), {'text': '  中文\n'});
    expect(reads, 1);
    expect(inner.sent, isEmpty);
  });

  for (final status in PasteStatus.values.where((status) => status != PasteStatus.text)) {
    test('${status.name} answers Flutter\'s null, which leaves the field alone', () async {
      final messenger = PasteButtonMessenger(_Inner(), read: () async => PasteResult(status));
      expect(await answer(messenger.send(platform, call('Clipboard.getData', 'text/plain'))), isNull);
    });
  }

  test('everything else goes through untouched, with no read', () {
    final inner = _Inner();
    var reads = 0;
    final messenger = PasteButtonMessenger(
      inner,
      read: () async {
        reads++;
        return const PasteResult(PasteStatus.cancelled);
      },
    );
    final hasStrings = call('Clipboard.hasStrings', 'text/plain');
    final setData = call('Clipboard.setData', {'text': 'x'});
    messenger.send(platform, hasStrings);
    messenger.send(platform, setData);
    messenger.send(platform, null);
    final other = ByteData(4);
    messenger.send('dsh/paste', other);
    messenger.setMessageHandler('x', null);
    expect(inner.sent.map((row) => row.$1), [platform, platform, platform, 'dsh/paste']);
    expect(inner.sent[0].$2, same(hasStrings));
    expect(inner.sent[1].$2, same(setData));
    expect(inner.sent[3].$2, same(other));
    expect(inner.handlers, ['x']);
    expect(reads, 0);
  });

  testWidgets('a field\'s own paste puts the text at the cursor, and leaves it alone when there is none', (
    tester,
  ) async {
    // The framework's real path, answered the way the messenger answers it.
    final messenger = PasteButtonMessenger(
      _Inner(),
      read: () async => const PasteResult(PasteStatus.text, text: 'key'),
    );
    var reply = messenger;
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      platform,
      (message) async => await reply.send(platform, message) ?? codec.encodeSuccessEnvelope(null),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMessageHandler(platform, null));
    final controller = TextEditingController(text: 'a-b');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller, autofocus: true)),
      ),
    );
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    await editable.pasteText(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(controller.text, 'a-keyb');

    reply = PasteButtonMessenger(_Inner(), read: () async => const PasteResult(PasteStatus.cancelled));
    await editable.pasteText(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(controller.text, 'a-keyb');
  });

  testWidgets('the real reader goes to dsh/paste and closes the window behind it', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('k'));
    final messenger = PasteButtonMessenger(_Inner());
    final reply = messenger.send(platform, call('Clipboard.getData', 'text/plain'));
    await tester.pump();
    expect(await answer(reply), {'text': 'k'});
    await tester.pump();
    expect(paste.reads, hasLength(1));
    expect(paste.cancels, contains(paste.reads.single));
  });
}
