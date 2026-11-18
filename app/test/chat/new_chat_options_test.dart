// The new chat's preset and permission chips: what they show before any
// pick, what a pick holds, and that the first send applies both to the new
// session before its prompt — and does not send under defaults the person
// did not choose when applying fails, not even after a restart.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/models_state.dart' show pendingModelProvider;
import 'package:dsh_app/state/new_chat_modes.dart';
import 'package:dsh_app/state/features_state.dart' show PermissionOption, PermissionState, agentPresetsProvider;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart' show ModelChip;
import 'package:dsh_app/ui/chat/new_chat_options.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart' show FakeRpcCarrier;
import 'support/harness.dart';

/// A Host with three presets (one hidden from new chats) and three
/// permission presets; commands succeed unless [failPermission] says not.
class _Host {
  _Host({bool companionDefault = false})
    : presets = [
        {'id': 'standard', 'isDefault': !companionDefault},
        {'id': 'minimal'},
        {'id': 'dsh-go-companion-full', 'name': 'Companion', 'isDefault': companionDefault},
      ];

  /// What `agentPresets/list` answers (a test may change it).
  List<Map<String, Object?>> presets;
  var failPermission = false;
  late final carrier = FakeRpcCarrier({
    'agentPresets/list': (_) => {'presets': presets},
    'permissionPresets/catalog': (_) => {
      'options': [
        {'value': 'read-only', 'name': 'Read only'},
        {'value': 'workspace-write', 'name': 'Workspace write'},
        {'value': 'danger-full-access', 'name': 'Full access'},
      ],
      'defaultPreset': 'workspace-write',
    },
    'settings/describe': (_) => {'namespaces': <Object?>[]},
    'agentPresets/select': (args) => args['agentPreset'],
    'commands/execute': (args) => {
      'commandId': 'c1',
      'result': {'kind': failPermission ? 'error' : 'success', 'text': failPermission ? 'refused' : 'ok'},
    },
  });
  late final connection = HostConnection(client: DshClient.withCarrier(carrier), isLocal: true);

  List<Map<String, Object?>> calls(String endpoint) => carrier.argsOf(endpoint);
}

Future<void> _pump(WidgetTester tester, ChatHarness harness, _Host host) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(host.connection)),
        ...harness.overrides.skip(1),
      ],
    ),
  );
  await pumpFrames(tester, 8);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ChatScreen)), listen: false);

