// Run information derived from turn traces: formatting, the live activity,
// footnote placement, trajectory rows and numbered diff hunks, over the
// synthetic timed session (support/run_info_fixture.dart) and the captured
// DSH frames.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/widgets/turn_footnote.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/run_info_fixture.dart';
import 'support/sample_chat.dart';

const _clientFixtures = '../packages/dsh_client/test/fixtures';

ChatTranscript _load(String path) {
  final transcript = ChatTranscript();
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    transcript.apply(parseFollowFrame('s', jsonDecode(line)));
  }
  return transcript;
}

void main() {
  group('formatting', () {
    test('static durations', () {
      expect(formatSpan(const Duration(milliseconds: 40)), '<0.1 秒');
      expect(formatSpan(const Duration(milliseconds: 300)), '0.3 秒');
      expect(formatSpan(const Duration(milliseconds: 4000)), '4 秒');
      expect(formatSpan(const Duration(milliseconds: 4230)), '4.2 秒');
      expect(formatSpan(const Duration(seconds: 47)), '47 秒');
      expect(formatSpan(const Duration(seconds: 65)), '1 分 05 秒');
      expect(formatSpan(const Duration(minutes: 62)), '1 小时 02 分');
    });

    test('live clock', () {
      expect(formatClock(const Duration(seconds: 7)), '0:07');
      expect(formatClock(const Duration(seconds: 765)), '12:45');
      expect(formatClock(const Duration(seconds: 3725)), '1:02:05');
      expect(formatClock(const Duration(seconds: -3)), '0:00');
    });

    test('cost only with a known price; never made up', () {
      expect(knownPricingIsEmpty, isTrue);
      final trace = runInfoState(finished: true).turns.single;
      expect(turnCostLabel(trace), isNull);
      expect(formatCost(0.0349, 'CNY'), '约 ¥0.03');
      expect(formatCost(0.004, 'CNY'), '不到 ¥0.01');
    });
  });

  group('token speed', () {
    test('nothing measured has no speed', () {
      expect(tracesTokensPerSecond(const []), isNull);
      expect(tracesTokensPerSecond([_modelTrace(output: null)]), isNull);
      expect(tracesTokensPerSecond([_modelTrace(decoding: const Duration(milliseconds: 150))]), isNull);
      expect(tracesTokensPerSecond([_modelTrace(firstToken: false)]), isNull);
    });

    test('output tokens over decoding time, aggregated across turns', () {
      final first = _modelTrace(output: 300);
      expect(turnTokensPerSecond(first), 300);
      // 400 tokens over 3 s, not the mean of the two turns' rates.
      final second = _modelTrace(turn: 2, output: 100, decoding: const Duration(seconds: 2));
      expect(tracesTokensPerSecond([first, second]), closeTo(400 / 3, 1e-9));
    });

    test('the fixture turn: 1970 tokens over 16.8 s', () {
      final trace = runInfoState(finished: true).turns.single;
      expect(turnTokensPerSecond(trace), closeTo(1970 / 16.8, 1e-9));
      expect(turnSpeedLabel(trace), '117 tokens/秒');
    });

    test('one decimal below ten, whole numbers at ten and up', () {
      expect(speedFigure(8.34), '8.3');
      // 9.95 already rounds up: no '10.0'.
      expect(speedFigure(9.94), '9.9');
      expect(speedFigure(9.96), '10');
      expect(speedFigure(10.4), '10');
      expect(speedFigure(117.26), '117');
      expect(speedFigure(null), isNull);
      expect(speedText(8.34), '8.3 tokens/秒');
      expect(speedText(null), isNull);
    });
  });

  group('timed session', () {
    test('turn one: 1 分 23 秒, five requests, a 48 s wait for the person', () {
      final trace = runInfoState(finished: true).turns.single;
      expect(trace.running, isFalse);
      expect(formatSpan(trace.duration!), '1 分 23 秒');
      expect(trace.steps, 5);
      expect(trace.waitTime, const Duration(seconds: 48));
      expect(trace.ttft, const Duration(milliseconds: 1100));
      expect(trace.usage.total, 8226 + 69888 + 1970);
      expect(TurnFootnote.variants(trace).first, '1 分 23 秒 · 5 步 · 80.1K tokens · 117 tokens/秒');

      final rows = trajectoryRows(trace);
      final labels = [
        for (final row in rows)
          switch (row) {
            SpanRow(:final span) => spanLabel(span).title,
            SpanGroupRow() => 'group',
          },
      ];
      expect(labels, [
        '思考', '读取', '搜索', //
        '思考', '更新待办', '编辑',
        '思考', '等待确认', '运行',
        '思考', '写入', '更新待办',
        '回复',
      ]);
      final wait = (rows[7] as SpanRow).span;
      expect(wait.outcome, ApprovalOutcome.allowedOnce);
      expect(spanLabel(wait).detail, '运行 flutter test test/auth');
    });

    test('the footnote hangs on the last reply, the change card follows', () {
      final s = runInfoState(finished: true);
      final rows = deriveRows(items: s.items, turns: s.turns);
      final reply = rows.whereType<AssistantRow>().last;
      expect(reply.showActions, isTrue);
      expect(reply.footnote, same(s.turns.single));
      expect(rows.last, isA<ChangeCardRow>());
      expect(rows.whereType<TurnFootnoteRow>(), isEmpty);
    });

    test('a turn without a reply gets a footnote row of its own', () {
      final t = _load('$_clientFixtures/follow_cancel.jsonl');
      final items = [
        for (final item in t.items)
          if (item is! AssistantChatItem) item,
      ];
      final rows = deriveRows(items: items, turns: t.turns);
      expect(rows.whereType<TurnFootnoteRow>(), hasLength(1));
      expect(rows.indexWhere((r) => r is TurnFootnoteRow), greaterThan(0));
    });

    test('a running turn has no footnote yet', () {
      final s = runInfoState();
      final rows = deriveRows(items: s.items, turns: s.turns, running: true);
      final footnotes = [
        for (final row in rows)
          if (row is AssistantRow && row.footnote != null) row.footnote,
      ];
      expect(footnotes, [same(s.turns.first)]);
    });

    test('while running: what runs now, since when, todo progress', () {
      final s = runInfoState();
      expect(s.runningTurn, isNotNull);
      final activity = runActivityOf(s)!;
      expect(activity.kind, ActivityKind.tool);
      expect(activity.title, '跑');
      expect(activity.detail, 'flutter test');
      expect(activity.since, runInfoTestDispatched);
      expect((activity.todoDone, activity.todoTotal), (4, 5));
      expect(runActivityOf(runInfoState(finished: true)), isNull);
    });

    test('waiting on the person wins over everything else', () {
      final activity = runActivityOf(conversationState())!;
      expect(activity.kind, ActivityKind.approval);
      expect(activity.title, '等你确认');
      expect(activity.detail, '跑 flutter test test/auth');
      expect(activity.since, isNull, reason: 'no trace in this state');
    });

    test('streaming text reads as replying, reasoning only as thinking', () {
      expect(runActivityOf(streamingState())!.title, '写回复中');
      final thinking = ChatState(
        running: true,
        items: [
          user(1, 'hi'),
          assistant(2, '', reasoning: '嗯', streaming: true),
        ],
      );
      expect(runActivityOf(thinking)!.title, '思考中');
    });
  });

  group('numbered hunks', () {
    test('an edit after a read gets real line numbers; a new file starts at 1', () {
      final s = runInfoState(finished: true);
      final files = fileChangesOf(s.items.whereType<ToolChatItem>().toList());
      expect(files.map((f) => f.shownPath), [
        'app/lib/auth/login_controller.dart',
        'test/auth/login_controller_test.dart',
      ]);
      final edit = files.first.hunks.single;
      expect((edit.oldStart, edit.newStart), (9, 9));
      expect((edit.oldCount, edit.newCount), (9, 13));
      final created = files.last.hunks.single;
      expect(created.newStart, 1);
      expect(
        files.last.patch,
        startsWith('--- /dev/null\n+++ b/test/auth/login_controller_test.dart\n@@ -0,0 +1,15 @@\n'),
      );
      expect(files.first.patch, contains('@@ -9,9 +9,13 @@\n'));
    });

    test('whole-file writes and successive edits are placed too', () {
      final t = _load('test/chat/fixtures/follow_file_changes.jsonl');
      final turnTwo = t.items.whereType<ToolChatItem>().skip(6).toList();
      final readme = fileChangesOf(turnTwo).first;
      // An update by whole-file write: placed by its new text in the result.
      expect(readme.created, isFalse);
      expect(readme.hunks.single.newStart, 2);
      expect(readme.hunks.single.oldStart, 2);
      final turnOne = fileChangesOf(t.items.whereType<ToolChatItem>().take(6).toList());
      final login = turnOne.firstWhere((f) => f.fileName == 'login_controller.dart');
      expect(login.edits, 2);
      expect(login.hunks.map((h) => h.edit), [1, 2]);
      // The read saw the file, so the first edit lands; the second is placed
      // in the content as the first edit left it.
      expect(login.hunks.every((h) => h.numbered), isTrue);
    });
  });
}

