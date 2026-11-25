import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart' show dshUiPlainText;
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/share/share_panel.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

// ---------------------------------------------------------------------------
// A scripted Host: unary calls through a carrier, events through watch().

class _Carrier extends DshCarrier {
  final Map<String, RpcResult Function(Map<String, Object?> request)> handlers = {};
  final calls = <(String, Map<String, Object?>)>[];

  @override
  String get kind => 'memory';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final request = (args['request'] as Map).cast<String, Object?>();
    calls.add((endpoint, request));
    return handlers[endpoint]?.call(request) ?? const RpcError(DshRemoteException('gateway/not-found', 'missing'));
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnsupportedError('watch() is scripted');

  @override
  Future<void> close() async {}

  List<String> get endpoints => [for (final (e, _) in calls) e];
  Map<String, Object?> last(String endpoint) => calls.lastWhere((c) => c.$1 == endpoint).$2;
}

class _Client extends DshClient {
  _Client(this.host) : super.withCarrier(host);

  final _Carrier host;
  final events = StreamController<DshEvent>.broadcast();

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;
}

Map<String, Object?> _wire(int seq, String type, [Map<String, Object?> data = const {}]) => {
  'seq': seq,
  'time': 1760000000000 + seq,
  'type': type,
  'data': data,
};

Map<String, Object?> _prompt(int seq, String text) => _wire(seq, 'user/message', {
  'id': 'u$seq',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': 'r$seq'},
});

Map<String, Object?> _reply(int seq, String text, {int turn = 1}) => _wire(seq, 'assistant/message', {
  'turn': turn,
  'step': 1,
  'message': {
    'id': 'm$seq',
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'assistant'},
  },
});

/// Two finished turns as DSH 0.2.1 writes them.
final _log = [
  _wire(0, 'permission/preset'),
  _wire(1, 'sandbox/mode'),
  _wire(2, 'approval/policy'),
  _wire(3, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0}),
  _wire(4, 'turn/start', {'turn': 1}),
  _wire(5, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'removedCount': 1}),
  _wire(6, 'step/start', {'turn': 1, 'step': 1}),
  _wire(7, 'system/message', {'turn': 1, 'step': 1}),
  _prompt(8, '第一个问题'),
  _wire(9, 'session/title', {'title': '测试标题'}),
  _reply(10, '第一个回答'),
  _wire(11, 'step/end', {'turn': 1, 'step': 1}),
  _wire(12, 'turn/end', {
    'turn': 1,
    'reason': {'kind': 'completed'},
  }),
  _wire(13, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0}),
  _wire(14, 'turn/start', {'turn': 2}),
  _wire(15, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'removedCount': 1}),
  _wire(16, 'step/start', {'turn': 2, 'step': 1}),
  _prompt(17, '第二个问题'),
  _reply(18, '第二个回答', turn: 2),
  _wire(19, 'step/end', {'turn': 2, 'step': 1}),
  _wire(20, 'turn/end', {
    'turn': 2,
    'reason': {'kind': 'completed'},
  }),
];

// ---------------------------------------------------------------------------
// Widget helpers.

UserChatItem _user(int seq, String text) =>
    UserChatItem(seq: seq, time: DateTime(2026, 10, 23, 9), text: text, images: const [], files: const []);

AssistantChatItem _assistant(int seq, String text) =>
    AssistantChatItem(id: 'a$seq', seq: seq, time: DateTime(2026, 10, 23, 9), text: text, reasoning: '');

ChatState _conversation() =>
    ChatState(items: [_user(1, '帮我看看测试为什么失败'), _assistant(2, '是**超时重试**多发了一次请求。')], title: '测试失败', loading: false);

Future<void> _pump(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

List<String> _composerTexts(WidgetTester tester) => [
  for (final field in tester.widgetList<TextField>(find.byType(TextField))) field.controller?.text ?? '',
];

/// Records what reaches the clipboard and the share sheet.
({List<String> copied, List<String> shared}) _platform(WidgetTester tester) {
  final copied = <String>[];
  final shared = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/share'), (call) async {
    shared.add((call.arguments as Map)['text'] as String);
    return 'dev.fluttercommunity.plus/share/unavailable';
  });
  return (copied: copied, shared: shared);
}