Future<void> _pick(WidgetTester tester, String chip, String row) async {
  await tester.tap(find.text(chip));
  await pumpFrames(tester, 6);
  await tester.tap(find.text(row).last);
  await pumpFrames(tester, 6);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(AppIcons.send));
  await pumpFrames(tester, 8);
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    tipStart = (_) => 0;
  });

  testWidgets('chips name the Host defaults; companion preset is not offered', (tester) async {
    final host = _Host();
    await _pump(tester, ChatHarness(newChatCatalogs: true), host);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('new-chat-preset')), findsOneWidget);
    expect(find.text('标准模式'), findsOneWidget);
    expect(find.text('工作区内修改'), findsOneWidget);

    await tester.tap(find.text('标准模式'));
    await pumpFrames(tester, 6);
    expect(find.text('这次对话的预设'), findsOneWidget);
    expect(find.text('极简模式'), findsOneWidget);
    expect(find.text('Companion'), findsNothing);
  });

  testWidgets('a pick holds until the first send, which applies it before the prompt', (tester) async {
    final host = _Host();
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);

    await _pick(tester, '标准模式', '极简模式');
    await _pick(tester, '工作区内修改', '仅可查看');
    expect(
      _container(tester).read(pendingNewChatModesProvider),
      const NewChatModes(preset: 'minimal', permission: 'read-only'),
    );
    expect(find.text('极简模式'), findsOneWidget);
    expect(find.text('仅可查看'), findsOneWidget);
    expect(host.calls('agentPresets/select'), isEmpty, reason: 'nothing is applied before a session exists');

    await _send(tester, '你好');
    expect(harness.sessions.creates, 1);
    expect(host.calls('agentPresets/select'), [
      {'agentId': 'fresh', 'agentPreset': 'minimal'},
    ]);
    expect(host.calls('commands/execute').map((a) => (a['agentId'], a['line'])), [('fresh', '/permission read-only')]);
    expect(harness.controllers['fresh']!.sent, ['你好']);
    expect(_container(tester).read(pendingNewChatModesProvider).isEmpty, isTrue);
  });

  testWidgets('picking the default again keeps the default (nothing to apply)', (tester) async {
    final host = _Host();
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    await _pick(tester, '标准模式', '极简模式');
    await _pick(tester, '极简模式', '标准模式');
    expect(_container(tester).read(pendingNewChatModesProvider).isEmpty, isTrue);

    await _send(tester, '你好');
    expect(host.calls('agentPresets/select'), isEmpty);
    expect(host.calls('commands/execute'), isEmpty);
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  testWidgets('a permission that does not apply holds the message; the retry applies only what is owed', (
    tester,
  ) async {
    final host = _Host()..failPermission = true;
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    await _pick(tester, '标准模式', '极简模式');
    await _pick(tester, '工作区内修改', '仅可查看');

    await _send(tester, '你好');
    expect(harness.controllers['fresh']?.sent ?? const <String>[], isEmpty, reason: 'never under the default');
    expect(find.textContaining('没能设置预设或权限'), findsOneWidget);
    expect(host.calls('agentPresets/select'), hasLength(1));

    host.failPermission = false;
    // The notice sits over the composer for a moment; the message waits in it.
    await tester.pump(const Duration(seconds: 5));
    await pumpFrames(tester, 4);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 8);
    expect(host.calls('agentPresets/select'), hasLength(1), reason: 'the preset already applied');
    expect(host.calls('commands/execute'), hasLength(2));
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  testWidgets('a failed setup keeps the model with the session; the retry applies it before the prompt', (
    tester,
  ) async {
    final host = _Host()..failPermission = true;
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    await _pick(tester, '工作区内修改', '仅可查看');
    _container(tester).read(pendingModelProvider.notifier).select(_flash);
    await tester.pump();

    await _send(tester, '你好');
    expect(harness.controllers['fresh']?.sent ?? const <String>[], isEmpty);
    expect(harness.controllers['fresh']?.models ?? const <ModelSelection>[], isEmpty, reason: 'after the permission');
    expect(_container(tester).read(pendingModelProvider), isNull, reason: 'it went to the session, not a later chat');

    host.failPermission = false;
    await tester.pump(const Duration(seconds: 5));
    await pumpFrames(tester, 4);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 8);
    expect(host.calls('commands/execute'), hasLength(2));
    expect(harness.controllers['fresh']!.models.single.model, 'deepseek-flash');
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  testWidgets('what a failed setup still owes survives a restart and goes before the kept message', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => SharedPreferences.setMockInitialValues({}));
    final host = _Host()..failPermission = true;
    await _pump(tester, ChatHarness(created: 'fresh', newChatCatalogs: true), host);
    await _pick(tester, '工作区内修改', '仅可查看');
    await _send(tester, '你好');
    expect(host.calls('commands/execute'), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
    await pumpFrames(tester, 4);

    // The app starts again on the session that was created.
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, 2);
    host.failPermission = false;
    final again = ChatHarness(session: 'fresh', newChatCatalogs: true);
    await _pump(tester, again, host);
    await _send(tester, '你好');
    expect(host.calls('commands/execute').map((a) => a['line']), ['/permission read-only', '/permission read-only']);
    expect(again.controllers['fresh']!.sent, ['你好']);
    expect(_container(tester).read(owedSetupsProvider), isEmpty, reason: 'settled once the Host confirmed it');
  });

  testWidgets('a Host whose default is the hidden companion preset gets the offered default', (tester) async {
    final host = _Host(companionDefault: true);
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    expect(find.text('标准模式'), findsOneWidget);

    await _send(tester, '你好');
    expect(host.calls('agentPresets/select'), [
      {'agentId': 'fresh', 'agentPreset': 'standard'},
    ], reason: 'what the chip shows, not the hidden preset');
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  testWidgets('a pick the Host no longer offers falls back to the default it shows', (tester) async {
    final host = _Host()..presets.add({'id': 'ptc'});
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    await _pick(tester, '标准模式', '极简模式');
    host.presets = [
      for (final preset in host.presets)
        if (preset['id'] != 'minimal') preset,
    ];
    _container(tester).invalidate(agentPresetsProvider);
    await pumpFrames(tester, 6);
    expect(find.text('标准模式'), findsOneWidget);

    await _send(tester, '你好');
    expect(host.calls('agentPresets/select'), isEmpty);
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  testWidgets('the model is picked from the header before typing and goes with the first message', (tester) async {
    final host = _Host();
    final harness = ChatHarness(created: 'fresh', newChatCatalogs: true);
    await _pump(tester, harness, host);
    // On a phone too: the new chat's header has room for the model chip.
    expect(find.byType(ModelChip), findsOneWidget);
    expect(find.byKey(const ValueKey('new-chat-model')), findsNothing);

    await tester.tap(find.byType(ModelChip));
    await pumpFrames(tester, 6);
    expect(find.text('选择模型'), findsOneWidget);
    await tester.tap(find.text('V41 Flash'));
    await pumpFrames(tester, 2);
    expect(_container(tester).read(pendingModelProvider)?.model, 'deepseek-flash');
    await tester.tapAt(const Offset(20, 120)); // dismiss the sheet
    await pumpFrames(tester, 4);
    expect(find.descendant(of: find.byType(ModelChip), matching: find.textContaining('V41 Flash')), findsOneWidget);

    await _send(tester, '你好');
    expect(harness.controllers['fresh']!.models.single.model, 'deepseek-flash');
    expect(harness.controllers['fresh']!.sent, ['你好']);
  });

  test('what a new session gets: the pick while offered, the offered default over a hidden one', () {
    const standard = AgentPresetInfo(id: 'standard', isDefault: true);
    const minimal = AgentPresetInfo(id: 'minimal');
    const companion = AgentPresetInfo(id: 'dsh-go-companion-full', isDefault: true);
    const broken = AgentPresetInfo(id: 'broken', broken: 'missing');
    expect(newChatPresetToApply([standard, minimal], null), isNull);
    expect(newChatPresetToApply([standard, minimal], 'minimal'), 'minimal');
    expect(newChatPresetToApply([standard, minimal], 'gone'), isNull);
    expect(newChatPresetToApply([standard, broken], 'broken'), isNull);
    expect(newChatPresetToApply(null, 'minimal'), 'minimal', reason: 'nothing known to check against');
    expect(newChatPresetToApply([const AgentPresetInfo(id: 'standard'), minimal, companion], null), 'standard');

    const state = PermissionState(
      options: [PermissionOption('read-only', 'Read only')],
      hostDefault: 'workspace-write',
    );
    expect(newChatPermissionToApply(state, 'read-only'), 'read-only');
    expect(newChatPermissionToApply(state, 'gone'), isNull);
    expect(newChatPermissionToApply(state, null), isNull);
    expect(newChatPermissionToApply(null, 'read-only'), 'read-only');
  });

  test('defaults: the marked preset, else the first; full access only where creation switches to it', () {
    const a = AgentPresetInfo(id: 'a');
    const b = AgentPresetInfo(id: 'b', isDefault: true);
    expect(defaultPreset([a, b])?.id, 'b');
    expect(defaultPreset([a])?.id, 'a');
    expect(defaultPreset(const []), isNull);
    expect(
      newChatPresets([
        a,
        const AgentPresetInfo(id: 'dsh-go-companion-full'),
        const AgentPresetInfo(id: 'dsh-go-diagnostics'),
      ]).map((p) => p.id),
      ['a'],
    );

    const state = PermissionState(options: [], hostDefault: 'workspace-write');
    String effective({bool local = true, bool autoApprove = true, bool safeMode = false}) =>
        effectiveNewChatPermission(state, local: local, autoApprove: autoApprove, safeMode: safeMode);
    expect(effective(), 'danger-full-access');
    expect(effective(autoApprove: false), 'workspace-write');
    expect(effective(safeMode: true), 'workspace-write');
    expect(effective(local: false), 'workspace-write');
  });
}

const _flash = ModelSelection(provider: 'deepseek-official', model: 'deepseek-flash');
