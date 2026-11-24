// The whole-turn fold when a turn and the user messages do not line up:
// a turn steered into while it ran (cut into pieces), several turns between
// two user messages (auto-triggered, goal rounds, job callbacks), retries,
// and the stopped / failed turns that stay open. Synthetic items with real
// seqs, plus one transcript built from DSH log events (turn/start before the
// opening user/message, the steer inside the same turn).

import 'dart:convert';

import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

final _t0 = DateTime(2026, 10, 25, 9);

TurnTrace _trace(int startSeq, int endSeq, {String reason = 'completed'}) => TurnTrace(
  turn: startSeq,
  startSeq: startSeq,
  start: _t0,
  spans: const [],
  endSeq: endSeq,
  end: _t0.add(const Duration(seconds: 30)),
  endReason: TurnEndReason(reason),
);

TurnTrace _running(int startSeq) => TurnTrace(turn: startSeq, startSeq: startSeq, start: _t0, spans: const []);

/// A tool call of the assistant message at [seq] (what the transcript gives).
ToolChatItem _tool(int seq, String id, [String name = 'bash']) => ToolChatItem(
  callId: id,
  name: name,
  arguments: jsonEncode({'command': id}),
  status: ToolStatus.succeeded,
  seq: seq,
);

ToolChatItem _edit(int seq, String id, String path) => ToolChatItem(
  callId: id,
  name: 'edit',
  arguments: jsonEncode({'file_path': path, 'old_string': 'a', 'new_string': 'b'}),
  status: ToolStatus.succeeded,
  seq: seq,
);

List<Type> _types(List<ChatRow> rows) => [for (final r in rows) r.runtimeType];

/// Every tool call, wherever it sits (inside a fold or not).
List<String> _calls(List<ChatRow> rows) => [
  for (final row in rows)
    ...switch (row) {
      ToolCallRow(:final item) => [item.callId],
      ToolGroupRow(:final tools) => [for (final t in tools) t.callId],
      TurnProcessRow(:final rows) => _calls(rows),
      _ => const <String>[],
    },
];

void _expectSane(List<ChatRow> rows) {
  final keys = [for (final r in rows) r.key];
  expect(keys.toSet(), hasLength(keys.length), reason: 'row keys are unique');
  for (final fold in rows.whereType<TurnProcessRow>()) {
    expect(fold.rows.whereType<UserRow>(), isEmpty, reason: 'a user message is never folded away');
    var calls = 0;
    var messages = 0;
    for (final r in fold.rows) {
      switch (r) {
        case ToolCallRow():
          calls++;
        case ToolGroupRow(:final tools):
          calls += tools.length;
        case AssistantRow(:final item) when item.text.trim().isNotEmpty:
          messages++;
        default:
      }
    }
    expect(fold.toolCalls, calls, reason: 'the count matches what is inside');
    expect(fold.messages, messages);
  }
}

