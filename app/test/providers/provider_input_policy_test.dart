// Actual form -> EditableText -> TextInput channel policy. No device IME is
// instantiated; the emitted configurations are also fed to the pinned Android
// embedding contract probe in the G53 evidence bundle.
import 'dart:convert';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_app/ui/providers/provider_widgets.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../clipboard/fake_paste.dart';
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(FormFieldBlock)),
  matching: find.byType(TextField),
);

class _EditLauncher extends StatelessWidget {
  const _EditLauncher();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () {
        Navigator.of(context).push<String>(
          MaterialPageRoute<String>(builder: (_) => ProviderFormPage(existing: CustomProvider.fromProfile(gateway))),
        );
      },
      child: const Text('open form'),
    ),
  );
}

Future<void> _open(WidgetTester tester, FakeProviderBackend backend, {bool edit = false, String? os}) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 2800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: edit ? const _EditLauncher() : const ProvidersPage(),
      brightness: Brightness.light,
      overrides: [if (os != null) operatingSystemProvider.overrideWithValue(os), ...providerOverrides(backend)],
    ),
  );
  await settle(tester);
  await tester.tap(find.text(edit ? 'open form' : '添加渠道'));
  await settle(tester);
  expect(find.byType(ProviderFormPage), findsOneWidget);
}

Future<Map<String, dynamic>> _capture(WidgetTester tester, String field, String label) async {
  expect(defaultTargetPlatform, TargetPlatform.android);
  final target = _field(field);
  await tester.tap(target);
  await tester.pump();
  final widget = tester.widget<TextField>(target);
  final editable = tester.state<EditableTextState>(find.descendant(of: target, matching: find.byType(EditableText)));
  final effective = editable.textInputConfiguration.toJson();
  final wire = Map<String, dynamic>.from(tester.testTextInput.setClientArgs!);
  for (final key in ['inputType', 'obscureText', 'autocorrect', 'enableSuggestions', 'enableIMEPersonalizedLearning']) {
    expect(wire[key], effective[key], reason: 'The platform receives the actual EditableText $key');
  }
  expect(wire['inputType'], widget.keyboardType.toJson());
  expect(wire['obscureText'], widget.obscureText);
  expect(wire['autocorrect'], widget.autocorrect);
  expect(wire['enableSuggestions'], widget.enableSuggestions);
  expect(wire['enableIMEPersonalizedLearning'], widget.enableIMEPersonalizedLearning);
  debugPrint('G53 ${jsonEncode({'case': label, 'platformConfig': wire})}');
  return wire;
}

void _ordinaryUrl(Map<String, dynamic> wire) {
  expect(wire['inputType']['name'], 'TextInputType.url');
  expect(wire['obscureText'], isFalse);
  expect(wire['autocorrect'], isFalse);
  expect(wire['enableSuggestions'], isTrue, reason: 'Android must retain URI rather than add a password variation');
  expect(wire['enableIMEPersonalizedLearning'], isTrue);
  expect(wire['autofill']['hints'], isEmpty);
}

void _secretKey(Map<String, dynamic> wire, {required bool hidden}) {
  expect(wire['inputType']['name'], 'TextInputType.visiblePassword');
  expect(wire['obscureText'], hidden);
  expect(wire['autocorrect'], isFalse);
  expect(wire['enableSuggestions'], isFalse);
  expect(wire['enableIMEPersonalizedLearning'], isFalse);
  expect(wire['autofill']['hints'], isEmpty);
}

void _clipboard(WidgetTester tester, String text, VoidCallback read) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') {
      read();
      return {'text': text};
    }
    if (call.method == 'Clipboard.hasStrings') return {'value': true};
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

