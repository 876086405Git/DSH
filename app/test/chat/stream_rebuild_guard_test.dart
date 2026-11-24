// Work-count guard for streaming: while a reply or a tool call's arguments
// stream in, only the row being written may rebuild, and the row model is not
// derived again per delta. Transport is the only fake: the transcript, the
// controller and the list are real. Counts, not frame times.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/media/media_paths.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart' show debugToolSummaryCaches;
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/stream_row.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/pending_notice_harness.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;
}

const _session = 's';
const _deltas = 20;

/// Three finished turns (each a prompt, a tool call and an answer), then a
/// running fourth turn that has already finished one tool call.
List<Map<String, Object?>> _history() {
  final log = <Map<String, Object?>>[];
  var time = DateTime(2026, 11, 10, 9).millisecondsSinceEpoch;
  void ev(String type, Map<String, Object?> data) =>
      log.add({'type': type, 'seq': log.length + 1, 'time': time += 1000, 'data': data});
  void prompt(String text) => ev('user/message', {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'user'},
  });
  void step(int turn, int step, {String text = '', String? call}) {
    ev('assistant/message', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'reasoning', 'text': '想一想第 $step 步'},
          if (text.isNotEmpty) {'type': 'text', 'text': text},
          if (call != null)
            {
              'type': 'tool-call',
              'id': call,
              'name': 'bash',
              'arguments': jsonEncode({'command': 'echo $call'}),
            },
        ],
        'source': {'kind': 'llm', 'model': 'deepseek-flash'},
      },
    });
    if (call == null) return;
    ev('tool/call', {
      'turn': turn,
      'step': step,
      'callId': call,
      'name': 'bash',
      'arguments': jsonEncode({'command': 'echo $call'}),
    });
    ev('tool/result', {
      'turn': turn,
      'step': step,
      'message': {
        'role': 'tool',
        'toolCallId': call,
        'content': [
          {'type': 'text', 'text': call},
        ],
      },
    });
  }

  for (var turn = 1; turn <= 3; turn++) {
    ev('turn/start', {'turn': turn});
    prompt('第 $turn 个问题');
    step(turn, 1, call: 'c$turn');
    step(turn, 2, text: '**第 $turn 个回答**\n\n- 一\n- 二\n\n`code` 和一段正文。');
    ev('turn/end', {
      'turn': turn,
      'reason': {'kind': 'completed'},
    });
  }
  ev('turn/start', {'turn': 4});
  prompt('第 4 个问题');
  step(4, 1, call: 'c4');
  return log;
}

class _Guard {
  _Guard({List<ProviderObserver> observers = const []}) {
    container = ProviderContainer(
      observers: observers,
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
        settingsProvider.overrideWith(TestSettings.new),
        sessionArtifactsProvider(_session).overrideWithValue(const []),
      ],
    );
    container.listen(chatProvider(_session), (_, _) {});
  }

  final client = _Client();
  late final ProviderContainer container;
  final history = _history();
  late final int seq = history.length;
  final time = DateTime(2026, 11, 10, 10);
  var _index = 0;

  ChatState get state => container.read(chatProvider(_session));

  /// The history, with [queued] waiting in the inbox for the next turn.
  void snapshot({List<String> queued = const []}) {
    client.events.add(
      parseFollowFrame(_session, {
        'type': 'snapshot',
        'header': {'id': _session, 'createdAt': 1792700000000},
        'cursor': seq,
        'records': [
          for (final event in history) {'type': 'event', 'event': event},
        ],
        'hasMore': false,
        'projections': {
          'asOfSeq': seq,
          'values': {
            'inbox': {
              'next-turn': [
                for (final (i, text) in queued.indexed)
                  {
                    'id': 'inbox-$i',
                    'role': 'user',
                    'content': [
                      {'type': 'text', 'text': text},
                    ],
                    'source': {'kind': 'user'},
                  },
              ],
              'next-step': <Object?>[],
            },
          },
        },
      }),
    );
    client.events.add(const SessionStatusEvent(_session, true));
  }

  void startStream() => client.events.add(AssistantStreamStarted('attempt', 0, turn: 4, step: 2, startedAfterSeq: seq));

  var _logged = 0;

  /// A durable event after the history.
  void log(String type, Map<String, Object?> data) {
    final at = seq + ++_logged;
    client.events.add(
      parseFollowFrame(_session, {
        'type': 'event',
        'event': {'seq': at, 'time': 1792700000000 + at, 'type': type, 'data': data},
      }),
    );
  }

  void chunk(StreamChunk chunk) =>
      client.events.add(AssistantChunkEvent('attempt', 0, index: _index++, time: time, chunk: chunk));

  Future<void> mount(WidgetTester tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          home: const Scaffold(body: ChatList(sessionId: _session, topInset: 0, bottomInset: 0)),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Unmounts and disposes before the test ends: the controller's timers
  /// go with the container.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    dispose();
    await tester.pump(const Duration(seconds: 1));
  }

  var _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    unawaited(client.events.close());
  }
}

