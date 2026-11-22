// 添加 / 编辑渠道: validation in place, fetch → pick → save calls the engine
// in the right order with the right shapes, edit keeps the stored key, keys
// stay on the engine they were typed for. Geometry: equal insets around the
// fields, the protocol capsule, the pinned button and the picker.

import 'dart:async';

import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsMetrics;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

/// Opens the form from a plain page so the pop result can be read.
class _Opener extends StatefulWidget {
  const _Opener({this.existing});

  final CustomProvider? existing;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  Object? result = 'none';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('result: $result'),
          TextButton(
            onPressed: () async {
              final r = await Navigator.of(context)
                  .push(MaterialPageRoute<String>(builder: (_) => ProviderFormPage(existing: widget.existing)));
              setState(() => result = r);
            },
            child: const Text('open'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  FakeProviderBackend? backend, {
  CustomProvider? existing,
  MemoryProviderKeyVault? vault,
  double height = 1400,
  FakeProviderBackend? Function()? backendFor,
}) async {
  // Real glyph widths: the capsule's fit depends on them.
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390 * 2, height * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: _Opener(existing: existing),
      brightness: Brightness.light,
      overrides: backendFor == null
          ? providerOverrides(backend, vault: vault)
          : [
              // The support helper's first override is the backend being switched.
              ...providerOverrides(backend, vault: vault).skip(1),
              providerBackendProvider.overrideWith((ref) => backendFor()),
            ],
    ),
  );
  await tester.tap(find.text('open'));
  await settle(tester);
}

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
  matching: find.byType(TextField),
);

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.enterText(_field(label), text);
  await tester.pump();
}

class _DelayedDiscovery extends FakeProviderBackend {
  final response = Completer<List<DiscoveredModel>>();

  @override
  Future<List<DiscoveredModel>> discover({
    String? provider,
    String? baseUrl,
    ProviderApi? api,
    String? apiKey,
    Map<String, String>? headers,
  }) {
    calls.add(('discover', {'baseURL': ?baseUrl, 'headers': ?headers}));
    return response.future;
  }
}

const _headerProfile = ProviderProfile(
  route: 'custom-header-gateway',
  displayName: 'Header gateway',
  api: 'openai-completions',
  baseUrl: 'https://gw.example.com/v1',
  models: [ProviderModelSpec(id: 'm1')],
  headers: {'x-opencode-session': 'session-1'},
);

Finder _headerField(String field, [int index = 0]) => find.byKey(ValueKey('provider-header-$field-$index'));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settle(tester);
}

Future<void> _openHeaders(WidgetTester tester) => _tapVisible(tester, find.text('请求头（可选）'));

Future<void> _addHeader(WidgetTester tester, String name, String value) async {
  await _tapVisible(tester, find.text('添加请求头'));
  final index = find.byType(TextFormField).evaluate().length ~/ 2 - 1;
  await tester.enterText(_headerField('name', index), name);
  await tester.enterText(_headerField('value', index), value);
  await tester.pump();
}

Future<void> _manualModel(WidgetTester tester) async {
  await _tapVisible(tester, find.text('手动添加'));
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'm1');
  await tester.tap(find.widgetWithText(FilledButton, '添加'));
  await settle(tester);
}