void main() {
  for (final edit in [false, true]) {
    for (final protocol in ['OpenAI', 'Anthropic', 'Responses']) {
      testWidgets('${edit ? 'edit' : 'add'} $protocol URL is ordinary while hidden and shown keys stay secret', (
        tester,
      ) async {
        final backend = edit ? sampleBackend() : FakeProviderBackend();
        await _open(tester, backend, edit: edit);
        await tester.tap(find.text(protocol));
        await settle(tester);
        final label = 'provider-${edit ? 'edit' : 'add'}-${protocol.toLowerCase()}';
        _ordinaryUrl(await _capture(tester, 'Base URL', '$label-url'));
        const url = 'https://g53.example.invalid:8443/team/path/v1';
        await tester.enterText(_field('Base URL'), url);
        await tester.pump();
        expect(tester.widget<TextField>(_field('Base URL')).controller!.text, url);
        expect(tester.widget<TextField>(_field('API Key')).controller!.text, isEmpty);
        _secretKey(await _capture(tester, 'API Key', '$label-key-hidden'), hidden: true);
        tester.testTextInput.log.clear();
        await tester.tap(find.byTooltip('显示'));
        await tester.pump();
        _secretKey(await _capture(tester, 'API Key', '$label-key-shown'), hidden: false);
        expect(tester.testTextInput.log.any((call) => call.method == 'TextInput.updateConfig'), isTrue);
        await tester.tap(find.byTooltip('隐藏'));
        await tester.pump();
        _secretKey(await _capture(tester, 'API Key', '$label-key-hidden-again'), hidden: true);
        expect(backend.callNames.where((name) => name != 'read'), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('URL clipboard shortcut preserves a port and path without filling or writing a key', (tester) async {
    const url = 'https://paste.example.invalid:8443/custom/path/v1';
    var reads = 0;
    _clipboard(tester, url, () => reads++);
    final backend = FakeProviderBackend();
    await _open(tester, backend);
    _ordinaryUrl(await _capture(tester, 'Base URL', 'provider-clipboard-url'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(tester.widget<TextField>(_field('Base URL')).controller!.text, url);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, isEmpty);
    expect(reads, greaterThan(0));
    expect(backend.callNames.where((name) => name != 'read'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HarmonyOS: the system paste button fills the key, normalized, marked edited', (tester) async {
    final paste = FakePaste(tester, reply: FakePaste.text('  sk-g53-pasted\n'), flutterText: 'wrong');
    final backend = sampleBackend(isLocal: false);
    await _open(tester, backend, edit: true, os: 'ohos');
    await tester.tap(find.text('粘贴'));
    await settle(tester);
    expect(paste.reads, hasLength(1));
    expect(paste.flutterReads, 0);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, 'sk-g53-pasted');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(backend.stored[gateway.apiKeyEnv], 'sk-g53-pasted');
  });

  testWidgets('HarmonyOS: backed out of leaves the key alone, and saving stores nothing new', (tester) async {
    FakePaste(tester, reply: {'status': 'cancelled'});
    final backend = sampleBackend(isLocal: false);
    await _open(tester, backend, edit: true, os: 'ohos');
    final before = tester.widget<TextField>(_field('API Key')).controller!.text;
    await tester.tap(find.text('粘贴'));
    await settle(tester);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, before);
    expect(find.byType(SnackBar), findsNothing);
    expect(backend.callNames.where((name) => name == 'storeKey'), isEmpty);
  });

  testWidgets('explicit key paste keeps password policy and saves the key separately from the URL', (tester) async {
    var reads = 0;
    _clipboard(tester, '  sk-g53-pasted\n', () => reads++);
    final backend = sampleBackend(isLocal: false);
    await _open(tester, backend, edit: true);
    await tester.tap(find.text('粘贴'));
    await settle(tester);
    expect(reads, 1);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, 'sk-g53-pasted');
    expect(tester.widget<TextField>(_field('Base URL')).controller!.text, gateway.baseUrl);
    _secretKey(await _capture(tester, 'API Key', 'provider-pasted-key-hidden'), hidden: true);
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(backend.callNames.where((name) => name != 'read'), ['update', 'storeKey']);
    final update = backend.calls.firstWhere((call) => call.$1 == 'update').$2;
    expect(update['baseURL'], gateway.baseUrl);
    expect(update.containsKey('apiKey'), isFalse);
    expect(backend.stored[gateway.apiKeyEnv], 'sk-g53-pasted');
    expect(find.byType(ProviderFormPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('revealing an empty edit key does not expose or replace the stored credential', (tester) async {
    final backend = sampleBackend();
    final stored = Map<String, String>.of(backend.stored);
    await _open(tester, backend, edit: true);
    expect(find.text('已保存，留空则不修改'), findsOneWidget);
    _secretKey(await _capture(tester, 'API Key', 'provider-empty-key-hidden'), hidden: true);
    await tester.tap(find.byTooltip('显示'));
    await tester.pump();
    _secretKey(await _capture(tester, 'API Key', 'provider-empty-key-shown'), hidden: false);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, isEmpty);
    const url = 'https://edited.example.invalid:9443/tenant/v2';
    await tester.enterText(_field('Base URL'), url);
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(backend.callNames.where((name) => name != 'read'), ['update']);
    expect(backend.stored, stored);
    expect(backend.calls.firstWhere((call) => call.$1 == 'update').$2['baseURL'], url);
    expect(tester.takeException(), isNull);
  });
}