/// One model request that decoded [output] tokens over [decoding]; no usage
/// when [output] is null, no first token when [firstToken] is false.
TurnTrace _modelTrace({
  int turn = 1,
  int? output = 300,
  Duration decoding = const Duration(seconds: 1),
  bool firstToken = true,
}) {
  final start = DateTime(2026);
  final end = start.add(decoding);
  return TurnTrace(
    turn: turn,
    startSeq: turn * 10,
    start: start,
    end: end,
    spans: [
      TraceSpan(
        kind: TraceKind.model,
        step: 1,
        seq: turn * 10 + 1,
        start: start,
        end: end,
        firstToken: firstToken ? start : null,
        usage: output == null ? null : TokenUsage(inputTokens: 100, outputTokens: output),
      ),
    ],
  );
}

/// `knownPricing` stays empty until DeepSeek's prices are in the repo.
bool get knownPricingIsEmpty =>
    turnCostLabel(
      TurnTrace(
        turn: 1,
        startSeq: 0,
        start: DateTime(2026),
        end: DateTime(2026),
        endSeq: 1,
        spans: [
          TraceSpan(
            kind: TraceKind.model,
            step: 1,
            seq: 1,
            start: DateTime(2026),
            end: DateTime(2026),
            provider: 'deepseek-official',
            model: 'deepseek-flash',
            usage: const TokenUsage(inputTokens: 1000, outputTokens: 10),
          ),
        ],
      ),
    ) ==
    null;
