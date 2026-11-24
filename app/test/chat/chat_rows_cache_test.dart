import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/chat_rows_cache.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_chat.dart';

// Compare the complete projection, including nested folded rows, to the
// uncached implementation. This is a work-count contract, not an FPS claim.
// A changed streaming draft makes fresh tool calls; the cache keeps the one
// it has while its values are the same, so compare those by value.
Object toolShape(ToolChatItem t) =>
    t.seq == null && (t.status == ToolStatus.streaming || t.status == ToolStatus.running)
    ? (t.callId, t.name, t.arguments, t.status, t.resultParts, t.meta, t.pendingApproval)
    : t;

Object shape(ChatRow row) => switch (row) {
  UserRow(:final item) => (row.key, item),
  PendingRow(:final prompt) => (row.key, prompt),
  AssistantRow(:final item, :final showActions, :final footnote) => (
    row.key,
    item.id,
    item.seq,
    item.time,
    item.text,
    item.reasoning,
    item.streaming,
    item.interrupted,
    item.usage,
    item.model,
    showActions,
    footnote,
  ),
  ToolCallRow(:final item, :final card) => (row.key, toolShape(item), card),
  ToolGroupRow(:final tools, :final live) => [row.key, tools.map(toolShape).toList(), live],
  NoticeRowData(:final item) => (row.key, item),
  ApprovalRow(:final request) => (row.key, request),
  QuestionRow(:final request) => (row.key, request),
  ChangeCardRow(:final files) => [
    row.key,
    for (final f in files) (f.path, f.created, f.added, f.removed, f.edits, f.patch, f.lastCallId),
  ],
  ArtifactCardRow(:final group) => (row.key, group),
  TurnProcessRow(:final trace, :final rows, :final toolCalls, :final messages, :final cut) => [
    row.key,
    trace,
    toolCalls,
    messages,
    cut,
    rows.map(shape).toList(),
  ],
  TurnFootnoteRow(:final trace) => (row.key, trace),
  CommandNoticeRow(:final notice) => (row.key, notice),
};

List<ChatRow> check(
  ChatRowsCache cache,
  ChatState state, {
  bool foldTurns = false,
  List<TurnArtifacts> artifacts = const [],
}) {
  final actual = cache.update(state, foldTurns: foldTurns, artifacts: artifacts);
  final expected = deriveRows(
    items: state.items,
    approvals: state.approvals,
    questions: state.questions,
    pending: state.pending,
    running: state.running,
    autoAnswered: state.autoAnswered,
    commands: state.commands,
    turns: state.turns,
    foldTurns: foldTurns,
    artifacts: artifacts,
  );
  expect(actual.map(shape).toList(), expected.map(shape).toList());
  expect(cache.index, {for (var i = 0; i < actual.length; i++) actual[i].key: i});
  return actual;
}