void main() {
  setUpAll(loadTestFonts);

  group('ChatController message actions', () {
    late _Carrier carrier;
    late _Client client;
    late ProviderContainer container;

    ChatController chat() => container.read(chatProvider('s1').notifier);
    ChatState state() => container.read(chatProvider('s1'));
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

    Future<void> play(Iterable<Map<String, Object?>> wire) async {
      for (final event in wire) {
        client.events.add(SessionLogEvent.fromJson(event));
      }
      await settle();
    }

    AssistantChatItem reply(int seq) => state().items.whereType<AssistantChatItem>().firstWhere((i) => i.seq == seq);
    UserChatItem prompt(int seq) => state().items.whereType<UserChatItem>().firstWhere((i) => i.seq == seq);

    setUp(() async {
      carrier = _Carrier()
        ..handlers['session/fork'] = ((_) => const RpcOk({'sessionId': 'fork'}))
        ..handlers['session/projections'] = ((_) => const RpcOk({
          'asOfSeq': 20,
          'values': {
            'title': '测试标题',
            'inbox': {'next-turn': <Object?>[], 'next-step': <Object?>[]},
          },
        }))
        ..handlers['session/rename'] = ((r) => RpcOk({'title': r['title'], 'seq': 30}));
      client = _Client(carrier);
      container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
          ),
        ],
      );
      container.listen(chatProvider('s1'), (_, _) {});
      // Production watch() begins with a baseline before admitting actions.
      // Model the same G54 contract in this scripted transport.
      client.events.add(
        SessionSnapshotEvent.fromJson('s1', {
          'header': {'id': 's1'},
          'cursor': -1,
          'records': <Object?>[],
          'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
        }),
      );
      await container.pump();
      expect(state().controlReady, isTrue);
    });

    tearDown(() async {
      container.dispose();
      await client.events.close();
    });

    test('branch from the last reply of a turn, numbered title', () async {
      await play(_log);
      expect(chat().branchPointAfter(reply(10)), 12);
      expect(chat().branchPointAfter(reply(18)), 20);
      expect(chat().replyMessageId(reply(18)), 'm18');

      final outcome = await chat().branchAfter(reply(10));
      expect(outcome?.sessionId, 'fork');
      expect(carrier.last('session/fork'), {'sessionId': 's1', 'atSeq': 12});
      expect(carrier.last('session/rename'), {'sessionId': 'fork', 'title': '测试标题 (1)'});
      expect(state().error, isNull);
    });

    test('edit and resend forks just before the prompt', () async {
      await play(_log);
      final outcome = await chat().forkBeforePrompt(prompt(17));
      expect(outcome?.sessionId, 'fork');
      expect(carrier.last('session/fork'), {'sessionId': 's1', 'atSeq': 12});
      // The first prompt keeps only the opening settings.
      await chat().forkBeforePrompt(prompt(8));
      expect(carrier.last('session/fork'), {'sessionId': 's1', 'atSeq': 2});
    });

    test('a prompt at the top of the loaded window reads what came before', () async {
      carrier.handlers['session/page'] = (_) => RpcOk({
        'records': [
          for (final e in _log.where((e) => (e['seq'] as int) <= 16)) {'event': e},
        ],
        'hasMore': false,
      });
      await play(_log.where((e) => (e['seq'] as int) >= 14));
      await chat().forkBeforePrompt(prompt(17));
      expect(carrier.last('session/page')['throughSeq'], 16);
      expect(carrier.last('session/fork'), {'sessionId': 's1', 'atSeq': 12});
    });

    test('refusals land in the error banner', () async {
      await play(_log.where((e) => (e['seq'] as int) <= 18));
      // The turn has not ended yet: nothing to branch from.
      expect(chat().branchPointAfter(reply(18)), isNull);
      expect(await chat().branchAfter(reply(18)), isNull);
      expect(state().error, contains('已完成'));
      expect(carrier.endpoints, isNot(contains('session/fork')));

      carrier.handlers['session/fork'] = (_) =>
          const RpcError(DshRemoteException('session/fork-unavailable', 'event 2 is gone'));
      expect(await chat().forkBeforePrompt(prompt(8)), isNull);
      expect(state().error, '分叉失败：这里不能分叉');
    });

  });

  group('reply actions', () {
    testWidgets('the row: copy, and branch when DSH allows; no rating', (tester) async {
      final platform = _platform(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
      await _pump(tester, harness);
      // Not branchable (the fake reports nothing): copy only.
      expect(find.byTooltip('复制'), findsOneWidget);
      expect(find.byTooltip('从这里分叉'), findsNothing);

      final chat = harness.controllers['s1']!;
      chat.branchPoints[2] = 7;
      chat.replyIds[2] = 'm2';
      chat.emit(_conversation());
      await pumpFrames(tester);
      expect(find.byTooltip('从这里分叉'), findsOneWidget);
      // A stored reply id no longer brings 👍 / 👎.
      expect(find.byTooltip('好的回答'), findsNothing);
      expect(find.byTooltip('有问题的回答'), findsNothing);

      await tester.tap(find.byTooltip('复制'));
      await pumpFrames(tester, 2);
      expect(platform.copied, ['是**超时重试**多发了一次请求。']);

      await tester.tap(find.byTooltip('从这里分叉'));
      await pumpFrames(tester);
      expect(chat.branched, [2]);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(currentSessionProvider), 'fork-session');
      expect(find.text('已在新对话中继续'), findsOneWidget);
      await tester.tap(find.text('返回原对话'));
      await pumpFrames(tester);
      expect(container.read(currentSessionProvider), 's1');
    });

    testWidgets('copy carries a visual reply as its plain summary', (tester) async {
      final platform = _platform(tester);
      const reply = '先看这个：\n\n```dsh-ui\n{"type": "text", "text": "第一行"}\n```\n\n就这样。';
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(items: [_user(1, '画给我看'), _assistant(2, reply)], loading: false),
        },
      );
      await _pump(tester, harness);
      await tester.tap(find.byTooltip('复制'));
      await pumpFrames(tester, 2);
      expect(platform.copied, [dshUiPlainText(reply)]);
      expect(platform.copied.single, isNot(contains('{')));
      // The key shows 「已复制」 for a moment.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('long-press menu: copy, select text, share, branch', (tester) async {
      final platform = _platform(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
      await _pump(tester, harness);
      harness.controllers['s1']!.branchPoints[2] = 7;
      harness.controllers['s1']!.emit(_conversation());
      await pumpFrames(tester);

      Future<void> menu() async {
        await tester.longPress(find.textContaining('多发了一次请求', findRichText: true).first);
        await pumpFrames(tester);
        await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
        await pumpFrames(tester);
      }

      await menu();
      for (final label in ['复制', '选择文字', '分享', '从这里分叉']) {
        expect(find.widgetWithText(SettingsTile, label), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(SettingsTile, '复制'));
      await pumpFrames(tester);
      expect(platform.copied, ['是**超时重试**多发了一次请求。']);
      expect(find.text('已复制'), findsOneWidget);

      // 分享: the share panel at this reply (its 文字 sends what the old
      // menu item did).
      await menu();
      await tester.tap(find.widgetWithText(SettingsTile, '分享'));
      await pumpFrames(tester);
      expect(find.byType(SharePanel), findsOneWidget);
      expect(tester.widget<SegmentedPill<ShareScope>>(find.byType(SegmentedPill<ShareScope>)).selected, ShareScope.reply);
      expect(platform.shared, isEmpty);
      Navigator.of(tester.element(find.byType(SharePanel))).pop();
      await pumpFrames(tester);

      await menu();
      await tester.tap(find.widgetWithText(SettingsTile, '选择文字'));
      await pumpFrames(tester);
      expect(find.text('全部复制'), findsOneWidget);
      final sheet = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SelectTextSheet');
      expect(find.descendant(of: sheet, matching: find.byType(SelectionArea)), findsOneWidget);
    });

  });

  group('prompt actions', () {
    testWidgets('long press offers edit and resend directly, with the original draft preserved', (tester) async {
      _platform(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
      await _pump(tester, harness);
      await tester.enterText(find.byType(TextField), '原对话草稿');
      await tester.longPress(find.text('帮我看看测试为什么失败'));
      await pumpFrames(tester);
      final edit = find.widgetWithText(TextSelectionToolbarTextButton, '编辑后重发').hitTestable();
      expect(edit, findsOneWidget);
      await tester.tap(edit);
      await pumpFrames(tester);

      expect(harness.controllers['s1']!.edited, [1]);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(currentSessionProvider), 'fork-session');
      expect(container.read(draftStoreProvider).drafts['s1']!.text, '原对话草稿');
      expect(_composerTexts(tester), contains('帮我看看测试为什么失败'));
      expect(harness.controllers['fork-session']!.sent, isEmpty);
      expect(find.text('已在新对话中打开'), findsOneWidget);
    });

    testWidgets('a failed fork stays put', (tester) async {
      _platform(tester);
      final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
      await _pump(tester, harness);
      harness.controllers['s1']!.forkOutcome = null;
      await tester.longPress(find.text('帮我看看测试为什么失败'));
      await pumpFrames(tester);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      for (final label in ['复制', '选择文字', '编辑后重发']) {
        expect(find.widgetWithText(SettingsTile, label), findsOneWidget);
      }
      expect(find.widgetWithText(SettingsTile, '分享'), findsNothing);
      await tester.tap(find.widgetWithText(SettingsTile, '编辑后重发'));
      await pumpFrames(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      expect(container.read(currentSessionProvider), 's1');
      expect(_composerTexts(tester), isNot(contains('帮我看看测试为什么失败')));
    });

    testWidgets('a queued message offers copy and select only', (tester) async {
      final platform = _platform(tester);
      final harness = ChatHarness(
        session: 's1',
        states: {
          's1': ChatState(
            loading: false,
            running: true,
            pending: [
              PendingPrompt(requestId: 'r1', text: '再看看依赖', time: DateTime(2026, 10, 23, 9), mode: SendMode.queue),
            ],
          ),
        },
      );
      await _pump(tester, harness);
      await tester.longPress(find.text('再看看依赖'));
      await pumpFrames(tester);
      expect(find.widgetWithText(TextSelectionToolbarTextButton, '编辑后重发'), findsNothing);
      await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
      await pumpFrames(tester);
      expect(find.widgetWithText(SettingsTile, '编辑后重发'), findsNothing);
      await tester.tap(find.widgetWithText(SettingsTile, '复制'));
      await pumpFrames(tester);
      expect(platform.copied, ['再看看依赖']);
    });
  });
}