void main() {
  testWidgets('late discovery preserves an endpoint edited while loading', (tester) async {
    final backend = _DelayedDiscovery();
    await _open(tester, backend);
    await _type(tester, 'Base URL', 'https://old.example.com/v1');
    await _type(tester, 'API Key', 'sk-old');
    await tester.tap(find.text('获取模型'));
    await tester.pump();
    expect(backend.callNames, contains('discover'));
    await _type(tester, 'Base URL', 'https://new.example.com/v1');
    backend.response.complete(discovered);
    await settle(tester);
    expect(tester.widget<TextField>(_field('Base URL')).controller!.text, 'https://new.example.com/v1');
    expect(find.byType(ModelPickerSheet), findsNothing);
    expect(find.text('获取模型'), findsOneWidget);
  });

  testWidgets('late discovery failure does not blame an edited credential', (tester) async {
    final backend = _DelayedDiscovery();
    await _open(tester, backend);
    await _type(tester, 'Base URL', 'https://gw.example.com/v1');
    await _type(tester, 'API Key', 'sk-old');
    await tester.tap(find.text('获取模型'));
    await tester.pump();
    await _type(tester, 'API Key', 'sk-new');
    backend.response.completeError(listingRefused('https://gw.example.com/v1', 401));
    await settle(tester);
    expect(find.text('API Key 无效或没有权限'), findsNothing);
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, 'sk-new');
    expect(find.text('获取模型'), findsOneWidget);
  });

  testWidgets('late discovery ignores a response after the active backend changes', (tester) async {
    final original = _DelayedDiscovery();
    FakeProviderBackend active = original;
    await _open(tester, original, backendFor: () => active);
    await _type(tester, 'Base URL', 'https://gw.example.com/v1');
    await _type(tester, 'API Key', 'sk-old');
    await tester.tap(find.text('获取模型'));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(ProviderFormPage)));
    active = FakeProviderBackend();
    container.invalidate(providerBackendProvider);
    await tester.pump();
    original.response.complete(discovered);
    await settle(tester);
    expect(find.byType(ModelPickerSheet), findsNothing);
    expect(find.text('DeepSeek V4 Pro'), findsNothing);
  });

  testWidgets('late discovery picker cannot add models after the active backend changes', (tester) async {
    final original = FakeProviderBackend(discoverResult: discovered);
    FakeProviderBackend active = original;
    await _open(tester, original, backendFor: () => active);
    await _type(tester, 'Base URL', 'https://gw.example.com/v1');
    await _type(tester, 'API Key', 'sk-old');
    await tester.tap(find.text('获取模型'));
    await settle(tester);
    expect(find.byType(ModelPickerSheet), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(ProviderFormPage)));
    active = FakeProviderBackend();
    container.invalidate(providerBackendProvider);
    await tester.pump();
    await tester.tap(find.text('添加 3 个模型'));
    await settle(tester);
    expect(find.text('DeepSeek V4 Pro'), findsNothing);
    expect(find.text('模型 · 3'), findsNothing);
  });

  group('request headers', () {
    testWidgets('stored reserved headers stay read-only while an adjacent header changes', (tester) async {
      const profile = ProviderProfile(
        route: 'custom-reserved-header',
        api: 'openai-completions',
        baseUrl: 'https://gw.example.com/v1',
        models: [ProviderModelSpec(id: 'm1')],
        headers: {'UsEr-AgEnT': 'legacy-agent', 'x-opencode-session': 'old-session'},
      );
      final backend = FakeProviderBackend(profiles: const [profile]);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, backend, existing: CustomProvider.fromProfile(profile), height: 844);
      tester.view.physicalSize = const Size(640, 1688);
      await tester.pump();
      await _openHeaders(tester);
      await _tapVisible(tester, _headerField('value', 1));
      await tester.enterText(_headerField('value', 1), 'new-session');
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.callNames, contains('discover'), reason: 'an untouched reserved row must not reject its neighbor');
      expect(backend.calls.last.$2['headers'], {'UsEr-AgEnT': 'legacy-agent', 'x-opencode-session': 'new-session'});
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.profiles.single.headers, {'UsEr-AgEnT': 'legacy-agent', 'x-opencode-session': 'new-session'});
    });

    testWidgets('a stored reserved row exposes neither text editing nor deletion', (tester) async {
      const profile = ProviderProfile(
        route: 'custom-reserved-header',
        api: 'openai-completions',
        baseUrl: 'https://gw.example.com/v1',
        models: [ProviderModelSpec(id: 'm1')],
        headers: {'UsEr-AgEnT': 'legacy-agent', 'x-opencode-session': 'session-1'},
      );
      await _open(
        tester,
        FakeProviderBackend(profiles: const [profile]),
        existing: CustomProvider.fromProfile(profile),
      );
      await _openHeaders(tester);
      for (final field in ['name', 'value']) {
        final input = tester.widget<TextField>(
          find.descendant(of: _headerField(field), matching: find.byType(TextField)),
        );
        expect(input.readOnly, isTrue, reason: field);
        expect(tester.widget<TextFormField>(_headerField(field)).onChanged, isNull, reason: field);
      }
      final delete = tester.widget<TextButton>(
        find.ancestor(of: find.text('删除').first, matching: find.byType(TextButton)),
      );
      expect(delete.onPressed, isNull);
      final normal = tester.widget<TextField>(
        find.descendant(of: _headerField('value', 1), matching: find.byType(TextField)),
      );
      expect(normal.readOnly, isFalse);
    });

    testWidgets('renaming an ordinary header to a reserved name is rejected and remains correctable', (tester) async {
      final backend = FakeProviderBackend(profiles: const [_headerProfile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(_headerProfile));
      await _openHeaders(tester);
      await tester.enterText(_headerField('name'), 'USER-AGENT');
      await _tapVisible(tester, find.text('获取模型'));
      expect(find.text('User-Agent 由引擎设置，请移除此请求头'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((name) => name != 'read'), isEmpty);
      await tester.enterText(_headerField('name'), 'X-Trace');
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.calls.last.$2['headers'], {'X-Trace': 'session-1'});
    });

    testWidgets('draft discovery and save use the entered header map', (tester) async {
      final backend = FakeProviderBackend(discoverResult: discovered);
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-test');
      await _openHeaders(tester);
      expect(find.textContaining('不参与日志脱敏'), findsOneWidget);
      await _addHeader(tester, ' x-opencode-session ', 'session-1');
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.calls.firstWhere((call) => call.$1 == 'discover').$2['headers'], {
        'x-opencode-session': 'session-1',
      });
      await tester.tap(find.text('添加 3 个模型'));
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.calls.firstWhere((call) => call.$1 == 'create').$2['headers'], {
        'x-opencode-session': 'session-1',
      });
      expect(find.text('result: custom-gw-example'), findsOneWidget);
    });

    testWidgets('stored headers read back and stay omitted until edited', (tester) async {
      final backend = FakeProviderBackend(profiles: const [_headerProfile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(_headerProfile));
      await _openHeaders(tester);
      expect(tester.widget<TextFormField>(_headerField('name')).initialValue, 'x-opencode-session');
      expect(tester.widget<TextFormField>(_headerField('value')).initialValue, 'session-1');
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.calls.last.$2.containsKey('headers'), isFalse);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.calls.firstWhere((call) => call.$1 == 'update').$2.containsKey('headers'), isFalse);
      expect(backend.profiles.single.headers, _headerProfile.headers);
    });

    testWidgets('editing headers replaces the whole map and preserves other fields', (tester) async {
      const profile = ProviderProfile(
        route: 'custom-two-headers',
        api: 'openai-completions',
        baseUrl: 'https://gw.example.com/v1',
        models: [ProviderModelSpec(id: 'm1')],
        headers: {'x-opencode-session': 'old-session', 'X-Team': 'remove-me'},
      );
      final backend = FakeProviderBackend(profiles: const [profile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(profile));
      await _openHeaders(tester);
      await tester.enterText(_headerField('value'), 'new-session');
      await _tapVisible(tester, find.text('删除').last);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.profiles.single.headers, {'x-opencode-session': 'new-session'});
      expect(backend.profiles.single.models.single.id, 'm1');
      expect(backend.profiles.single.baseUrl, profile.baseUrl);
    });

    testWidgets('untouched legacy headers are neither normalized nor rejected', (tester) async {
      const profile = ProviderProfile(
        route: 'custom-legacy-headers',
        api: 'openai-completions',
        baseUrl: 'https://gw.example.com/v1',
        models: [ProviderModelSpec(id: 'm1')],
        headers: {' User-Agent ': 'legacy', 'X-Legacy': '旧配置'},
      );
      final backend = FakeProviderBackend(profiles: const [profile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(profile));
      await _openHeaders(tester);
      expect(tester.widget<TextFormField>(_headerField('name')).initialValue, ' User-Agent ');
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.calls.last.$2.containsKey('headers'), isFalse);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.calls.firstWhere((call) => call.$1 == 'update').$2.containsKey('headers'), isFalse);
      expect(backend.profiles.single.headers, profile.headers);
    });

    testWidgets('removing the last stored header explicitly clears discovery and save', (tester) async {
      final backend = FakeProviderBackend(profiles: const [_headerProfile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(_headerProfile));
      await _openHeaders(tester);
      await _tapVisible(tester, find.text('删除'));
      await _tapVisible(tester, find.text('获取模型'));
      expect(backend.calls.last.$2['headers'], isEmpty);
      expect(backend.calls.last.$2.containsKey('headers'), isTrue);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.calls.firstWhere((call) => call.$1 == 'update').$2['headers'], isEmpty);
      expect(backend.profiles.single.headers, isEmpty);
    });

    testWidgets('duplicate names block both discovery and save without hiding values', (tester) async {
      final backend = FakeProviderBackend(profiles: const [_headerProfile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(_headerProfile));
      await _openHeaders(tester);
      await _addHeader(tester, 'X-OPENCODE-SESSION', 'other');
      await _tapVisible(tester, find.text('获取模型'));
      expect(find.text('请求头名称重复（不区分大小写）'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((name) => name != 'read'), isEmpty);
      expect(tester.widget<TextFormField>(_headerField('value', 1)).initialValue, 'other');
      final input = tester.widget<TextField>(
        find.descendant(of: _headerField('value', 1), matching: find.byType(TextField)),
      );
      expect(input.obscureText, isFalse);
      expect(input.autocorrect, isFalse);
      expect(input.enableSuggestions, isTrue);
    });

    for (final failure in [false, true]) {
      testWidgets('late discovery ${failure ? 'failure' : 'success'} belongs to the header snapshot', (tester) async {
        final backend = _DelayedDiscovery();
        await _open(tester, backend);
        await _type(tester, 'Base URL', 'https://gw.example.com/v1');
        await _type(tester, 'API Key', 'sk-test');
        await _openHeaders(tester);
        await _addHeader(tester, 'x-opencode-session', 'old-session');
        await tester.ensureVisible(find.text('获取模型'));
        await tester.tap(find.text('获取模型'));
        await tester.pump();
        expect(backend.callNames, contains('discover'));
        await tester.enterText(_headerField('value'), 'new-session');
        if (failure) {
          backend.response.completeError(listingRefused('https://gw.example.com/v1', 401));
        } else {
          backend.response.complete(discovered);
        }
        await settle(tester);
        expect(find.byType(ModelPickerSheet), findsNothing);
        expect(find.text('API Key 无效或没有权限'), findsNothing);
        expect(tester.widget<TextFormField>(_headerField('value')).initialValue, 'new-session');
      });
    }

    testWidgets('headers survive a partial create and can be cleared on the retry', (tester) async {
      final backend = FakeProviderBackend()..storeKeyError = const ProviderFailure('Key write refused');
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-test');
      await _openHeaders(tester);
      await _addHeader(tester, 'x-opencode-session', 'session-1');
      await _manualModel(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.profiles.single.headers, {'x-opencode-session': 'session-1'});
      expect(find.textContaining('渠道已保存，Key 没有存上'), findsOneWidget);
      backend.storeKeyError = null;
      await _tapVisible(tester, find.text('删除'));
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((name) => name == 'create'), hasLength(1));
      expect(backend.calls.firstWhere((call) => call.$1 == 'update').$2['headers'], isEmpty);
      expect(backend.profiles.single.headers, isEmpty);
    });

    testWidgets('header-only edits survive collapse and trigger the discard guard', (tester) async {
      final backend = FakeProviderBackend(profiles: const [_headerProfile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(_headerProfile));
      await _openHeaders(tester);
      await tester.enterText(_headerField('value'), 'edited-session');
      await _openHeaders(tester);
      await _openHeaders(tester);
      expect(tester.widget<TextFormField>(_headerField('value')).initialValue, 'edited-session');
      await tester.tap(find.byIcon(AppIcons.back));
      await settle(tester);
      expect(find.text('放弃修改？'), findsOneWidget);
      expect(backend.callNames.where((name) => name != 'read'), isEmpty);
    });
  });

  group('validation', () {
    testWidgets('an empty save names every missing field and writes nothing', (tester) async {
      final backend = FakeProviderBackend();
      await _open(tester, backend);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(find.text('填写 Base URL'), findsOneWidget);
      expect(find.text('填写 API Key'), findsOneWidget);
      expect(find.text('至少添加一个模型'), findsOneWidget);
      expect(backend.callNames.where((c) => c != 'read'), isEmpty);

      // Typing clears that field's error only.
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      expect(find.text('填写 Base URL'), findsNothing);
      expect(find.text('填写 API Key'), findsOneWidget);
    });

    testWidgets('a bad URL or a pasted env line is refused in place', (tester) async {
      await _open(tester, FakeProviderBackend());
      await _type(tester, 'Base URL', 'gw.example.com');
      await _type(tester, 'API Key', 'OPENAI_API_KEY=sk-123');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(find.text('以 http:// 或 https:// 开头的完整地址'), findsOneWidget);
      expect(find.text('只粘贴 Key 本身，不带变量名'), findsOneWidget);
    });

    testWidgets('fetching needs a key on a new provider', (tester) async {
      final backend = FakeProviderBackend(discoverResult: discovered);
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await tester.tap(find.text('获取模型'));
      await settle(tester);
      expect(find.text('先填写 API Key'), findsOneWidget);
      expect(backend.callNames, isNot(contains('discover')));
    });

    testWidgets('the protocol switches the Base URL placeholder; no helper lines', (tester) async {
      await _open(tester, FakeProviderBackend());
      String? hint() => tester.widget<TextField>(_field('Base URL')).decoration!.hintText;
      expect(hint(), 'https://api.example.com/v1');
      await tester.tap(find.text('Anthropic'));
      await settle(tester);
      expect(hint(), 'https://api.example.com');
      expect(find.textContaining('Keystore'), findsNothing);
      expect(find.textContaining('/v1 结尾'), findsNothing);
    });

    testWidgets('no monospace anywhere in the form', (tester) async {
      await _open(tester, sampleBackend(), existing: CustomProvider.fromProfile(gateway));
      await _type(tester, 'API Key', 'sk-visible');
      await tester.tap(find.byTooltip('显示'));
      await settle(tester);
      for (final field in tester.widgetList<EditableText>(find.byType(EditableText))) {
        expect(field.style.fontFamily, isNot(AppType.monoFamily), reason: field.controller.text);
      }
    });
  });

  group('create', () {
    for (final (label, endpoint, expected) in [
      ('OpenAI', 'https://gw.example.com/v1/chat/completions///', 'https://gw.example.com/v1'),
      ('Responses', 'https://gw.example.com/api/v3/responses', 'https://gw.example.com/api/v3'),
      ('Anthropic', 'https://gw.example.com/Tenant/v1/messages', 'https://gw.example.com/Tenant'),
      ('Anthropic', 'https://gw.example.com/Tenant/v1/v1/messages', 'https://gw.example.com/Tenant/v1'),
      ('Anthropic', 'https://gw.example.com/Proxy/messages', 'https://gw.example.com/Proxy'),
    ]) {
      testWidgets('one endpoint after discovery and save: $label $endpoint', (tester) async {
        final backend = FakeProviderBackend(discoverResult: discovered);
        await _open(tester, backend);
        await tester.tap(find.text(label));
        await _type(tester, 'Base URL', endpoint);
        await _type(tester, 'API Key', 'sk-fixture');
        await tester.tap(find.text('获取模型'));
        await settle(tester);
        expect(backend.calls.firstWhere((c) => c.$1 == 'discover').$2['baseURL'], expected);
        await tester.tap(find.text('添加 3 个模型'));
        await settle(tester);
        final displayed = tester.widget<TextField>(_field('Base URL')).controller!.text;
        await tester.tap(find.text('保存'));
        await settle(tester);
        expect(backend.calls.firstWhere((c) => c.$1 == 'create').$2['baseURL'], expected);
        expect(displayed, endpoint, reason: 'ordinary discovery keeps the original input for the next save');
        expect(backend.callNames.where((c) => c != 'read'), ['discover', 'create', 'storeKey']);
      });
    }

    testWidgets('fetch → pick two → save: profile, then key; pops with the id', (tester) async {
      final backend = FakeProviderBackend(discoverResult: discovered);
      final vault = MemoryProviderKeyVault();
      await _open(tester, backend, vault: vault);
      await _type(tester, '名称', 'My Gateway');
      await _type(tester, 'Base URL', ' https://gw.example.com/v1/ ');
      await _type(tester, 'API Key', ' sk-gw-123 ');
      await tester.tap(find.text('获取模型'));
      await settle(tester);

      // Three candidates, all ticked; untick glm-4.6.
      expect(find.byType(ModelPickerSheet), findsOneWidget);
      expect(find.text('添加 3 个模型'), findsOneWidget);
      await tester.tap(find.text('glm-4.6'));
      await settle(tester);
      await tester.tap(find.text('添加 2 个模型'));
      await settle(tester);
      expect(find.text('模型 · 2'), findsOneWidget);
      expect(find.text('DeepSeek V4 Pro'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((c) => c != 'read'), ['discover', 'create', 'storeKey']);
      expect(backend.calls.firstWhere((c) => c.$1 == 'discover').$2, {
        'baseURL': 'https://gw.example.com/v1',
        'api': 'openai-completions',
        'apiKey': 'sk-gw-123',
      });
      expect(backend.calls.firstWhere((c) => c.$1 == 'create').$2, {
        'displayName': 'My Gateway',
        'api': 'openai-completions',
        'baseURL': 'https://gw.example.com/v1',
        'apiKeyEnv': 'CUSTOM_MY_GATEWAY_API_KEY',
        'models': [
          {
            'id': 'deepseek-v4-pro',
            'name': 'DeepSeek V4 Pro',
            'contextWindow': 1048576,
            'input': ['text', 'image'],
            'reasoningEfforts': {'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'},
          },
          {
            'id': 'qwen3-coder',
            'name': 'Qwen3 Coder',
            'contextWindow': 262144,
            'maxTokens': 65536,
            'input': ['text', 'image'],
            'reasoningEfforts': {'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'},
          },
        ],
        'route': 'custom-my-gateway',
      });
      expect(backend.calls.firstWhere((c) => c.$1 == 'storeKey').$2, {
        'ref': 'CUSTOM_MY_GATEWAY_API_KEY',
        'key': 'sk-gw-123',
      });
      expect(vault.data, {'custom-my-gateway': 'sk-gw-123'});
      expect(find.text('result: custom-my-gateway'), findsOneWidget);
    });

    testWidgets('a 404 on a bare host is retried with /v1 and the field updated', (tester) async {
      final backend = FakeProviderBackend()
        ..discoverFor = (url) =>
            url == 'https://gw.example.com/v1' ? discovered : listingRefused('https://gw.example.com', 404);
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com');
      await _type(tester, 'API Key', 'sk-1');
      await tester.tap(find.text('获取模型'));
      await settle(tester);
      expect(find.byType(ModelPickerSheet), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await settle(tester);
      // The notice sits right under the field it is about.
      final note = tester.getRect(find.text('已补全为 https://gw.example.com/v1'));
      final field = tester.getRect(_field('Base URL'));
      final keyLabel = tester.getRect(find.text('API Key'));
      expect(note.top, greaterThan(field.bottom));
      expect(note.bottom, lessThan(keyLabel.top));
      expect(tester.widget<TextField>(_field('Base URL')).controller!.text, 'https://gw.example.com/v1');
      // Editing the URL again drops it.
      await _type(tester, 'Base URL', 'https://gw.example.com/v2');
      expect(find.textContaining('已补全为'), findsNothing);
    });

    testWidgets('a refused fetch shows one Chinese line under the models', (tester) async {
      final backend = FakeProviderBackend()..discoverError = listingRefused('https://gw.example.com/v1', 401);
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-wrong');
      await tester.tap(find.text('获取模型'));
      await settle(tester);
      expect(find.byType(ModelPickerSheet), findsNothing);
      expect(find.text('API Key 无效或没有权限'), findsOneWidget);
    });

    testWidgets('a model added by hand is checked for duplicates', (tester) async {
      final backend = FakeProviderBackend();
      await _open(tester, backend);
      for (final id in ['qwen3-coder', 'qwen3-coder']) {
        await tester.tap(find.text('手动添加'));
        await settle(tester);
        await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), id);
        await tester.tap(find.widgetWithText(FilledButton, '添加'));
        await settle(tester);
      }
      expect(find.text('已经添加过'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(find.text('模型 · 1'), findsOneWidget);

      // Anthropic drops a pasted /v1; the hand-added model is saved with the
      // image / thinking defaults.
      await tester.tap(find.text('Anthropic'));
      await _type(tester, 'Base URL', 'https://relay.example.cn/v1/');
      await _type(tester, 'API Key', 'sk-ant-1');
      await tester.tap(find.text('保存'));
      await settle(tester);
      final created = backend.calls.firstWhere((c) => c.$1 == 'create').$2;
      expect(created['api'], 'anthropic-messages');
      expect(created['baseURL'], 'https://relay.example.cn');
      expect(created['displayName'], 'relay.example.cn', reason: 'no name: the host');
      expect(created['models'], [
        {
          'id': 'qwen3-coder',
          'input': ['text', 'image'],
          'reasoningEfforts': {'off': null, 'low': 'low', 'medium': 'medium', 'high': 'high'},
        },
      ]);
    });

    testWidgets('a key the engine refuses leaves the form open, now editing', (tester) async {
      final backend = FakeProviderBackend(discoverResult: discovered)
        ..storeKeyError = const ProviderFailure('引擎的启动环境已提供这个 Key，无法在这里修改');
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-1');
      await tester.tap(find.text('手动添加'));
      await settle(tester);
      await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'm1');
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await settle(tester);
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(find.textContaining('渠道已保存，Key 没有存上'), findsOneWidget);
      expect(find.text('编辑渠道'), findsWidgets);

      backend.storeKeyError = null;
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((c) => c != 'read' && c != 'storeKey'), ['create', 'update']);
      expect(backend.stored['CUSTOM_GW_EXAMPLE_API_KEY'], 'sk-1');
    });
  });

  group('edit', () {
    for (final (api, base) in [
      (ProviderApi.openaiCompletions, 'https://gw.example.com/tenant/chat/completions'),
      (ProviderApi.openaiResponses, 'https://gw.example.com/tenant/responses'),
      (ProviderApi.anthropicMessages, 'https://gw.example.com/tenant/v1/messages'),
      (ProviderApi.anthropicMessages, 'https://gw.example.com/tenant/v1'),
    ]) {
      for (final discoverFirst in [false, true]) {
        testWidgets('preserves stored base $base, discovery $discoverFirst', (tester) async {
          final profile = ProviderProfile(
            route: 'custom-stored',
            api: api.wire,
            baseUrl: base,
            models: const [ProviderModelSpec(id: 'model')],
          );
          final backend = FakeProviderBackend(profiles: [profile]);
          await _open(tester, backend, existing: CustomProvider.fromProfile(profile));
          await _type(tester, '名称', 'Renamed');
          if (discoverFirst) {
            await tester.tap(find.text('获取模型'));
            await settle(tester);
            expect(backend.calls.firstWhere((c) => c.$1 == 'discover').$2['baseURL'], base);
          }
          await tester.tap(find.text('保存'));
          await settle(tester);
          final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
          expect(update['displayName'], 'Renamed');
          expect(update['baseURL'], base, reason: 'the unchanged address is already a stored base');
          expect(update['api'], api.wire);
          expect(update['expectedRevision'], 3);
          expect(backend.callNames, isNot(contains('storeKey')));
        });
      }
    }

    testWidgets('a protocol-only edit reinterprets the address for that protocol', (tester) async {
      const profile = ProviderProfile(
        route: 'custom-stored',
        api: 'openai-responses',
        baseUrl: 'https://gw.example.com/tenant/v1/messages',
        models: [ProviderModelSpec(id: 'model')],
      );
      final backend = FakeProviderBackend(profiles: [profile]);
      await _open(tester, backend, existing: CustomProvider.fromProfile(profile));
      await tester.tap(find.text('Anthropic'));
      await tester.tap(find.text('保存'));
      await settle(tester);
      final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
      expect(update['api'], 'anthropic-messages');
      expect(update['baseURL'], 'https://gw.example.com/tenant');
    });

    for (final (label, endpoint, expected) in [
      ('OpenAI', 'https://gw.example.com/v1/chat/completions', 'https://gw.example.com/v1'),
      ('Responses', 'https://gw.example.com/api/v3/responses', 'https://gw.example.com/api/v3'),
      ('Anthropic', 'https://gw.example.com/Tenant/v1/messages', 'https://gw.example.com/Tenant'),
    ]) {
      testWidgets('saves a full $label endpoint without discovery', (tester) async {
        final backend = sampleBackend();
        await _open(tester, backend, existing: CustomProvider.fromProfile(gateway));
        await tester.tap(find.text(label));
        await _type(tester, 'Base URL', endpoint);
        await tester.tap(find.text('保存'));
        await settle(tester);
        final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
        expect(update['baseURL'], expected);
        expect(update['expectedRevision'], 3);
        expect(backend.callNames.where((c) => c != 'read'), ['update']);
      });
    }

    for (final suffix in ['?x=1', '#fragment']) {
      testWidgets('endpoint with $suffix is rejected before discovery and save', (tester) async {
        final backend = sampleBackend();
        await _open(tester, backend, existing: CustomProvider.fromProfile(gateway));
        await _type(tester, 'Base URL', 'https://gw.example.com/v1/chat/completions$suffix');
        await tester.tap(find.text('获取模型'));
        await settle(tester);
        expect(find.text('去掉 ? 或 # 之后的部分'), findsOneWidget);
        await tester.tap(find.text('保存'));
        await settle(tester);
        expect(find.text('去掉 ? 或 # 之后的部分'), findsOneWidget);
        expect(backend.callNames.where((c) => c != 'read'), isEmpty);
      });
    }

    testWidgets('prefilled; an empty key keeps the stored one', (tester) async {
      final backend = sampleBackend();
      final gw = CustomProvider.fromProfile(gateway);
      final vault = MemoryProviderKeyVault();
      await _open(tester, backend, existing: gw, vault: vault);
      expect(find.text('编辑渠道'), findsWidgets);
      expect(find.text('已保存，留空则不修改'), findsOneWidget);
      expect(find.text('模型 · 3'), findsOneWidget);
      await tester.tap(find.byTooltip('移除 kimi-k2-0905'));
      await settle(tester);
      await _type(tester, '名称', 'Gateway');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.callNames.where((c) => c != 'read'), ['update']);
      final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
      expect(update['displayName'], 'Gateway');
      expect((update['models']! as List).map((m) => (m as Map)['id']), ['qwen3-coder', 'glm-4.6']);
      expect(update['expectedRevision'], 3);
      expect(vault.data, isEmpty);
      expect(find.text('result: custom-mygw'), findsOneWidget);
    });

    testWidgets('on a remote host the key goes to that host only', (tester) async {
      final backend = sampleBackend(isLocal: false);
      final vault = MemoryProviderKeyVault();
      await _open(tester, backend, existing: CustomProvider.fromProfile(claudeRelay), vault: vault);
      await _type(tester, 'API Key', 'sk-relay');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect(backend.stored['CUSTOM_CLAUDE_RELAY_API_KEY'], 'sk-relay');
      expect(vault.data, isEmpty);
    });
  });

  testWidgets('without an engine the form waits instead of failing', (tester) async {
    await _open(tester, null);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '等待引擎连接'));
    expect(button.onPressed, isNull);
  });

  group('geometry', () {
    const tol = 0.6;

    for (final scale in [1.0, 1.3]) {
      testWidgets('fields, protocol capsule and the pinned button share one column (text ×$scale)', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _open(tester, FakeProviderBackend(), height: 1600);
        final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

        final card = tester.getRect(find.ancestor(of: find.text('名称'), matching: find.byType(GlassSurface)).first);
        // Cards sit 16 from both screen edges.
        expect(card.left, moreOrLessEquals(16, epsilon: tol));
        expect(width - card.right, moreOrLessEquals(16, epsilon: tol));

        // Every input and the capsule: 16 inside the card on both sides.
        for (final rect in [
          tester.getRect(_field('名称')),
          tester.getRect(_field('Base URL')),
          tester.getRect(_field('API Key')),
          tester.getRect(find.byType(SegmentedPill<ProviderApi>)),
        ]) {
          expect(rect.left - card.left, moreOrLessEquals(SettingsMetrics.inset, epsilon: tol));
          expect(card.right - rect.right, moreOrLessEquals(SettingsMetrics.inset, epsilon: tol));
        }

        // The protocol capsule's three segments are equal and fit unscaled.
        final segments = [
          for (final label in ['OpenAI', 'Anthropic', 'Responses'])
            tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(Expanded)).first),
        ];
        expect(segments[0].width, moreOrLessEquals(segments[1].width, epsilon: tol));
        expect(segments[1].width, moreOrLessEquals(segments[2].width, epsilon: tol));
        for (final label in ['OpenAI', 'Anthropic', 'Responses']) {
          final fitted = find.ancestor(of: find.text(label), matching: find.byType(FittedBox)).first;
          final inner = tester.getSize(find.text(label));
          // One line always; at the default size nothing is shrunk to fit.
          expect(inner.height, lessThan(30 * scale));
          if (scale == 1.0) {
            expect(tester.getSize(fitted).width, greaterThanOrEqualTo(inner.width - tol), reason: '$label not shrunk');
          }
        }

        // The pinned button: 16 from both edges, like the cards.
        final button = tester.getRect(find.widgetWithText(FilledButton, '保存'));
        expect(button.left, moreOrLessEquals(16, epsilon: tol));
        expect(width - button.right, moreOrLessEquals(16, epsilon: tol));
      });
    }

    testWidgets('model rows: icon slot and remove glyph 16 in, rows 52 / 64', (tester) async {
      await _open(tester, sampleBackend(), existing: CustomProvider.fromProfile(gateway), height: 1600);
      final card = tester.getRect(find.ancestor(of: find.text('获取模型'), matching: find.byType(GlassSurface)).first);
      final icon = tester.getRect(find.byIcon(AppIcons.modelItem).first);
      final close = tester.getRect(find.byIcon(AppIcons.close).first);
      // The icon's 32 slot starts 16 in; the remove glyph's box ends 16 in,
      // where a settings row's chevron or switch ends.
      expect(icon.left - card.left, moreOrLessEquals(SettingsMetrics.inset, epsilon: tol));
      expect(icon.width, moreOrLessEquals(SettingsMetrics.icon, epsilon: tol));
      expect(close.width, moreOrLessEquals(SettingsMetrics.lineGlyph, epsilon: tol));
      expect(card.right - close.right, moreOrLessEquals(SettingsMetrics.inset, epsilon: tol));
      // Vertically the two glyphs share the row's centre line.
      expect(close.center.dy, moreOrLessEquals(icon.center.dy, epsilon: tol));
      // Rows: one line 52, two lines 64.
      final fetchRow = tester.getRect(find.ancestor(of: find.text('获取模型'), matching: find.byType(InkWell)).first);
      expect(fetchRow.height, moreOrLessEquals(SettingsMetrics.rowHeight, epsilon: tol));
      final modelRow = tester.getRect(
        find.ancestor(of: find.text('Qwen3 Coder'), matching: find.byType(InkWell)).first,
      );
      expect(modelRow.height, moreOrLessEquals(SettingsMetrics.rowHeightTwoLine, epsilon: tol));
    });

    testWidgets('picker: ticks, title and button on the sheet\'s 20 column', (tester) async {
      await _open(
        tester,
        FakeProviderBackend(
          discoverResult: [
            ...discovered,
            for (var i = 0; i < 8; i++) DiscoveredModel(id: 'm$i'),
          ],
        ),
        height: 1000,
      );
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-1');
      await tester.ensureVisible(find.text('获取模型'));
      await tester.pump();
      await tester.tap(find.text('获取模型'));
      await settle(tester);
      final sheet = tester.getRect(find.byType(ModelPickerSheet));
      final title = tester.getRect(find.text('选择模型'));
      final firstTick = tester.getRect(
        find.descendant(of: find.byType(ListView), matching: find.byType(AnimatedContainer)).first,
      );
      final search = tester.getRect(find.widgetWithText(TextField, '搜索模型'));
      final count = tester.getRect(find.text('共 11 个'));
      expect(count.left, moreOrLessEquals(search.left, epsilon: tol));
      expect(count.left, moreOrLessEquals(firstTick.left, epsilon: tol));
      final all = tester.getRect(find.text('全选'));
      final button = tester.getRect(find.widgetWithText(FilledButton, '添加'));
      const inset = SheetTitleBar.inset;
      expect(title.left - sheet.left, moreOrLessEquals(inset, epsilon: tol));
      expect(firstTick.left - sheet.left, moreOrLessEquals(inset, epsilon: tol));
      expect(search.left - sheet.left, moreOrLessEquals(inset, epsilon: tol));
      expect(sheet.right - search.right, moreOrLessEquals(inset, epsilon: tol));
      expect(sheet.right - all.right, moreOrLessEquals(inset, epsilon: tol));
      expect(button.left - sheet.left, moreOrLessEquals(inset, epsilon: tol));
      expect(sheet.right - button.right, moreOrLessEquals(inset, epsilon: tol));
      // A long list starts unticked; search narrows it.
      expect(find.text('添加'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '搜索模型'), 'qwen');
      await settle(tester);
      expect(find.text('qwen3-coder'), findsOneWidget);
      expect(find.text('m0'), findsNothing);
    });
  });
}