final class _MediaPathsObserver extends ProviderObserver {
  var builds = 0;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (context.provider == sessionMediaPathsProvider(_session)) builds++;
  }

  @override
  void didUpdateProvider(ProviderObserverContext context, Object? previousValue, Object? newValue) {
    if (context.provider == sessionMediaPathsProvider(_session)) builds++;
  }
}

/// Builds of row widgets during [body], split into the row being written
/// (a streaming reply or tool call) and every other row.
Future<({int done, int live, int derivations})> _count(Future<void> Function() body) async {
  var done = 0;
  var live = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previous?.call(element, builtOnce);
    switch (element.widget) {
      case AssistantMessage(:final item) when item.streaming:
        live++;
      case ToolRow(:final item) when item.status == ToolStatus.streaming:
        live++;
      case ToolGroup(:final tools) when tools.any((tool) => tool.status == ToolStatus.streaming):
        live++;
      case AssistantMessage() || ToolRow() || ToolGroup() || UserBubble() || TurnProcess() || NoticeRow():
        done++;
    }
  };
  final derived = debugDeriveRowsCount;
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return (done: done, live: live, derivations: debugDeriveRowsCount - derived);
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('metadata publishes retain the unchanged live transcript', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '回答'));
    g.chunk(const ToolCallDeltaChunk(1, id: 'live-call', name: 'bash', argumentsDelta: '{'));
    await g.settle(tester);
    expect(
      g.container.exists(sessionsProvider),
      isFalse,
      reason: 'image scope metadata must not start the sessions watcher',
    );
    final items = g.state.items;
    final status = await _count(() async {
      g.client.events.add(const SessionStatusEvent(_session, true));
      await g.settle(tester);
    });
    final title = await _count(() async {
      g.log('session/title', {'title': '新的标题'});
      await g.settle(tester);
    });
    debugPrint('[GUARD] unchanged draft metadata: status=$status title=$title');
    expect(status.done, 0, reason: 'an unchanged live projection must not rebuild historical rows');
    expect(status.derivations, 0);
    expect(g.state.title, '新的标题');
    expect(g.state.items, same(items));
    expect(tester.takeException(), isNull);
    g.chunk(const TextDeltaChunk(0, '继续'));
    await g.settle(tester);
    expect(g.state.items.whereType<AssistantChatItem>().last.text, '回答继续');
    expect(items.whereType<AssistantChatItem>().last.text, '回答');
    await g.unmount(tester);
  });

  Future<void> streamText(WidgetTester tester, {List<String> queued = const []}) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot(queued: queued);
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);
    expect(g.state.pending, hasLength(queued.length));
    expect(find.byType(UserBubble), findsWidgets);

    final counts = await _count(() async {
      for (var delta = 0; delta < _deltas; delta++) {
        g.chunk(TextDeltaChunk(0, ' 第$delta段'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    });
    expect(tester.takeException(), isNull);
    final draft = g.state.items.whereType<AssistantChatItem>().last;
    expect(draft.streaming, isTrue);
    expect(draft.text, contains('第${_deltas - 1}段'));
    debugPrint(
      '[GUARD] text stream, queued=${queued.length}, deltas=$_deltas: '
      'finished-row builds=${counts.done} live-row builds=${counts.live} deriveRows=${counts.derivations}',
    );
    expect(counts.live, greaterThan(0), reason: 'the reply being written rebuilds');
    expect(counts.done, 0, reason: 'finished rows must not rebuild while a reply streams');
    expect(counts.derivations, 0, reason: 'a text delta must not derive the rows again');
    await g.unmount(tester);
  }

  testWidgets('a streaming reply rebuilds only its own row', (tester) async {
    await streamText(tester);
  });

  testWidgets('a streaming reply with queued messages derives no rows per delta', (tester) async {
    await streamText(tester, queued: ['排队一', '排队二']);
  });

  testWidgets('text deltas leave the jump button alone', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);

    // The Positioned that owns the floating button stays in both trees.
    final overlay = tester.element(find.ancestor(of: find.byType(PetAvoid), matching: find.byType(Positioned)).first);
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      element.visitAncestorElements((ancestor) {
        if (ancestor != overlay) return true;
        builds++;
        return false;
      });
    };
    try {
      for (var i = 0; i < _deltas; i++) {
        g.chunk(const TextDeltaChunk(0, '字'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect(g.state.items.whereType<AssistantChatItem>().last.text, '开始${'字' * _deltas}');
    debugPrint('[GUARD] jump button builds=$builds for $_deltas text deltas');
    expect(builds, 0);
    await g.unmount(tester);
  });

  testWidgets('text deltas reuse the unchanged reasoning control', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const ReasoningDeltaChunk(0, '思考'));
    await g.settle(tester);
    final row = find.byWidgetPredicate((w) => w is AssistantMessage && w.item.streaming);
    final pill = find.descendant(of: row, matching: find.byType(ThinkingPill));
    expect(tester.widget<ThinkingPill>(pill).active, isTrue);

    g.chunk(const BlockStartChunk(1, 'text'));
    g.chunk(const TextDeltaChunk(1, '答'));
    await g.settle(tester);
    final stable = tester.widget<ThinkingPill>(pill);
    expect(stable.active, isFalse);
    for (var i = 0; i < 3; i++) {
      g.chunk(const TextDeltaChunk(1, '字'));
      await tester.pump(const Duration(milliseconds: 32));
      expect(tester.widget<ThinkingPill>(pill), same(stable));
    }
    expect(g.state.items.whereType<AssistantChatItem>().last.text, '答字字字');
    await g.unmount(tester);
  });

  testWidgets('plain streaming replies do not build the media path projection', (tester) async {
    final media = _MediaPathsObserver();
    final g = _Guard(observers: [media]);
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);
    final initialMediaBuilds = media.builds;
    media.builds = 0;
    final counts = await _count(() async {
      for (var delta = 0; delta < _deltas; delta++) {
        g.chunk(TextDeltaChunk(0, ' 第$delta段'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    });
    debugPrint(
      '[GUARD] plain text, deltas=$_deltas: '
      'initial media builds=$initialMediaBuilds streaming media builds=${media.builds} live=${counts.live}',
    );
    expect(counts.live, greaterThan(0));
    expect(initialMediaBuilds, 0);
    expect(media.builds, 0, reason: 'observe without keeping the auto-disposed projection alive');
    // A literal image marker exercises the observer without loading an image.
    g.chunk(const TextDeltaChunk(0, ' 这里有 ![未闭合'));
    await g.settle(tester);
    expect(media.builds, greaterThan(0));
    expect(tester.takeException(), isNull);
    await g.unmount(tester);
  });

  testWidgets('text deltas leave the historical sliver in place until its rows change', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);

    final history = find.byType(SliverList).first;
    final element = tester.element(history);
    expect(find.descendant(of: history, matching: find.byType(TurnProcess)), findsWidgets);
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (child, builtOnce) {
      previous?.call(child, builtOnce);
      child.visitAncestorElements((ancestor) {
        if (ancestor != element) return true;
        builds++;
        return false;
      });
    };
    try {
      for (var i = 0; i < _deltas; i++) {
        g.chunk(const TextDeltaChunk(0, '字'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect(g.state.items.whereType<AssistantChatItem>().last.text, '开始${'字' * _deltas}');
    expect(builds, 0);

    SharedPreferences.setMockInitialValues({});
    await g.container.read(settingsProvider.notifier).setFoldCompletedTurns(false);
    await g.settle(tester);
    expect(find.descendant(of: history, matching: find.byType(TurnProcess)), findsNothing);
    expect(find.descendant(of: history, matching: find.byType(ToolRow)), findsWidgets);
    await g.unmount(tester);
  });

  testWidgets('publishing text keeps the completed tool’s forward sliver child', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);

    final forward = tester.element(find.byType(SliverList).last);
    Element forwardChild(Finder finder) {
      var child = tester.element(finder);
      var found = false;
      child.visitAncestorElements((parent) {
        if (parent == forward) {
          found = true;
          return false;
        }
        child = parent;
        return true;
      });
      expect(found, isTrue);
      return child;
    }

    final tool = find.byWidgetPredicate((w) => w is ToolRow && w.item.callId == 'c4');
    final completed = forwardChild(tool);
    final active = forwardChild(find.byWidgetPredicate((w) => w is AssistantMessage && w.item.streaming));
    final fixed = completed.widget;
    var previous = active.widget;
    for (var i = 0; i < _deltas; i++) {
      g.chunk(const TextDeltaChunk(0, '字'));
      await tester.pump(const Duration(milliseconds: 32));
      expect(forwardChild(tool), same(completed));
      expect(completed.widget, same(fixed));
      expect(active.widget, isNot(same(previous)));
      previous = active.widget;
    }
    expect(g.state.items.whereType<AssistantChatItem>().last.text, '开始${'字' * _deltas}');
    await g.unmount(tester);
  });

  testWidgets('streaming tool arguments rebuild only the tool being written', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot(queued: ['排队一']);
    await g.settle(tester);
    g.startStream();
    g.chunk(const ReasoningDeltaChunk(0, '要先看一下目录'));
    g.chunk(const BlockStartChunk(1, 'tool-call'));
    g.chunk(const ToolCallDeltaChunk(1, id: 'c5', name: 'bash', argumentsDelta: '{"command": "ls'));
    await g.settle(tester);
    expect(g.state.items.last, isA<ToolChatItem>().having((t) => t.status, 'status', ToolStatus.streaming));

    final counts = await _count(() async {
      for (var delta = 0; delta < _deltas; delta++) {
        g.chunk(ToolCallDeltaChunk(1, id: 'c5', argumentsDelta: ' dir$delta'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    });
    expect(tester.takeException(), isNull);
    expect((g.state.items.last as ToolChatItem).arguments, endsWith('dir${_deltas - 1}'));
    debugPrint(
      '[GUARD] tool arguments stream, deltas=$_deltas: '
      'finished-row builds=${counts.done} live-row builds=${counts.live} deriveRows=${counts.derivations}',
    );
    expect(counts.live, greaterThan(0), reason: 'the tool call being written rebuilds');
    expect(counts.done, 0, reason: 'finished rows must not rebuild while tool arguments stream');
    expect(counts.derivations, 0, reason: 'an argument delta must not derive the rows again');
    await g.unmount(tester);
  });

  testWidgets('writing file content keeps the tool header until its displayed path changes', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const ReasoningDeltaChunk(0, '准备写文件'));
    g.chunk(const BlockStartChunk(1, 'tool-call'));
    g.chunk(const ToolCallDeltaChunk(1, id: 'c5', name: 'write', argumentsDelta: '{"path":"a.dart","content":"'));
    await g.settle(tester);

    final row = find.byWidgetPredicate((w) => w is ToolRow && w.item.callId == 'c5');
    final frame = find.descendant(of: row, matching: find.byType(StreamRowFrame));
    final element = tester.element(frame);
    expect(find.descendant(of: frame, matching: find.text('a.dart')), findsOneWidget);
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (e, builtOnce) {
      previous?.call(e, builtOnce);
      if (e == element) builds++;
    };
    try {
      for (var i = 0; i < _deltas; i++) {
        g.chunk(ToolCallDeltaChunk(1, id: 'c5', argumentsDelta: 'final x$i = $i;'));
        await tester.pump(const Duration(milliseconds: 32));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect((g.state.items.last as ToolChatItem).arguments, endsWith('final x19 = 19;'));
    expect(tester.element(frame), same(element));
    expect(builds, 0);
    g.chunk(const ToolCallDeltaChunk(1, id: 'c5', argumentsDelta: '","file_path":"b.dart"}'));
    await tester.pump(const Duration(milliseconds: 32));
    expect(find.descendant(of: frame, matching: find.text('b.dart')), findsOneWidget);
    await g.unmount(tester);
  });

  testWidgets('what the log decides is not worked out again per delta', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    final media = <Set<String>>[];
    final modes = <SessionModes>[];
    // A new set each time it is worked out: every recompute reaches the listener.
    g.container.listen(sessionMediaPathsProvider(_session), (_, next) => media.add(next), fireImmediately: true);
    g.container.listen(sessionModesProvider(_session), (_, next) => modes.add(next), fireImmediately: true);
    g.snapshot();
    await g.settle(tester);
    g.startStream();
    g.chunk(const TextDeltaChunk(0, '开始'));
    await g.settle(tester);
    media.clear();
    modes.clear();
    for (var delta = 0; delta < _deltas; delta++) {
      g.chunk(TextDeltaChunk(0, ' 第$delta段'));
      await tester.pump(const Duration(milliseconds: 32));
    }
    debugPrint('[GUARD] text stream, deltas=$_deltas: media paths worked out ${media.length} times');
    expect(media, isEmpty, reason: 'media comes with a result, a log event');
    // The log still moves them.
    g.log('permission/preset', {'preset': 'danger-full-access'});
    await tester.pump(const Duration(milliseconds: 40));
    expect(modes.map((m) => m.preset), ['danger-full-access']);
    expect(media, hasLength(1));
    g.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a closed chat takes its calls out of the tool summary caches', (tester) async {
    final g = _Guard();
    addTearDown(g.dispose);
    final before = debugToolSummaryCaches;
    await g.mount(tester);
    g.snapshot();
    await g.settle(tester);
    expect(debugToolSummaryCaches.turns, greaterThan(before.turns), reason: 'finished turns were summarised');
    await g.unmount(tester);
    expect(debugToolSummaryCaches, before);
  });

  testWidgets('a language switch reaches the kept rows', (tester) async {
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot([
      pendingMessage(text: '排队的消息', source: {'kind': 'user'}),
    ], slot: 'next-turn');
    h.running(true);
    await h.settle(tester);
    expect(find.text('排队中 · 本轮结束后发送'), findsOneWidget);
    expect(find.text('立即发送'), findsOneWidget);
    expect(find.text('撤回'), findsOneWidget);

    // As app.dart does: switch, then rebuild every element (no inherited
    // change, and nothing in the chat changed).
    AppLocale.use(AppLocale.en);
    void mark(Element element) {
      element.markNeedsBuild();
      element.visitChildren(mark);
    }

    tester.binding.rootElement!.visitChildren(mark);
    await tester.pump();
    expect(find.text('Queued · Next turn'), findsOneWidget);
    expect(find.text('Send now'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);
  });
}
