// Which files a turn delivered or generated (lib/state/artifacts.dart) and
// where their card sits among the chat rows, over a synthetic session in the
// DSH 0.2.1 wire shape (test/chat/fixtures/follow_artifacts.jsonl) and the
// presented-files fixture of packages/dsh_client.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

ChatTranscript _load(String path) {
  final transcript = ChatTranscript();
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    transcript.apply(parseFollowFrame('s', jsonDecode(line)));
  }
  return transcript;
}

const _fixture = 'test/chat/fixtures/follow_artifacts.jsonl';
const _ws = '/root/workspace';

List<TurnArtifacts> _derive(ChatTranscript t, {List<PhoneOutput> outputs = const []}) =>
    deriveArtifacts(events: t.events, turns: t.turns, cwd: t.header?.cwd, phoneOutputs: outputs);

List<Type> _types(List<ChatRow> rows) => [for (final r in rows) r.runtimeType];

class _CountedMessage extends Message {
  _CountedMessage(Message message)
    : super(id: message.id, role: message.role, parts: message.parts, source: message.source);

  int reads = 0;

  @override
  String get text {
    reads++;
    return super.text;
  }
}

void main() {
  test('finished artifact inputs are read once until that turn changes', () {
    final transcript = _load(_fixture);
    final messages = <_CountedMessage>[];
    for (final event in transcript.events.toList()) {
      if (event is! AssistantMessageEvent) continue;
      final message = _CountedMessage(event.message);
      messages.add(message);
      transcript.apply(
        AssistantMessageEvent(
          event.seq,
          event.time,
          event.data,
          turn: event.turn,
          step: event.step,
          message: message,
          usage: event.usage,
          interrupted: event.interrupted,
        ),
      );
    }
    final cache = SessionArtifactsCache();
    var cwd = _ws;
    List<PhoneOutput> outputs = const [];
    List<TurnArtifacts> read() =>
        cache.derive(events: transcript.events, turns: transcript.turns, cwd: cwd, phoneOutputs: outputs);
    int reads() => messages.fold(0, (sum, message) => sum + message.reads);
    final first = read();
    expect(reads(), 12, reason: 'only the 12 committed messages of finished turns');
    final running = transcript.turns.last;
    transcript.apply(
      ToolCallEvent(46, running.start, const {}, turn: 4, step: 2, callId: 'next', name: 'bash', arguments: '{}'),
    );
    final again = read();
    expect(reads(), 12, reason: 'no history reply rejoined, including the turn with no artifacts');
    expect(again[0], same(first[0]));
    expect(again[1], same(first[1]));

    // A late declaration changes a reused trace, including integral JSON doubles.
    transcript.apply(
      SessionLogEvent.fromJson({
        'seq': 47,
        'time': running.start.millisecondsSinceEpoch,
        'type': presentedEventType,
        'data': {
          'turn': 3.0,
          'callId': 'late',
          'files': [
            {'path': 'late.xlsx'},
          ],
        },
      }),
    );
    final late = read();
    expect(reads(), 14, reason: 'only the two messages of turn 3 are reconsidered');
    expect(late[0], same(first[0]));
    expect(late.last.files.single.path, '$_ws/late.xlsx');

    // An older page can replace an event without replacing its TurnTrace.
    final old = transcript.events.whereType<AssistantMessageEvent>().firstWhere((event) => event.seq == 31);
    final replacement = _CountedMessage(
      Message.fromJson({
        'id': old.message.id,
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'No linked spreadsheet now.'},
        ],
      }),
    );
    messages.add(replacement);
    transcript.prependHistory(
      HistoryPage([
        AssistantMessageEvent(old.seq, old.time, old.data, turn: old.turn, step: old.step, message: replacement),
      ], false),
    );
    final changed = read();
    expect(reads(), 20, reason: 'only the six messages of the replaced turn are reconsidered');
    expect(changed[1].files.map((file) => file.path), ['$_ws/site/index.html']);
    expect(changed[0], same(first[0]));

    cwd = '/another';
    final moved = read();
    expect(reads(), 32);
    expect(moved.last.files.single.path, '/another/late.xlsx');
    outputs = [PhoneOutput(path: '$phoneOutputDir/new.pdf', modified: transcript.turns[1].start)];
    final withOutput = read();
    expect(reads(), 44);
    expect(withOutput[1].files.last.path, '$phoneOutputDir/new.pdf');
  });

  test('invalid bash arguments do not affect a write create artifact', () {
    final transcript = ChatTranscript();
    var seq = 0;
    void event(String type, Map<String, Object?> data) {
      transcript.apply(
        parseFollowFrame('s', {
          'type': 'event',
          'event': {'type': type, 'seq': seq++, 'time': 1792900000000, 'data': data},
        }),
      );
    }

    event('turn/start', {'turn': 1});
    event('tool/call', {'turn': 1, 'step': 1, 'callId': 'bad', 'name': 'bash', 'arguments': '{broken json'});
    event('tool/result', {
      'turn': 1,
      'step': 1,
      'message': {'id': 'r1', 'role': 'tool', 'toolCallId': 'bad', 'content': [], 'isError': false},
    });
    event('tool/call', {'turn': 1, 'step': 2, 'callId': 'write', 'name': 'write', 'arguments': '{not needed'});
    event('tool/result', {
      'turn': 1,
      'step': 2,
      'message': {'id': 'r2', 'role': 'tool', 'toolCallId': 'write', 'content': [], 'isError': false},
      'meta': {'operation': 'create', 'path': '/root/workspace/report.pdf'},
    });
    event('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
    expect(_derive(transcript).single.files.single.path, '/root/workspace/report.pdf');
  });

  group('file types', () {
    test('kinds, labels and MIME types from the extension', () {
      expect(artifactKindOf('/a/Q3.PDF'), ArtifactKind.pdf);
      expect(artifactKindOf('x.xlsx'), ArtifactKind.spreadsheet);
      expect(artifactKindOf('deck.pptx'), ArtifactKind.slides);
      expect(artifactKindOf('a.tar.gz'), ArtifactKind.archive);
      expect(artifactKindOf('Makefile'), ArtifactKind.other);
      expect(mimeTypeOf('a.docx'), 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
      expect(mimeTypeOf('a.weird'), 'application/octet-stream');
      Artifact a(String path) => Artifact(path: path, origin: ArtifactOrigin.written, turn: 1);
      expect(a('/w/r.pdf').typeLabel, 'PDF');
      expect(a('/w/s.xlsx').typeLabel, '表格 · XLSX');
      expect(a('/w/x.bin').typeLabel, 'BIN');
      expect(a('$phoneOutputDir/r.pdf').inPhoneDownloads, isTrue);
      expect(a('/sdcard/Download/DSH/r.pdf').inPhoneDownloads, isTrue);
      expect(a('/root/workspace/r.pdf').inPhoneDownloads, isFalse);
    });

    test('made for the user: documents, media, archives, pages; not code or notes', () {
      for (final path in [
        'r.pdf',
        'p.png',
        's.csv',
        'd.docx',
        'k.pptx',
        'z.zip',
        'v.mp4',
        'a.mp3',
        'i.html',
        'c.ics',
      ]) {
        expect(isArtifactPath(path), isTrue, reason: path);
      }
      for (final path in ['main.dart', 'app.py', 'README.md', 'notes.txt', 'conf.yaml', 'data.json', 'Makefile']) {
        expect(isArtifactPath(path), isFalse, reason: path);
      }
    });

    test('reply links: local paths only, resolved, anchors dropped', () {
      const reply =
          '见 [报告](<out/Q3 report.pdf>) 和 ![图](chart%20v2.png "趋势")、'
          '[年报](https://example.com/a.pdf)、[锚点](#top)、[行](<src/a.py#L3-L9>)、'
          '[绝对](/sdcard/Download/DSH/x.xlsx)、[再提一次](<out/Q3 report.pdf>)、'
          '[手机](/sdcard/Download/DSH-Go/y.pdf)。';
      expect(linkedPaths(reply, cwd: _ws), [
        '$_ws/out/Q3 report.pdf',
        '$_ws/chart v2.png',
        '$_ws/src/a.py',
        '/sdcard/Download/DSH/x.xlsx',
        '$phoneOutputDir/y.pdf',
      ]);
    });
  });

  group('per-turn artifacts', () {
    late ChatTranscript t;
    setUp(() => t = _load(_fixture));

    test('deliverables replace every other rule for their turn', () {
      final turn1 = _derive(t).firstWhere((g) => g.turn == 1);
      expect(turn1.delivered, isTrue);
      expect([for (final f in turn1.files) f.path], ['$_ws/out/report.pdf', '$_ws/out/chart.png']);
      expect(turn1.files.first.description, '2026 Q3 销售汇总');
      expect(turn1.files.last.description, isNull);
      expect(turn1.endSeq, t.turns.first.endSeq);
    });

    test('without deliverables: created pages, and linked files the turn named', () {
      final turn2 = _derive(t).firstWhere((g) => g.turn == 2);
      expect(turn2.delivered, isFalse);
      expect(
        [for (final f in turn2.files) (f.path, f.origin)],
        [('$_ws/site/index.html', ArtifactOrigin.written), ('$_ws/out/summary.xlsx', ArtifactOrigin.linked)],
      );
    });

    test('files that appeared in the phone output folder while the turn ran', () {
      final trace3 = t.turns.firstWhere((tr) => tr.turn == 3);
      final outputs = [
        PhoneOutput(
          path: '$phoneOutputDir/summary.xlsx',
          modified: trace3.start.add(const Duration(seconds: 2)),
          bytes: 18432,
        ),
        PhoneOutput(path: '$phoneOutputDir/old.pdf', modified: t.turns.first.start.subtract(const Duration(days: 1))),
      ];
      final groups = _derive(t, outputs: outputs);
      final turn3 = groups.firstWhere((g) => g.turn == 3);
      expect(turn3.files.single.path, '$phoneOutputDir/summary.xlsx');
      expect(turn3.files.single.origin, ArtifactOrigin.phoneOutput);
      expect(turn3.files.single.bytes, 18432);
      expect(groups.expand((g) => g.files).where((f) => f.path.endsWith('old.pdf')), isEmpty);
      // Without the listing the turn made nothing for the user.
      expect(_derive(t).map((g) => g.turn), [1, 2]);
    });

    test('a running turn shows nothing yet, its declaration included', () {
      expect(t.running, isTrue);
      expect(_derive(t).map((g) => g.turn), isNot(contains(4)));
    });

    test('presented-files fixture: latest description, relative path resolved', () {
      final presented = _load('../packages/dsh_client/test/fixtures/follow_presented.jsonl');
      final groups = _derive(presented);
      expect(groups.map((g) => g.turn), [1]);
      expect(
        [for (final f in groups.single.files) (f.name, f.description)],
        [('report.pdf', '季度销售报告(终版)'), ('chart.png', null), ('data.xlsx', '原始数据')],
      );
      expect(groups.single.files.last.path, '$_ws/out/data.xlsx');
    });
  });

  group('chat rows', () {
    late ChatTranscript t;
    late List<TurnArtifacts> artifacts;
    setUp(() {
      t = _load(_fixture);
      artifacts = _derive(t);
    });

    List<ChatRow> rows({bool fold = false, bool running = false}) =>
        deriveRows(items: t.items, turns: t.turns, running: running, foldTurns: fold, artifacts: artifacts);

    test('each card follows its turn, after the change card', () {
      final all = rows(running: true);
      final cards = all.whereType<ArtifactCardRow>().toList();
      expect(cards.map((c) => c.group.turn), [1, 2]);
      final second = all.indexOf(cards[1]);
      expect(all[second - 1], isA<ChangeCardRow>());
      expect(all[second + 1], isA<UserRow>(), reason: 'turn 3 starts right after');
      final first = all.indexOf(cards[0]);
      expect(all[first + 1], isA<UserRow>());
      expect(all[first - 1], isA<ChangeCardRow>(), reason: 'turn 1 created a script');
      expect(cards[0].key, 'art${t.turns.first.endSeq}');
    });

    test('folded turns keep the cards outside the process row', () {
      final all = rows(fold: true, running: true);
      expect(_types(all.sublist(0, 5)), [UserRow, TurnProcessRow, AssistantRow, ChangeCardRow, ArtifactCardRow]);
      for (final process in all.whereType<TurnProcessRow>()) {
        expect(process.rows.whereType<ArtifactCardRow>(), isEmpty);
      }
      final second = all.whereType<ArtifactCardRow>().last;
      expect(all[all.indexOf(second) - 1], isA<ChangeCardRow>());
      expect(all[all.indexOf(second) - 2], isA<AssistantRow>());
    });

    test('a turn without a card gets none; no artifacts, no cards', () {
      expect(rows(running: true).whereType<ArtifactCardRow>().map((c) => c.group.turn), isNot(contains(3)));
      final plain = deriveRows(items: t.items, turns: t.turns, running: true);
      expect(plain.whereType<ArtifactCardRow>(), isEmpty);
    });

    test('several finished turns in one segment each get their card', () {
      // Two auto-triggered turns (no user message between them).
      final start = DateTime(2026, 10, 24, 9);
      TurnTrace trace(int turn, int startSeq, int endSeq) => TurnTrace(
        turn: turn,
        startSeq: startSeq,
        start: start,
        spans: const [],
        endSeq: endSeq,
        end: start.add(const Duration(seconds: 5)),
        endReason: const TurnEndReason('completed'),
      );
      Artifact file(int turn) => Artifact(path: '/w/t$turn.pdf', origin: ArtifactOrigin.delivered, turn: turn);
      final items = <ChatItem>[
        UserChatItem(seq: 1, time: start, text: '开始', images: const [], files: const []),
        AssistantChatItem(id: 'a3', seq: 3, text: '第一轮', reasoning: ''),
        AssistantChatItem(id: 'a6', seq: 6, text: '第二轮', reasoning: ''),
      ];
      final all = deriveRows(
        items: items,
        turns: [trace(1, 0, 4), trace(2, 5, 7)],
        artifacts: [
          TurnArtifacts(turn: 1, endSeq: 4, files: [file(1)]),
          TurnArtifacts(turn: 2, endSeq: 7, files: [file(2)]),
        ],
      );
      // Each turn closes on its own: its card right after its reply.
      expect(_types(all), [UserRow, AssistantRow, ArtifactCardRow, AssistantRow, ArtifactCardRow]);
      expect(all.whereType<ArtifactCardRow>().map((c) => c.group.turn), [1, 2]);
    });
  });
}