void main() {
  group('a turn steered into while it ran', () {
    // turn/start 0, the opening prompt 1, a steer at 6, turn/end 12.
    final steered = <ChatItem>[
      user(1, '这个 3D 模型怎么跑起来'),
      assistant(2, '', reasoning: '先搜一下'),
      _tool(2, 'search', 'web_search'),
      _tool(4, 'fetch', 'web_fetch'),
      user(6, '顺便看看它是什么模型'),
      assistant(7, '', reasoning: 'The user now asks: What is this 3D model'),
      _tool(7, 'run'),
      assistant(10, '是一个 glTF 模型。', reasoning: '整理一下'),
    ];

    test('each piece folds; the answer and the footnote stay out', () {
      final turn = _trace(0, 12);
      final rows = deriveRows(items: steered, turns: [turn], foldTurns: true);
      expect(_types(rows), [UserRow, TurnProcessRow, UserRow, TurnProcessRow, AssistantRow]);
      _expectSane(rows);

      final before = rows[1] as TurnProcessRow;
      expect(before.cut, 6);
      expect(before.key, 'tp0@6');
      expect(before.toolCalls, 2);
      expect(turnProcessLabel(before), '已完成 · 2 次工具调用');

      final last = rows[3] as TurnProcessRow;
      expect(last.cut, isNull);
      expect(last.key, 'tp0', reason: 'the key the list settles and opens by');
      expect(last.toolCalls, 1);
      // The answer's own thinking went inside.
      expect((last.rows.last as AssistantRow).item.reasoning, '整理一下');

      final answer = rows[4] as AssistantRow;
      expect(answer.item.text, '是一个 glTF 模型。');
      expect(answer.item.reasoning, isEmpty);
      expect(answer.showActions, isTrue);
      expect(answer.footnote, same(turn));
      expect(_calls(rows), ['search', 'fetch', 'run']);
    });

    test('three pieces: every piece before a steer folds on its own', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          _tool(2, 'a'),
          _tool(3, 'b'),
          user(4, '再加一个'),
          assistant(5, '', reasoning: '加上'),
          _tool(5, 'c'),
          user(7, '还有这个'),
          _tool(8, 'd'),
          _tool(9, 'e'),
          _tool(10, 'f'),
          assistant(12, '都好了'),
        ],
        turns: [_trace(0, 13)],
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, TurnProcessRow, UserRow, TurnProcessRow, UserRow, TurnProcessRow, AssistantRow]);
      _expectSane(rows);
      final folds = rows.whereType<TurnProcessRow>().toList();
      expect([for (final f in folds) f.key], ['tp0@4', 'tp0@7', 'tp0']);
      expect([for (final f in folds) f.toolCalls], [2, 1, 3]);
      expect(folds.last.rows.single, isA<ToolGroupRow>());
      expect(_calls(rows), ['a', 'b', 'c', 'd', 'e', 'f']);
      // One footnote for the turn, on its answer.
      expect(rows.whereType<AssistantRow>().map((r) => r.footnote), [isNotNull]);
    });

    test('what it said before the steer stays out; its process folds', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          assistant(2, '', reasoning: '先看看'),
          _tool(2, 'a'),
          assistant(4, '我先查一下文档。', reasoning: '要查文档'),
          user(5, '查官方的'),
          _tool(6, 'b'),
          assistant(8, '查到了。'),
        ],
        turns: [_trace(0, 9)],
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, TurnProcessRow, AssistantRow, UserRow, TurnProcessRow, AssistantRow]);
      _expectSane(rows);
      final before = rows[1] as TurnProcessRow;
      expect(before.key, 'tp0@5');
      expect(before.toolCalls, 1);
      expect(before.messages, 0, reason: 'the line kept outside is not inside');
      expect((before.rows.last as AssistantRow).item.reasoning, '要查文档');

      final said = rows[2] as AssistantRow;
      expect(said.item.text, '我先查一下文档。');
      expect(said.item.reasoning, isEmpty);
      expect(said.showActions, isTrue);
      expect(said.footnote, isNull, reason: 'the turn goes on after it');

      final answer = rows[5] as AssistantRow;
      expect(answer.footnote, isNotNull);
    });

    test('a reply followed by more work before the steer folds as well', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          assistant(2, '先跑一下测试。'),
          _tool(2, 'a'),
          user(4, '跑完告诉我'),
          _tool(5, 'b'),
          assistant(7, '跑完了。'),
        ],
        turns: [_trace(0, 8)],
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, TurnProcessRow, UserRow, TurnProcessRow, AssistantRow]);
      final before = rows[1] as TurnProcessRow;
      expect(before.messages, 1);
      expect(turnProcessLabel(before), '已完成 · 1 次工具调用 · 1 条消息');
      _expectSane(rows);
    });

    test('a piece that is only a short reply stays as it is', () {
      final rows = deriveRows(
        items: [user(1, 'q'), assistant(2, '好的，马上。'), user(3, '快点'), _tool(4, 'a'), _tool(5, 'b'), assistant(7, '好了')],
        turns: [_trace(0, 8)],
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, AssistantRow, UserRow, TurnProcessRow, AssistantRow]);
    });

    test('while it runs nothing folds; it folds once it completes', () {
      final live = deriveRows(items: steered.sublist(0, 7), turns: [_running(0)], running: true, foldTurns: true);
      expect(live.whereType<TurnProcessRow>(), isEmpty);
      expect(_calls(live), ['search', 'fetch', 'run']);

      final done = deriveRows(items: steered, turns: [_trace(0, 12)], foldTurns: true);
      expect(done.whereType<TurnProcessRow>(), hasLength(2));
    });

    for (final reason in ['aborted', 'error']) {
      test('an $reason turn stays open, steered or not', () {
        final rows = deriveRows(
          items: [
            ...steered,
            NoticeChatItem(seq: 12, kind: reason, text: reason),
          ],
          turns: [_trace(0, 12, reason: reason)],
          foldTurns: true,
        );
        expect(rows.whereType<TurnProcessRow>(), isEmpty);
        expect(_types(rows).where((t) => t == UserRow), hasLength(2));
      });
    }

    test('the change card covers the whole turn, after its answer', () {
      final rows = deriveRows(
        items: [
          user(1, 'q'),
          _edit(2, 'e1', '/w/a.txt'),
          user(4, '这个也改'),
          _edit(5, 'e2', '/w/b.txt'),
          assistant(7, '两个都改好了'),
        ],
        turns: [_trace(0, 8)],
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, TurnProcessRow, UserRow, TurnProcessRow, AssistantRow, ChangeCardRow]);
      expect((rows.last as ChangeCardRow).files, hasLength(2));
    });
  });

  group('several turns between two user messages', () {
    // The prompt opens turn 0..5; an auto-triggered turn 6..11 follows.
    final items = <ChatItem>[
      user(1, '跑一下'),
      assistant(2, '', reasoning: '先跑'),
      _edit(2, 'e1', '/w/a.txt'),
      assistant(4, '第一轮完成。'),
      _tool(7, 'job'),
      _tool(8, 'check'),
      assistant(10, '后台任务也好了。', reasoning: '看结果'),
    ];

    test('each turn folds its own process, with its own footnote', () {
      final one = _trace(0, 5);
      final two = _trace(6, 11);
      final rows = deriveRows(items: items, turns: [one, two], foldTurns: true);
      expect(_types(rows), [UserRow, TurnProcessRow, AssistantRow, ChangeCardRow, TurnProcessRow, AssistantRow]);
      _expectSane(rows);
      final folds = rows.whereType<TurnProcessRow>().toList();
      expect([for (final f in folds) f.key], ['tp0', 'tp6']);
      expect([for (final f in folds) f.trace], [same(one), same(two)]);
      expect([for (final f in folds) f.toolCalls], [1, 2]);
      final answers = rows.whereType<AssistantRow>().toList();
      expect([for (final a in answers) a.footnote], [same(one), same(two)]);
      expect(answers.every((a) => a.showActions), isTrue);
    });

    test('unfolded, each turn still ends on its own', () {
      final rows = deriveRows(items: items, turns: [_trace(0, 5), _trace(6, 11)]);
      expect(rows.whereType<TurnProcessRow>(), isEmpty);
      final answers = rows.whereType<AssistantRow>().where((a) => a.item.text.isNotEmpty);
      expect([for (final a in answers) a.footnote?.startSeq], [0, 6]);
      final card = rows.indexWhere((r) => r is ChangeCardRow);
      expect(rows[card - 1], isA<AssistantRow>());
      expect((rows[card - 1] as AssistantRow).item.text, '第一轮完成。');
    });

    test('the finished turn folds while the next one runs', () {
      final rows = deriveRows(
        items: items.sublist(0, 6),
        turns: [_trace(0, 5), _running(6)],
        running: true,
        foldTurns: true,
      );
      expect(_types(rows), [UserRow, TurnProcessRow, AssistantRow, ChangeCardRow, ToolCallRow, ToolCallRow]);
    });

    test('a stopped turn after a folded one stays open', () {
      final rows = deriveRows(
        items: [
          ...items,
          const NoticeChatItem(seq: 11, kind: 'aborted', text: ''),
        ],
        turns: [
          _trace(0, 5),
          _trace(6, 11, reason: 'aborted'),
        ],
        foldTurns: true,
      );
      expect(rows.whereType<TurnProcessRow>().map((f) => f.key), ['tp0']);
      expect(_calls(rows.skip(4).toList()), ['job', 'check']);
    });
  });

  group('from DSH log events', () {
    var seq = 0;
    final events = <Map<String, Object?>>[];
    void ev(String type, Map<String, Object?> data) => events.add({
      'type': 'event',
      'event': {
        'type': type,
        'seq': seq++,
        'time': _t0.add(Duration(seconds: seq)).millisecondsSinceEpoch,
        'data': data,
      },
    });
    void prompt(String text) => ev('user/message', {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user'},
    });
    void step(int n, {String reasoning = '', String text = '', String? call}) {
      ev('step/start', {'turn': 1, 'step': n});
      ev('assistant/message', {
        'turn': 1,
        'step': n,
        'message': {
          'role': 'assistant',
          'content': [
            if (reasoning.isNotEmpty) {'type': 'reasoning', 'text': reasoning},
            if (text.isNotEmpty) {'type': 'text', 'text': text},
            if (call != null)
              {
                'type': 'tool-call',
                'id': call,
                'name': 'bash',
                'arguments': jsonEncode({'command': call}),
              },
          ],
          'source': {'kind': 'llm', 'model': 'deepseek-flash'},
        },
      });
      if (call != null) {
        ev('tool/call', {
          'turn': 1,
          'step': n,
          'callId': call,
          'name': 'bash',
          'arguments': jsonEncode({'command': call}),
        });
        ev('tool/result', {
          'turn': 1,
          'step': n,
          'message': {
            'role': 'tool',
            'toolCallId': call,
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          },
        });
      }
      ev('step/end', {'turn': 1, 'step': n});
    }

    ev('turn/start', {'turn': 1});
    prompt('这个 3D 模型怎么跑起来');
    step(1, reasoning: '先搜一下', call: 'search');
    step(2, call: 'fetch');
    // The steer: picked up between two steps of the same turn.
    prompt('顺便看看它是什么模型');
    ev('llm/retry', {'turn': 1, 'step': 3, 'retry': 1, 'maxRetries': 5, 'delayMs': 1000});
    step(3, reasoning: 'The user now asks: What is this 3D model', call: 'run');
    step(4, reasoning: '整理一下', text: '是一个 glTF 模型。');
    ev('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });

    test('a retried, steered turn that completed folds piece by piece', () {
      final t = ChatTranscript();
      for (final e in events) {
        t.apply(parseFollowFrame('s', e));
      }
      expect(t.turns.single.endReason?.isCompleted, isTrue);
      final rows = deriveRows(items: t.items, turns: t.turns, foldTurns: true);
      expect(_types(rows), [UserRow, TurnProcessRow, UserRow, TurnProcessRow, AssistantRow]);
      _expectSane(rows);
      final last = rows[3] as TurnProcessRow;
      expect(last.rows.whereType<NoticeRowData>().map((r) => r.item.kind), [
        'retry',
      ], reason: 'the retry notice is part of the process');
      expect(_calls(rows), ['search', 'fetch', 'run']);
      expect((rows.last as AssistantRow).footnote, same(t.turns.single));
    });
  });

  test('her conversation folds every call away, however the turn ended', () {
    final items = <ChatItem>[user(1, '帮我看看'), _tool(2, 'look'), assistant(3, '看完啦。')];
    final stopped = _trace(0, 4, reason: 'interrupted');
    final plain = deriveRows(items: items, turns: [stopped], foldTurns: true);
    expect(plain.whereType<ToolCallRow>(), hasLength(1), reason: 'an ordinary chat keeps a stopped turn open');
    final hers = deriveRows(items: items, turns: [stopped], foldTurns: true, compactTools: true);
    expect(hers.whereType<ToolCallRow>(), isEmpty);
    expect(hers.whereType<TurnProcessRow>().single.toolCalls, 1);
    _expectSane(hers);
  });
}