void main() {
  test('1000 historical rows and the key index survive each streaming update', () {
    final history = [for (var i = 0; i < 1000; i++) assistant(i, 'History $i')];
    final queued = PendingPrompt(requestId: 'queued', text: 'Next', time: DateTime(2026));
    ChatState snapshot(int token) => ChatState(
      loading: false,
      running: true,
      items: [
        ...history,
        assistant(1001, token.isEven ? '' : 'Token $token', reasoning: '$token', streaming: true),
      ],
      // ChatController publishes fresh list containers, even without changes.
      approvals: [approval],
      questions: [],
      commands: [],
      pending: [queued],
    );
    final cache = ChatRowsCache();
    final first = check(cache, snapshot(0));
    final index = cache.index;
    for (var token = 1; token <= 20; token++) {
      final rows = check(cache, snapshot(token));
      for (var i = 0; i < rows.length; i++) {
        if (i == 1000) continue;
        expect(identical(rows[i], first[i]), isTrue, reason: 'only the live draft changes');
      }
      expect(identical(cache.index, index), isTrue);
      expect((first[1000] as AssistantRow).item.reasoning, '0', reason: 'previous results stay immutable');
    }
  });

  test('streaming tool arguments keep every other row: alone, after thinking, in a live group', () {
    ToolChatItem call(String id, String args, {ToolStatus status = ToolStatus.streaming}) =>
        ToolChatItem(callId: id, name: 'bash', arguments: args, status: status);
    final prompt = user(1, 'Question');
    final earlier = assistant(2, 'Earlier');
    final done = [
      for (var i = 0; i < 2; i++) tool('done$i', 'read', {'path': '$i'}),
    ];
    final queued = [PendingPrompt(requestId: 'q', text: 'Next', time: DateTime(2026))];
    final shapes = <String, List<ChatItem> Function(int)>{
      'alone': (n) => [prompt, earlier, call('c', '{"command": "${'x' * n}')],
      'after thinking': (n) => [
        prompt,
        assistant(3, '', reasoning: 'Look first', streaming: true),
        call('a', '{"command": "ls"}', status: ToolStatus.running),
        call('c', '{"command": "${'x' * n}'),
      ],
      'in a live group': (n) => [prompt, ...done, call('c', '{"command": "${'x' * n}')],
    };
    for (final MapEntry(key: name, value: items) in shapes.entries) {
      final cache = ChatRowsCache();
      // Each publish brings new pending and draft objects that are equal.
      ChatState state(int n) => ChatState(
        running: true,
        items: items(n),
        pending: [for (final p in queued) PendingPrompt(requestId: p.requestId, text: p.text, time: p.time)],
      );
      final first = check(cache, state(0));
      final index = cache.index;
      final live = first.indexWhere((row) => row is ToolGroupRow || (row is ToolCallRow && row.item.callId == 'c'));
      final derived = debugDeriveRowsCount;
      for (var n = 1; n <= 10; n++) {
        final rows = check(cache, state(n));
        for (var i = 0; i < rows.length; i++) {
          if (i == live) continue;
          expect(identical(rows[i], first[i]), isTrue, reason: '$name: row $i is not the call being written');
        }
        expect(identical(cache.index, index), isTrue, reason: name);
      }
      // check() itself derives once per update to compare against.
      expect(debugDeriveRowsCount - derived, 10, reason: '$name: the cache derived no rows');
      expect(identical(check(cache, state(10)), cache.update(state(10), foldTurns: false)), isTrue);
    }
  });

  test('a draft call in an earlier group is replaced although a later group has other drafts', () {
    ToolChatItem call(String id, String args, {ToolStatus status = ToolStatus.streaming}) =>
        ToolChatItem(callId: id, name: 'bash', arguments: args, status: status);
    // The transcript hands the same durable items to every read.
    final durable = [
      user(1, 'Question'),
      tool('d0', 'read', {'path': '0'}),
      tool('d1', 'read', {'path': '1'}),
    ];
    // Two groups of calls, split by a streaming reply: the first ends in the
    // draft being written, the second is made of drafts too.
    List<ChatItem> items(int n) => [
      ...durable,
      call('a', '{"command": "${'x' * n}'),
      assistant(2, 'Between', streaming: true),
      call('c1', '{"command": "1"}', status: ToolStatus.running),
      call('c2', '{"command": "2"}', status: ToolStatus.running),
      call('c3', '{"command": "3"'),
    ];
    final cache = ChatRowsCache();
    final first = check(cache, ChatState(running: true, items: items(0)));
    expect(first.whereType<ToolGroupRow>().length, 2, reason: 'one group per run of calls');
    final group = first.indexWhere((row) => row is ToolGroupRow);
    final derived = debugDeriveRowsCount;
    for (var n = 1; n <= 5; n++) {
      check(cache, ChatState(running: true, items: items(n)));
      expect(cache.onlyDraftChanged, isTrue, reason: 'delta $n changes only the earlier draft');
      expect(cache.unchangedPrefix, group, reason: 'delta $n: rows before the earlier group are unchanged');
    }
    // check() itself derives once per update to compare against.
    expect(debugDeriveRowsCount - derived, 5, reason: 'the cache derived no rows');
  });

  test('a finished draft, a result or an approval on a draft call still derive', () {
    final cache = ChatRowsCache();
    final prompt = user(1, 'Question');
    ToolChatItem call(ToolStatus status, {List<Part> result = const [], ApprovalRequest? pending}) => ToolChatItem(
      callId: 'c',
      name: 'bash',
      arguments: '{}',
      status: status,
      resultParts: result,
      pendingApproval: pending,
    );
    final cases = [
      [prompt, call(ToolStatus.streaming)],
      [prompt, call(ToolStatus.running)],
      [prompt, call(ToolStatus.running, pending: approval)],
      [
        prompt,
        call(ToolStatus.succeeded, result: const [TextPart('ok')]),
      ],
      [prompt, assistant(2, 'Draft', streaming: true), call(ToolStatus.streaming)],
      [prompt, assistant(2, 'Draft', streaming: false), call(ToolStatus.streaming)],
      [prompt, assistant(2, 'Draft', streaming: true), call(ToolStatus.streaming)],
    ];
    for (final items in cases) {
      check(cache, ChatState(items: items, running: true));
    }
  });

  test('equal input containers reuse the projection without retaining removed rows', () {
    final items = [user(1, 'Question'), assistant(2, 'Answer')];
    final cache = ChatRowsCache();
    final rows = check(cache, ChatState(items: items));
    expect(identical(check(cache, ChatState(items: [...items], approvals: [], commands: [])), rows), isTrue);
    final empty = check(cache, const ChatState());
    expect(empty, isEmpty);
    expect(cache.index, isEmpty);
  });

  test('same-key draft commit and turn completion use the full projection', () {
    final cache = ChatRowsCache();
    final prompt = user(1, 'Question');
    final start = DateTime(2026);
    final runningTurn = TurnTrace(turn: 1, startSeq: 2, start: start, spans: const []);
    final draft = assistant(3, 'Draft', rowKey: 'm1.1', streaming: true);
    check(cache, ChatState(items: [prompt, draft], running: true, turns: [runningTurn]));
    final committed = assistant(4, 'Final', rowKey: 'm1.1');
    check(cache, ChatState(items: [prompt, committed], running: true, turns: [runningTurn]));
    final finished = TurnTrace(
      turn: 1,
      startSeq: 2,
      start: start,
      spans: const [],
      endSeq: 5,
      end: start.add(const Duration(seconds: 1)),
      endReason: const TurnEndReason('completed'),
    );
    final rows = check(cache, ChatState(items: [prompt, committed], turns: [finished]));
    expect((rows.last as AssistantRow).showActions, isTrue);
    expect((rows.last as AssistantRow).footnote, same(finished));
  });

  test('history edit, prepend, removal, tools and multiple drafts invalidate reuse', () {
    final cache = ChatRowsCache();
    final prompt = user(1, 'Question');
    final original = assistant(2, 'Old');
    final edited = assistant(2, 'Edited');
    final draft = assistant(3, 'Draft', streaming: true);
    final next = assistant(3, 'Next', streaming: true);
    final cases = <List<ChatItem>>[
      [prompt, original, draft],
      [prompt, edited, next],
      [user(0, 'Older'), prompt, edited, next],
      [prompt, next],
      [
        prompt,
        next,
        tool('t', 'read', {'path': 'a'}, status: ToolStatus.running),
      ],
      [
        prompt,
        next,
        tool('t', 'read', {'path': 'a'}, result: 'done'),
      ],
      [prompt, next, assistant(4, 'Another attempt', streaming: true)],
      [prompt, assistant(3, 'Changed earlier draft', streaming: true), assistant(4, 'Next', streaming: true)],
      [
        prompt,
        assistant(3, 'Stopped', interrupted: true),
        const NoticeChatItem(seq: 4, kind: 'aborted', text: 'Stopped'),
      ],
    ];
    for (final items in cases) {
      check(cache, ChatState(items: items, running: true));
    }
  });

  test('approval, question, queue, command and turn changes are never hidden by a text update', () {
    final cache = ChatRowsCache();
    final prompt = user(1, 'Question');
    final items = [prompt, assistant(3, 'Draft', streaming: true)];
    final pending = PendingPrompt(requestId: 'p', text: 'Queue', time: DateTime(2026));
    const question = UserQuestionRequest(eventId: 'q', sessionId: 's1', questions: []);
    const command = CommandNotice(id: 'c', name: 'help');
    final cases = [
      ChatState(items: items, running: true),
      ChatState(items: items, running: true, approvals: [approval]),
      ChatState(items: items, running: true, approvals: [approval], autoAnswered: {approval.eventId}),
      ChatState(items: items, running: true, questions: const [question]),
      ChatState(items: items, running: true, pending: [pending]),
      ChatState(
        items: items,
        running: true,
        pending: [PendingPrompt(requestId: 'p', text: 'Edited queue', time: pending.time)],
      ),
      ChatState(items: items, running: true, commands: const [command]),
      ChatState(
        items: items,
        running: true,
        commands: [command.copyWith(done: true, text: 'Done')],
      ),
      ChatState(
        items: items,
        running: true,
        turns: [TurnTrace(turn: 1, startSeq: 2, start: DateTime(2026), spans: const [])],
      ),
      ChatState(items: items),
    ];
    for (final state in cases) {
      check(cache, state);
    }
  });

  test('fold preferences, open turns and artifacts invalidate historical rows', () {
    final cache = ChatRowsCache();
    final turn = TurnTrace(
      turn: 1,
      startSeq: 2,
      start: DateTime(2026),
      spans: const [],
      endSeq: 8,
      end: DateTime(2026, 1, 1, 0, 0, 1),
      endReason: const TurnEndReason('completed'),
    );
    final state = ChatState(
      running: true,
      items: [
        user(1, 'First'),
        assistant(3, 'Step'),
        tool('t', 'read', {'path': 'a'}),
        assistant(7, 'Answer', reasoning: 'Thought'),
        user(9, 'Next'),
        assistant(10, 'Draft', streaming: true),
      ],
      turns: [turn],
    );
    check(cache, state);
    final folded = check(cache, state, foldTurns: true);
    expect(folded.whereType<TurnProcessRow>(), isNotEmpty);
    check(cache, state, foldTurns: true);
    const artifact = TurnArtifacts(turn: 1, endSeq: 8, files: []);
    check(cache, state, foldTurns: true, artifacts: const [artifact]);
    check(cache, state, foldTurns: true);
  });
}
