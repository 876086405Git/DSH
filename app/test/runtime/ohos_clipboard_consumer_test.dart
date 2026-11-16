import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wirePath = Platform.environment['OHOS_CLIPBOARD_WIRE'];
  final records = wirePath == null
      ? <Map<String, dynamic>>[
          for (final row in [
            [
              'channel-has-text',
              'Clipboard.hasStrings',
              {'value': true},
            ],
            [
              'channel-has-no-text',
              'Clipboard.hasStrings',
              {'value': false},
            ],
            [
              'channel-query-rejected',
              'Clipboard.hasStrings',
              {'value': false},
            ],
            [
              'channel-read-plain',
              'Clipboard.getData',
              {'text': '粘贴💡'},
            ],
            [
              'channel-read-html',
              'Clipboard.getData',
              {'text': 'fixture-html'},
            ],
            ['channel-read-denied', 'Clipboard.getData', null],
            ['channel-read-invalid', 'Clipboard.getData', null],
          ])
            {
              'name': row[0],
              'method': row[1],
              'replies': [
                {'value': row[2]},
              ],
            },
        ]
      : ((jsonDecode(File(wirePath).readAsStringSync()) as Map<String, dynamic>)['observations'] as List)
            .cast<Map<String, dynamic>>()
            .where((row) => row.containsKey('method'))
            .toList();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, dynamic> record(String name) => records.singleWhere((row) => row['name'] == name);
  Object? reply(Map<String, dynamic> row) {
    final replies = row['replies'] as List;
    expect(replies, hasLength(1), reason: 'native method must settle exactly once');
    final response = replies.single as Map<String, dynamic>;
    if (response['error'] case final List error) {
      throw PlatformException(code: error[0] as String, message: error[1] as String?, details: error[2]);
    }
    return response['value'];
  }

  void install(Map<String, dynamic> row) {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == row['method']) return reply(row);
      if (call.method == 'Clipboard.hasStrings') return reply(record('channel-has-text'));
      return null;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

  for (final name in ['channel-has-text', 'channel-has-no-text', 'channel-query-rejected']) {
    test('actual ClipboardStatusNotifier settles $name', () async {
      final row = record(name);
      install(row);
      final notifier = ClipboardStatusNotifier();
      addTearDown(notifier.dispose);
      await notifier.update();
      expect(notifier.value, name == 'channel-has-text' ? ClipboardStatus.pasteable : ClipboardStatus.notPasteable);
    });
  }

  for (final row in records.where((row) => row['method'] == 'Clipboard.getData')) {
    test('actual Clipboard.getData consumes ${row['name']}', () async {
      install(row);
      final response = (row['replies'] as List).single as Map<String, dynamic>;
      if (response.containsKey('error')) {
        await expectLater(Clipboard.getData(Clipboard.kTextPlain), throwsA(isA<PlatformException>()));
      } else {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        expect(data?.text, (response['value'] as Map<String, dynamic>?)?['text']);
      }
    });
  }

  for (final name in ['channel-read-plain', 'channel-read-denied', 'channel-read-invalid']) {
    testWidgets('actual ApiKeyPage paste button consumes $name', (tester) async {
      usePhoneSurface(tester);
      install(record(name));
      await tester.pumpWidget(
        goldenApp(
          home: const ApiKeyPage(onboarding: false),
          brightness: Brightness.light,
          overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('粘贴'));
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
      expect(controller.text, name == 'channel-read-plain' ? '粘贴💡' : '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('actual EditableText preserves or replaces selection for $name', (tester) async {
      install(record(name));
      final controller = TextEditingController.fromValue(
        const TextEditingValue(text: 'left SELECT right', selection: TextSelection(baseOffset: 5, extentOffset: 11)),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: controller)),
        ),
      );
      final before = controller.value;
      final editable = tester.state<EditableTextState>(find.byType(EditableText));
      await editable.pasteText(SelectionChangedCause.toolbar);
      await tester.pump();
      if (name == 'channel-read-plain') {
        expect(controller.text, 'left 粘贴💡 right');
        expect(controller.selection, const TextSelection.collapsed(offset: 9));
      } else {
        expect(controller.value, before);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
