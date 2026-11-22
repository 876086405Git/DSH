import 'dart:convert';

import 'package:dsh_client/src/companion_memory_rules.dart';
import 'package:test/test.dart';

MemoryRow source(String id, String text, {int sequence = 101, int revision = 1, int? editedAt}) => {
  'id': id,
  'session_id': 'room',
  'first_seq': sequence,
  'source_rev': revision,
  'event_seq': editedAt == null ? sequence : sequence + 10,
  'role': 'user',
  'scope': 'real',
  'text': text,
  'said_at_utc': DateTime.parse('2026-11-16T15:30:00Z').millisecondsSinceEpoch,
  'offset_minutes': 480,
  'edited_at_utc': editedAt,
};

MemoryRow card(
  String id,
  String text, {
  List<String> keywords = const [],
  String kind = 'fact',
  bool pinned = false,
  bool manual = false,
  bool eligible = true,
  String scope = 'real',
  String status = 'current',
  String mode = 'normal',
  int sourceAt = 100,
  int? expiresAt,
  String? topic,
  List<MemoryRow> evidence = const [],
}) => {
  'id': id,
  'row_rev': 8,
  'kind': kind,
  'text': text,
  'keywords': keywords,
  'pinned': pinned,
  'manual': manual,
  'eligible': eligible,
  'scope': scope,
  'status': status,
  'topic_id': topic ?? id,
  'topic_mode': mode,
  'current_basis_seq': 102,
  'source_at_ms': sourceAt,
  'created_at_ms': sourceAt,
  'updated_at_ms': 999999,
  'expires_at_ms': expiresAt,
  'evidence': evidence,
};

MemoryRow support(String quote) => {
  'message_id': 'support',
  'source_rev': 1,
  'quote': quote,
  'role': 'user',
  'scope': 'real',
};

MemoryBatch batch({List<MemoryRow>? sources, List<MemoryRow> existing = const []}) =>
    MemoryBatch(id: 'batch-1', controlRevision: 4, sources: sources ?? [source('u1', '我现在咖啡喝无糖。')], existing: existing);

MemoryRow proposal({List<MemoryRow>? operations, List<String> covered = const ['u1']}) => {
  'schema_version': 2,
  'batch_id': 'batch-1',
  'covered_message_ids': covered,
  'operations':
      operations ??
      <MemoryRow>[
        {
          'op': 'create',
          'kind': 'preference',
          'text': '你现在咖啡喝无糖。',
          'keywords': ['咖啡', '无糖'],
          'evidence': [
            {'message_id': 'u1', 'quote': '我现在咖啡喝无糖。'},
          ],
        },
      ],
  'completion': 'complete',
};

MemoryRow copy(MemoryRow value) => jsonDecode(jsonEncode(value)) as MemoryRow;
MemoryRow firstOperation(MemoryRow value) => (value['operations']! as List<Object?>).first! as MemoryRow;

MemorySelection select(List<MemoryRow> cards, String input, {Set<String> explicit = const {}, int limit = 6}) =>
    selectMemoryContext(cards, input: input, nowMs: 1000, controlRevision: 4, explicitTopicIds: explicit, limit: limit);

void main() {
  group('09s D followup response envelope', () {
    test('a single line is returned verbatim and silent is distinct from an empty line', () {
      const line = '你说过的那间朝南的房，今天想聊聊吗？';
      expect(parseFollowupProposal(jsonEncode({'action': 'line', 'text': line})), line);
      expect(parseFollowupProposal('{"action":"silent","text":""}'), isNull);
    });

    for (final entry in <String, Object?>{
      'missing text': {'action': 'line'},
      'extra topic authority': {'action': 'line', 'text': '想聊聊吗？', 'topic': 'other'},
      'empty line': {'action': 'line', 'text': ''},
      'blank line': {'action': 'line', 'text': '  '},
      'silent with words': {'action': 'silent', 'text': '也许下次'},
      'unknown action': {'action': 'ask', 'text': '想聊聊吗？'},
      'multiline': {'action': 'line', 'text': '那件事\n想聊聊吗？'},
      'next line': {'action': 'line', 'text': '那件事\u0085想聊聊吗？'},
      'unicode line break': {'action': 'line', 'text': '那件事\u2028想聊聊吗？'},
      'two questions': {'action': 'line', 'text': '怎样了？顺利吗?'},
      'control character': {'action': 'line', 'text': '那件事\u0000怎样了？'},
      'wrong text type': {'action': 'line', 'text': 123},
      'array envelope': <Object?>[],
    }.entries) {
      test('rejects ${entry.key}', () {
        expect(() => parseFollowupProposal(jsonEncode(entry.value)), throwsFormatException);
      });
    }

    test('prose or fenced JSON is not repaired into permission to speak', () {
      for (final raw in ['今天想聊聊吗？', '```json\n{"action":"line","text":"想聊聊吗？"}\n```']) {
        expect(() => parseFollowupProposal(raw), throwsFormatException);
      }
    });
  });

  group('B literal invitation and original local date', () {
    MemoryRow? plan(
      String text,
      String wording, {
      String? date,
      String precision = 'day',
      String saidAt = '2026-11-16T04:00:00Z',
      MemoryRow? eventTime,
      int? editedAt,
    }) => qualifyMemoryFollowup(
      {
        'text': text.split(RegExp(r'[，,。；;\n]')).first,
        'keywords': [
          for (final word in ['修琴', '换组', '琴', '陶杯', '册子', '那间朝南的房', '试音会'])
            if (text.contains(word)) word,
        ],
        'event_time': eventTime,
        'followup': {'basis': 'explicit_invitation', 'wording': wording, 'local_date': date, 'precision': precision},
      },
      {...source('invitation', text, editedAt: editedAt), 'said_at_utc': DateTime.parse(saidAt).millisecondsSinceEpoch},
    );
    int utc(String value) => DateTime.parse(value).millisecondsSinceEpoch;

    test('D1 and D2 use the invitation day; D3 with only an event day starts the following local day', () {
      final d1 = plan(
        '周日打算看那间朝南的房。周一你可以问问我。',
        '周一你可以问问我',
        date: '2026-11-23',
        saidAt: '2026-11-20T04:00:00Z',
        eventTime: {'local_date': '2026-11-22', 'precision': 'day', 'wording': '周日'},
      )!;
      expect(d1['opens_at_ms'], utc('2026-11-22T16:00:00Z'));
      final d2 = plan('周五来问我想不想聊换组。别问原因。', '周五来问我想不想聊换组', date: '2026-11-20', saidAt: '2026-11-18T01:00:00Z')!;
      expect(d2['opens_at_ms'], utc('2026-11-19T16:00:00Z'));
      final d3 = plan(
        '周四我打算去听试音会，过后你可以问问我。',
        '过后你可以问问我',
        precision: 'unspecified',
        saidAt: '2026-11-16T02:00:00Z',
        eventTime: {'local_date': '2026-11-19', 'precision': 'day', 'wording': '周四'},
      )!;
      expect(d3['opens_at_ms'], utc('2026-11-19T16:00:00Z'));
      for (final value in [d1, d2, d3]) {
        expect(value['expires_at_ms'], (value['opens_at_ms'] as int) + memoryFollowupWindowMs);
        expect(value['local_line'], isNull);
      }
    });

    test('late extraction and source edits cannot move tomorrow to the processing date', () {
      const raw = '明天可以问我修琴的进展';
      final edited = utc('2026-11-20T02:00:00Z');
      final value = plan(raw, '明天可以问我修琴的进展', date: '2026-11-17', saidAt: '2026-11-16T15:55:00Z', editedAt: edited)!;
      expect(value['opens_at_ms'], utc('2026-11-16T16:00:00Z'));
      final mismatch = plan(raw, '明天可以问我修琴的进展', date: '2026-11-21', saidAt: '2026-11-16T15:55:00Z', editedAt: edited)!;
      expect(mismatch['opens_at_ms'], isNull);
      expect(mismatch['reason'], 'date_mismatch');
    });

    test('vague time of day is never assigned 15:00 or opened early by a model day label', () {
      const raw = '明天下午可以问我修琴的进展';
      for (final precision in ['part_of_day', 'day']) {
        final value = plan(raw, raw, date: '2026-11-17', precision: precision)!;
        expect(value['opens_at_ms'], utc('2026-11-17T16:00:00Z'));
        expect(value['time_key'], 'day:2026-11-18');
      }
      final today = plan('今天可以问我修琴的进展', '今天可以问我修琴的进展', date: '2026-11-16')!;
      expect(
        today['opens_at_ms'],
        utc('2026-11-16T04:00:00Z'),
        reason: 'permission cannot open before the person said it',
      );
      final past = plan('本周一可以问我修琴的进展', '本周一可以问我修琴的进展', date: '2026-11-16', saidAt: '2026-11-20T04:00:00Z')!;
      expect(past['opens_at_ms'], isNull);
      expect(past['reason'], 'date_before_invitation');
    });

    test('D4 waits for direct completion; D5 is eligible to draft but has no fabricated local wording', () {
      final d4 = plan('册子校对的事，等我说结束再问我想不想聊。', '等我说结束再问我想不想聊', precision: 'unspecified')!;
      expect(d4['wait_subject'], '册子校对');
      expect(d4['opens_at_ms'], isNull);
      expect(d4['reason'], 'waiting_for_completion');
      expect(isMemoryFollowupCompletion('册子校对', '那本册子的校对结束了。'), isTrue);
      for (final text in ['我朋友说那本册子的校对结束了。', '那本册子的校对还没结束。', '那本册子的校对结束了？', '那本册子的校对和海报结束了。', '如果那本册子的校对结束了']) {
        expect(isMemoryFollowupCompletion('册子校对', text), isFalse, reason: text);
      }
      final d5 = plan(
        '周六可以问问陶杯烧得怎样。开口第一句必须先叫它我给它取的小名，别另起名字。',
        '周六可以问问陶杯烧得怎样',
        date: '2026-11-21',
        saidAt: '2026-11-17T02:00:00Z',
      )!;
      expect(d5['local_line'], isNull);
      expect(d5['opens_at_ms'], utc('2026-11-20T16:00:00Z'));
      expect(d5['reason'], isNull);
    });

    test('known recipients immediately after ask do not authorize a question to the person', () {
      for (final raw in [
        '周五可以问医生修琴的进展',
        '周五可以问问医生修琴的进展',
        '周五可以问我妈修琴的进展',
        '周五可以问问我妈修琴的进展',
      ]) {
        expect(plan(raw, raw, date: '2026-11-20'), isNull, reason: raw);
      }
    });

    test('asking the person about a doctor remains a literal invitation', () {
      const raw = '周五可以问我医生的建议';
      final value = plan(raw, raw, date: '2026-11-20')!;
      expect(value['opens_at_ms'], utc('2026-11-19T16:00:00Z'));
      expect(value['reason'], isNull);
    });

    test('a rejected recipient head still prevents a second head from becoming unique', () {
      const own = '周五可以问我修琴的进展';
      const other = '周六可以问医生陶杯的进展';
      for (final raw in ['$own，$other', '$other，$own']) {
        expect(plan(raw, own, date: '2026-11-20'), isNull, reason: raw);
      }
    });

    test('a model invitation label cannot authorize quotations, reminders, another person or multiple invitations', () {
      const wording = '周五可以问我修琴的进展';
      for (final raw in [
        '如果$wording',
        '“$wording”是台词',
        '朋友说$wording',
        '$wording，但不要问我',
        '$wording，提醒我带琴',
        '$wording，周六可以问我陶杯',
      ]) {
        expect(plan(raw, wording, date: '2026-11-20'), isNull, reason: raw);
      }
      for (final raw in ['周五可以问你修琴的进展', '周五可以问我修琴的进展吗？']) {
        expect(plan(raw, raw, date: '2026-11-20'), isNull, reason: raw);
      }
      expect(
        qualifyMemoryFollowup({
          'event_time': {'local_date': '2026-11-19', 'precision': 'day', 'wording': '周四'},
        }, source('event-only', '周四我去修琴')),
        isNull,
      );
      final undated = plan('过后你可以问问我', '过后你可以问问我', precision: 'unspecified')!;
      expect(undated['opens_at_ms'], isNull);
    });
  });

  group('09s extraction boundary', () {
    test('card text uses the v2 bridge control-character boundary without changing verbatim evidence', () {
      for (final code in [0, 1, 8, 11, 12, 14, 31, 127]) {
        final value = proposal();
        firstOperation(value)['text'] = '咖啡${String.fromCharCode(code)}喝无糖';
        expect(() => parseExtractionProposal(jsonEncode(value), batch()), throwsFormatException);
      }
      for (final whitespace in ['\t', '\n', '\r']) {
        final value = proposal();
        firstOperation(value)['text'] = '咖啡$whitespace喝无糖';
        expect(firstOperation(parseExtractionProposal(jsonEncode(value), batch()))['text'], '咖啡$whitespace喝无糖');
      }
      const original = '我现在咖啡喝无糖。\u0007';
      final value = proposal();
      firstOperation(value)['evidence'] = [
        {'message_id': 'u1', 'quote': original},
      ];
      final kept = parseExtractionProposal(jsonEncode(value), batch(sources: [source('u1', original)]));
      expect(firstOperation(kept)['evidence'], [
        {'message_id': 'u1', 'quote': original},
      ]);
    });

    test('valid complete proposals retain their wording; omitted keywords stay empty', () {
      final value = proposal();
      final parsed = parseExtractionProposal(jsonEncode(value), batch());
      expect(parsed, value);
      firstOperation(value).remove('keywords');
      final withoutKeywords = parseExtractionProposal(jsonEncode(value), batch());
      expect(firstOperation(withoutKeywords)['keywords'], isEmpty);
      expect(firstOperation(withoutKeywords)['text'], '你现在咖啡喝无糖。');
    });

    test('a complete empty result still must cover every source in order', () {
      final two = batch(sources: [source('u1', '只是台词。'), source('u2', '不是我的经历。', sequence: 102)]);
      expect(
        parseExtractionProposal(jsonEncode(proposal(operations: [], covered: ['u1', 'u2'])), two)['operations'],
        isEmpty,
      );
      for (final covered in <List<String>>[
        [],
        ['u1'],
        ['u2', 'u1'],
        ['u1', 'u1'],
      ]) {
        expect(
          () => parseExtractionProposal(jsonEncode(proposal(operations: [], covered: covered)), two),
          throwsFormatException,
        );
      }
    });

    test('unknown fields, incomplete results and non-JSON responses never become empty success', () {
      final invalid = <MemoryRow>[
        {...proposal(), 'schema_version': 2.0},
        {...proposal(), 'batch_id': 'different'},
        {...proposal(), 'completion': 'needs_more'},
        {...proposal(), 'cursor': 200},
        {...proposal(), 'covered_message_ids': 'u1'},
        {...proposal(), 'operations': null},
      ];
      for (final value in invalid) {
        expect(() => parseExtractionProposal(jsonEncode(value), batch()), throwsFormatException);
      }
      for (final text in [
        '',
        '不想整理。',
        '{"operations":[',
        '```json\n${jsonEncode(proposal())}\n```',
        '${jsonEncode(proposal())}\n好了',
      ]) {
        expect(() => parseExtractionProposal(text, batch()), throwsFormatException);
      }
    });

    test('each fact needs a verbatim quote from the referenced real user version', () {
      for (final evidence in <Object?>[
        [],
        [
          {'message_id': 'other', 'quote': '我现在咖啡喝无糖。'},
        ],
        [
          {'message_id': 'u1', 'quote': '我以前咖啡喝无糖。'},
        ],
        [
          {'message_id': 'u1', 'quote': ''},
        ],
        [
          {'message_id': 'u1', 'quote': '我现在咖啡喝无糖。', 'source_rev': 1},
        ],
      ]) {
        final value = proposal();
        firstOperation(value)['evidence'] = evidence;
        expect(() => parseExtractionProposal(jsonEncode(value), batch()), throwsFormatException);
      }
      for (final changed in <MemoryRow>[
        {...source('u1', '我现在咖啡喝无糖。'), 'role': 'assistant'},
        {...source('u1', '我现在咖啡喝无糖。'), 'scope': 'story'},
      ]) {
        expect(() => parseExtractionProposal(jsonEncode(proposal()), batch(sources: [changed])), throwsFormatException);
      }
    });

    test('keywords cannot borrow another message or invent an absent alias', () {
      final two = batch(sources: [source('u1', '我现在咖啡喝无糖。'), source('u2', '我还弹钢琴。', sequence: 102)]);
      for (final words in <List<Object?>>[
        ['钢琴'],
        ['去糖'],
        ['咖啡', '咖啡'],
        [''],
        [null],
        List.filled(9, '咖啡'),
      ]) {
        final value = proposal(covered: ['u1', 'u2']);
        firstOperation(value)['keywords'] = words;
        expect(() => parseExtractionProposal(jsonEncode(value), two), throwsFormatException);
      }
      final ascii = proposal();
      firstOperation(ascii)
        ..['text'] = '你喜欢 coffee。'
        ..['keywords'] = ['coffee']
        ..['evidence'] = [
          {'message_id': 'u1', 'quote': '我喜欢 COFFEE。'},
        ];
      expect(parseExtractionProposal(jsonEncode(ascii), batch(sources: [source('u1', '我喜欢 COFFEE。')])), ascii);
    });

    test('create cannot carry replacement authority or set controls and pinning', () {
      for (final extra in <MemoryRow>[
        {'target_id': 'k1'},
        {'expected_row_rev': 8},
        {'change_kind': 'new_current_value'},
        {'pinned': true},
        {'topic_mode': 'never'},
        {'scope': 'story'},
      ]) {
        final value = proposal();
        firstOperation(value).addAll(extra);
        expect(() => parseExtractionProposal(jsonEncode(value), batch()), throwsFormatException);
      }
      for (final change in <MemoryRow>[
        {'op': 'delete'},
        {'kind': 'identity'},
        {'text': String.fromCharCode(0xd800)},
      ]) {
        final value = proposal();
        firstOperation(value).addAll(change);
        expect(() => parseExtractionProposal(jsonEncode(value), batch()), throwsFormatException);
      }
    });

    test('replace targets the captured row revision; the store must recheck its current revision', () {
      final current = batch(existing: [card('k1', '你现在咖啡喝半糖。', kind: 'preference')]);
      final value = proposal();
      firstOperation(
        value,
      ).addAll({'op': 'replace', 'target_id': 'k1', 'expected_row_rev': 8, 'change_kind': 'correction_of_error'});
      expect(parseExtractionProposal(jsonEncode(value), current), value);
      for (final change in <MemoryRow>[
        {'target_id': 'missing'},
        {'expected_row_rev': 7},
        {'expected_row_rev': 8.0},
        {'change_kind': 'mark_historical'},
      ]) {
        final changed = copy(value);
        firstOperation(changed).addAll(change);
        expect(() => parseExtractionProposal(jsonEncode(changed), current), throwsFormatException);
      }
      final repeated = copy(value);
      (repeated['operations']! as List<Object?>).add(copy(firstOperation(value)));
      expect(() => parseExtractionProposal(jsonEncode(repeated), current), throwsFormatException);
    });

    test('event and invitation wording anchor to the first quote and preserve vague time', () {
      const words = '小露，我明天下午去纸展。周四你可以问问我。';
      final value = proposal(
        operations: [
          {
            'op': 'create',
            'kind': 'episode',
            'text': '你打算11月17日下午去纸展。',
            'keywords': ['纸展'],
            'evidence': [
              {'message_id': 'u1', 'quote': words},
            ],
            'event_time': {'local_date': '2026-11-17', 'precision': 'part_of_day', 'wording': '明天下午'},
            'followup': {
              'basis': 'explicit_invitation',
              'local_date': '2026-11-19',
              'precision': 'day',
              'wording': '周四你可以问问我',
            },
          },
        ],
      );
      final current = batch(sources: [source('u1', words)]);
      expect(parseExtractionProposal(jsonEncode(value), current), value);
      for (final date in ['2026-02-29', '2026-13-01', '2026-11-00', '2026-1-17', 'null']) {
        final changed = copy(value);
        (firstOperation(changed)['event_time']! as MemoryRow)['local_date'] = date;
        expect(() => parseExtractionProposal(jsonEncode(changed), current), throwsFormatException);
      }
      final unknown = copy(value);
      (firstOperation(unknown)['event_time']! as MemoryRow)['local_date'] = null;
      expect(parseExtractionProposal(jsonEncode(unknown), current), unknown);
      for (final change in <MemoryRow>[
        {'wording': '明天下午三点'},
        {'precision': 'hour'},
        {'hour': 15},
      ]) {
        final changed = copy(value);
        (firstOperation(changed)['event_time']! as MemoryRow).addAll(change);
        expect(() => parseExtractionProposal(jsonEncode(changed), current), throwsFormatException);
      }
      final changed = copy(value);
      (firstOperation(changed)['followup']! as MemoryRow)['basis'] = 'date_only';
      expect(() => parseExtractionProposal(jsonEncode(changed), current), throwsFormatException);

      final split = proposal(covered: ['u1', 'u2']);
      firstOperation(split)
        ..['evidence'] = [
          {'message_id': 'u1', 'quote': '我现在咖啡喝无糖。'},
          {'message_id': 'u2', 'quote': '周四你可以问问我。'},
        ]
        ..['followup'] = {
          'basis': 'explicit_invitation',
          'local_date': '2026-11-19',
          'precision': 'day',
          'wording': '周四你可以问问我',
        };
      final splitBatch = batch(sources: [source('u1', '我现在咖啡喝无糖。'), source('u2', '周四你可以问问我。', sequence: 102)]);
      expect(() => parseExtractionProposal(jsonEncode(split), splitBatch), throwsFormatException);
    });

    test('delayed and edited sources send their original UTC and offset, not the processing day', () {
      final edited = DateTime.parse('2026-11-18T01:00:00Z').millisecondsSinceEpoch;
      final processed = DateTime.parse('2026-11-18T02:00:00Z').millisecondsSinceEpoch;
      final current = batch(
        sources: [source('u1', '小露，我明天下午去纸展。', revision: 2, editedAt: edited)],
        existing: [card('k1', '你现在咖啡喝半糖。')],
      );
      final request = extractionInput(current, processedAtUtc: processed);
      final sent = (request['source']! as List<Object?>).single! as MemoryRow;
      expect(sent, {
        'id': 'u1',
        'first_seq': 101,
        'source_rev': 2,
        'said_at_utc': '2026-11-16T15:30:00.000Z',
        'offset_minutes': 480,
        'text': '小露，我明天下午去纸展。',
        'edited_at_utc': '2026-11-18T01:00:00.000Z',
      });
      expect(request['processed_at_utc'], '2026-11-18T02:00:00.000Z');
      expect((request['existing']! as List<Object?>).single, {
        'id': 'k1',
        'row_rev': 8,
        'kind': 'fact',
        'text': '你现在咖啡喝半糖。',
        'current_basis_seq': 102,
      });
      expect(request.containsKey('control_revision'), isFalse);
    });

    test('current-value order distinguishes old edits, hand edits and later independent statements', () {
      expect(canApplyMemoryCurrentValue(proposedBasisSeq: 101, currentBasisSeq: 102), isFalse);
      expect(canApplyMemoryCurrentValue(proposedBasisSeq: 104, currentBasisSeq: 102), isTrue);
      expect(canApplyMemoryCurrentValue(proposedBasisSeq: 101, currentBasisSeq: 101), isTrue);
      expect(canApplyMemoryCurrentValue(proposedBasisSeq: 101, currentBasisSeq: null), isTrue);
    });
  });

  group('09e-r2 two-pass recall', () {
    MemoryRow listening({String id = 'p', String mode = 'normal', List<String> keywords = const ['先听', '讲完', '建议']}) =>
        card(
          id,
          '先听我讲完，再给建议。',
          kind: 'preference',
          pinned: true,
          keywords: keywords,
          mode: mode,
          evidence: [support('先听我讲完，再给建议。')],
        );

    test('a zero-hit response preference remains before a matching topic', () {
      final result = select([
        card('c', '你这周在准备面试。', keywords: ['这周', '准备', '面试']),
        listening(),
      ], '今天面试真烦。');
      expect(result.ids, ['p', 'c']);
      expect(result.controlRevision, 4);
      expect(jsonDecode(result.block), {
        'type': 'companion_memory',
        'version': 2,
        'scope': 'real',
        'items': [
          {'id': 'p', 'kind': 'preference', 'text': '先听我讲完，再给建议。'},
          {'id': 'c', 'kind': 'fact', 'text': '你这周在准备面试。'},
        ],
      });
    });

    test('both passes share six slots; a third matching preference can join pass two once', () {
      final result = select([
        listening(id: 'p1'),
        listening(id: 'p2'),
        listening(id: 'p3'),
        for (var i = 0; i < 6; i++) card('c$i', '练习建议$i', keywords: ['建议']),
      ], '给我建议');
      expect(result.ids, hasLength(6));
      expect(result.ids.take(3), ['p1', 'p2', 'p3']);
      expect(result.ids.toSet(), hasLength(6));
      expect(select([listening()], '建议').ids, ['p']);
      final short = [
        for (var i = 0; i < 13; i++) card('m$i', '琴', keywords: ['琴课']),
      ];
      expect(select(short, '琴课', limit: 12).ids, hasLength(12));
      expect(() => select(short, '琴课', limit: 13), throwsArgumentError);
    });

    test('pinned birthday, taste and unsupported preference wording are not response fallback', () {
      final rows = [
        card('birthday', '你生日在六月。', pinned: true, keywords: ['生日']),
        card('taste', '你喜欢无糖拿铁。', kind: 'preference', pinned: true, keywords: ['无糖'], evidence: [support('我喜欢无糖拿铁。')]),
        card('mixed-source', '你喜欢无糖拿铁。', kind: 'preference', pinned: true, evidence: [support('我喜欢无糖拿铁。先听我讲完，再给建议。')]),
        card('taste-result', '你希望咖啡最后的结果是无糖。', kind: 'preference', pinned: true, evidence: [support('我希望咖啡最后的结果是无糖。')]),
        card(
          'assistant',
          '先听我讲完，再给建议。',
          kind: 'preference',
          pinned: true,
          evidence: [
            {...support('先听我讲完，再给建议。'), 'role': 'assistant'},
          ],
        ),
        card('story', '先听我讲完，再给建议。', kind: 'preference', pinned: true, evidence: [support('剧本台词是“先听我讲完，再给建议”。')]),
      ];
      expect(select(rows, '你好').ids, isEmpty);
      expect(select(rows, '无糖').ids, ['taste']);
    });

    test('less disables fallback but permits matches; never needs an explicit current invitation', () {
      expect(select([listening(mode: 'less')], '你好').ids, isEmpty);
      expect(select([listening(mode: 'less')], '给我建议').ids, ['p']);
      final muted = card('interview', '你当时打算周四面试。', keywords: ['面试'], pinned: true, mode: 'never');
      expect(select([muted], '面试').ids, isEmpty);
      expect(select([muted], '上次面试是哪天？', explicit: {'interview'}).ids, ['interview']);
      expect(muted['topic_mode'], 'never');
      expect(select([muted], '面试').ids, isEmpty);
    });

    test('reality, current support, expiry and explicit past wording precede ranking', () {
      final rows = [
        card('story', '你是校长。', keywords: ['称呼'], scope: 'story', pinned: true),
        card('unknown', '你的称呼不明。', keywords: ['称呼'], eligible: false),
        card('withdrawn', '你以前叫阿蓝。', keywords: ['称呼'], status: 'withdrawn'),
        card('expired', '你的称呼是阿蓝。', keywords: ['称呼'], expiresAt: 1000),
        card('past-current-wording', '你的称呼是阿蓝。', keywords: ['称呼'], status: 'past', evidence: [support('我叫阿蓝。')]),
        card('past', '你以前的称呼是阿蓝。', keywords: ['称呼'], status: 'past', evidence: [support('我以前叫阿蓝。')]),
        card('current', '你的称呼是阿橙。', keywords: ['称呼'], sourceAt: 200),
      ];
      expect(select(rows, '称呼').ids, ['current', 'past']);
    });

    test('legacy malformed automatic text cannot produce a block rejected by the v2 bridge', () {
      final rows = [
        for (final code in [0, 1, 8, 11, 12, 14, 31, 127])
          card('bad-$code', '咖啡${String.fromCharCode(code)}喝无糖', keywords: ['咖啡']),
        card('valid', '咖啡\n喝无糖', keywords: ['咖啡']),
      ];
      expect(select(rows, '咖啡').ids, ['valid']);
      expect((jsonDecode(select(rows, '咖啡').block) as Map)['items'], [
        {'id': 'valid', 'kind': 'fact', 'text': '咖啡\n喝无糖'},
      ]);
    });

    test('ranking caps distinct hits at two and uses effective source time, not model arrival', () {
      final rows = [
        card('z', '两词新。', keywords: ['面试', '准备'], sourceAt: 300),
        card('a', '两词旧。', keywords: ['面试', '准备'], sourceAt: 100),
        card('b', '三词不额外加分。', keywords: ['面试', '准备', '这周'], sourceAt: 100),
        card('pin', '两词置顶。', keywords: ['面试', '准备'], pinned: true, sourceAt: 1),
        card('repeat', '重复词只计一次。', keywords: ['面试', '面试'], pinned: true, sourceAt: 999),
      ];
      expect(select(rows, '这周准备面试').ids, ['pin', 'z', 'a', 'b', 'repeat']);
    });

    test('matching only folds whitespace and ASCII case, with ASCII word boundaries', () {
      final coffee = card('coffee', 'coffee', keywords: ['COFFEE']);
      expect(select([coffee], 'Have\n COFFEE today').ids, ['coffee']);
      expect(select([coffee], 'coffees').ids, isEmpty);
      expect(select([coffee], 'noncoffee').ids, isEmpty);
      expect(select([coffee], 'ＣＯＦＦＥＥ').ids, isEmpty);
      expect(normalizeMemoryText('  A\u3000Ｂ\nÉ '), 'a Ｂ É');
      expect(
        select([
          card('sugar', '糖', keywords: ['糖']),
        ], '糖').ids,
        isEmpty,
      );
      expect(
        select([
          card('sugar', '无糖', keywords: ['无糖']),
        ], '我喝无糖').ids,
        ['sugar'],
      );
      expect(
        select([
          card('punctuation', '??', keywords: ['??']),
        ], '??').ids,
        isEmpty,
      );
    });

    test('keywordless manual cards use the entire literal input only in pass two', () {
      final manual = card('m', '我的咖啡甜度是无糖', manual: true);
      expect(select([manual], '咖啡甜度').ids, ['m']);
      expect(select([manual], '咖啡甜度？').ids, isEmpty);
      expect(select([manual], '照平常的点').ids, isEmpty);
      expect(
        select([
          {...manual, 'text': '练琴在周五'},
        ], '咖啡甜度').ids,
        isEmpty,
      );
      expect(
        select([
          {...manual, 'text': '我最近的咖啡甜度是无糖'},
        ], '最近').ids,
        ['m'],
      );
      expect(
        select([
          {
            ...manual,
            'keywords': ['拿铁'],
          },
        ], '咖啡甜度').ids,
        isEmpty,
      );
      expect(
        select([
          {...manual, 'manual': false},
        ], '咖啡甜度').ids,
        isEmpty,
      );
      expect(
        select([
          {...manual, 'topic_mode': 'never'},
        ], '咖啡甜度').ids,
        isEmpty,
      );
      expect(
        select([
          {...manual, 'eligible': false},
        ], '咖啡甜度').ids,
        isEmpty,
      );
      expect(
        select([
          {...manual, 'pinned': true},
        ], '你好').ids,
        isEmpty,
      );
    });

    test('the serialized block accepts 1200 scalars including emoji and escaping; 1201 skips the whole card', () {
      const prefix = '😀"e\u0301';
      final emptyEnvelope = jsonEncode({
        'type': 'companion_memory',
        'version': 2,
        'scope': 'real',
        'items': [
          {'id': 'long', 'kind': 'fact', 'text': ''},
        ],
      });
      final escapedPrefix = jsonEncode(prefix).runes.length - 2;
      final text = prefix + List.filled(1200 - emptyEnvelope.runes.length - escapedPrefix, '鲸').join();
      final long = card('long', text, keywords: ['长笛'], sourceAt: 200);
      final exact = select([long], '长笛');
      expect(exact.ids, ['long']);
      expect(exact.block.runes.length, 1200);
      expect(exact.block.length, greaterThan(1200));
      final tooLong = {...long, 'text': '$text界'};
      expect(select([tooLong], '长笛').ids, isEmpty);
      expect(
        select([
          tooLong,
          card('short', '你学长笛。', keywords: ['长笛']),
        ], '长笛').ids,
        ['short'],
      );
      expect((jsonDecode(exact.block) as MemoryRow)['items'], [
        {'id': 'long', 'kind': 'fact', 'text': text},
      ]);
    });

    test('overlong first-pass cards do not prevent later fitting preferences', () {
      final huge = listening(id: 'a')..['text'] = '先听我讲完，再给建议。${List.filled(1300, '鲸').join()}';
      expect(select([huge, listening(id: 'b'), listening(id: 'c')], '你好').ids, ['b', 'c']);
    });

    test('a new empty selection carries no previous-turn items', () {
      final flute = card('flute', '你学长笛。', keywords: ['长笛']);
      expect(select([flute], '长笛').ids, ['flute']);
      final empty = select([flute], '你好');
      expect(empty.ids, isEmpty);
      expect(jsonDecode(empty.block), {'type': 'companion_memory', 'version': 2, 'scope': 'real', 'items': []});
    });
  });

  group('explicit control targeting', () {
    final interview = card('interview', '你周四有蓝桥面试。', keywords: ['蓝桥', '面试']);
    final music = card('music', '你周五上琴课。', keywords: ['琴课']);

    test('forgetting an errand remains chat even when a memory keyword matches', () {
      final cards = [
        card('umbrella', '我出门会带伞。', keywords: ['带伞']),
        card('keys', '我出门会带钥匙。', keywords: ['带钥匙']),
      ];
      for (final input in ['忘了带伞。', '忘记带钥匙了', '我忘了带伞。', '把带伞忘了', '别记错带伞了']) {
        expect(parseMemoryControl(input, cards), isNull, reason: input);
      }
    });

    test('only explicit forget requests select the resolved memory', () {
      final cards = [
        card('umbrella', '我出门会带伞。', keywords: ['带伞']),
        card('keys', '我出门会带钥匙。', keywords: ['带钥匙']),
      ];
      for (final input in ['忘掉带伞。', '请忘掉带伞。', '把带伞忘了吧', '别记带伞了']) {
        final result = parseMemoryControl(input, cards)!;
        expect(result['kind'], 'forget', reason: input);
        expect(result['topic_ids'], ['umbrella'], reason: input);
        expect(result['target_card_ids'], ['umbrella'], reason: input);
        expect(result['ambiguous'], isFalse, reason: input);
        expect(result['delete_chat'], isFalse, reason: input);
      }
    });

    test('forget, never, less, cancel and reopen remain separate operations', () {
      for (final entry in {
        '忘掉蓝桥面试，聊天留着': 'forget',
        '别再提蓝桥面试。': 'never',
        '蓝桥面试少提一点': 'less',
        '蓝桥面试取消了': 'cancel',
        '蓝桥面试改期了，时间还没定': 'postpone',
        '以后可以聊蓝桥面试': 'normal',
      }.entries) {
        final result = parseMemoryControl(entry.key, [interview, music])!;
        expect(result['kind'], entry.value);
        expect(result['topic_ids'], ['interview']);
        expect(result['ambiguous'], isFalse);
        expect(result['delete_chat'], isFalse);
        expect(
          result['target_card_ids'],
          const ['forget', 'cancel', 'postpone'].contains(entry.value) ? ['interview'] : isEmpty,
        );
      }
      expect(parseMemoryControl('忘掉蓝桥面试，连原话也删', [interview])!['delete_chat'], isTrue);
    });

    test('fact commands retain the exact card even when independent facts share an expression topic', () {
      final sugar = card('sugar', '我咖啡喝半糖', keywords: ['咖啡']);
      final morning = {
        ...card('morning', '我只在上午喝咖啡', keywords: ['咖啡']),
        'topic_id': 'sugar',
      };
      for (final input in ['忘掉我咖啡喝半糖', '我咖啡喝半糖取消了']) {
        final result = parseMemoryControl(input, [sugar, morning])!;
        expect(result['topic_ids'], ['sugar']);
        expect(result['target_card_ids'], ['sugar']);
        expect(result['ambiguous'], isFalse);
      }
      for (final input in ['忘掉咖啡', '咖啡取消了']) {
        final result = parseMemoryControl(input, [sugar, morning])!;
        expect(result['ambiguous'], isTrue);
        expect(result['target_card_ids'], isEmpty);
        expect(result['topic_ids'], isEmpty);
      }
      for (final input in ['少提咖啡', '别再提咖啡', '以后可以聊咖啡']) {
        final result = parseMemoryControl(input, [sugar, morning])!;
        expect(result['topic_ids'], ['sugar']);
        expect(result['target_card_ids'], isEmpty);
        expect(result['ambiguous'], isFalse);
      }
    });

    test('quoted or hypothetical commands do not execute; unresolved references ask for scope', () {
      expect(parseMemoryControl('如果我说忘掉蓝桥面试会怎样？', [interview]), isNull);
      expect(parseMemoryControl('如果蓝桥面试取消了', [interview]), isNull);
      expect(parseMemoryControl('剧本中的蓝桥面试取消了', [interview]), isNull);
      expect(parseMemoryControl('“别再提蓝桥面试”是台词。', [interview]), isNull);
      expect(parseMemoryControl('那件事少提一点', [interview])!['ambiguous'], isTrue);
      expect(parseMemoryControl('我朋友的蓝桥面试取消了', [interview])!['ambiguous'], isTrue);
      expect(parseMemoryControl('忘掉我的', [interview])!['ambiguous'], isTrue);
      expect(
        parseMemoryControl('忘掉蓝桥面试', [
          interview,
          {...interview, 'id': 'other', 'topic_id': 'other'},
        ])!['topic_ids'],
        isEmpty,
      );
      expect(parseMemoryControl('忘掉旅游', [interview])!['ambiguous'], isTrue);
    });

    test('explicit corrections keep the exact new wording and require one known target', () {
      final coffee = card('coffee', '我咖啡喝半糖。', keywords: ['咖啡', '半糖'], evidence: [support('我咖啡喝半糖。')]);
      final direct = parseMemoryControl('请把咖啡改成我喝 Cold Brew，  无糖。', [coffee])!;
      expect(direct['kind'], 'correct');
      expect(direct['target_card_id'], 'coffee');
      expect(direct['replacement_text'], '我喝 Cold Brew，  无糖。');
      expect(direct['ambiguous'], isFalse);
      final anchored = parseMemoryControl('你记错了，我咖啡一直喝无糖。', [coffee])!;
      expect(anchored['target_card_id'], 'coffee');
      expect(anchored['replacement_text'], '我咖啡一直喝无糖。');
      expect(
        parseMemoryControl('你记错了，我一直喝无糖。', [coffee])!['ambiguous'],
        isTrue,
        reason: 'a new sugar value alone does not name coffee',
      );
      expect(
        parseMemoryControl('你记错了，我咖啡一直喝无糖。', [
          coffee,
          {...coffee, 'id': 'other', 'topic_id': 'other'},
        ])!['ambiguous'],
        isTrue,
      );
      expect(
        parseMemoryControl('咖啡改成我一直喝无糖。', [
          {...coffee, 'scope': 'story'},
        ])!['ambiguous'],
        isTrue,
      );
      expect(parseMemoryControl('如果咖啡改成我喝无糖会怎样', [coffee]), isNull);
      expect(parseMemoryControl('“咖啡改成我喝无糖”是台词。', [coffee]), isNull);
      expect(parseMemoryControl('你记错了，我在扮演喝无糖咖啡的角色', [coffee])!['ambiguous'], isTrue);
      expect(parseMemoryControl('你记错了', [coffee])!['ambiguous'], isTrue);
    });

    test('an implicit correction anchor must survive in the current evidence, not just a keyword list', () {
      final unsupported = card('coffee', '我咖啡喝半糖。', keywords: ['咖啡'], evidence: [support('我在学长笛')]);
      expect(parseMemoryControl('你记错了，我咖啡一直喝无糖。', [unsupported])!['ambiguous'], isTrue);
      expect(
        parseMemoryControl('你记错了，我咖啡一直喝无糖。', [
          {...unsupported, 'manual': true},
        ])!['ambiguous'],
        isFalse,
      );
    });

    test('one explicit topic question grants a single selection without persistently reopening it', () {
      final muted = {...interview, 'topic_mode': 'never'};
      for (final text in ['聊聊蓝桥面试。', '我想问那次蓝桥面试', '蓝桥面试是哪天？', '蓝桥面试怎么样？']) {
        final topics = explicitMemoryTopics(text, [muted, music]);
        expect(topics, {'interview'});
        expect(select([muted], text, explicit: topics).ids, ['interview']);
      }
      for (final text in ['你好', '面试？', '如果蓝桥面试怎么样', '我想问面试这个词的英文', '“聊聊蓝桥面试”是台词']) {
        expect(explicitMemoryTopics(text, [muted]), isEmpty);
      }
      expect(
        explicitMemoryTopics('聊聊蓝桥面试', [
          muted,
          {...muted, 'id': 'second', 'topic_id': 'second'},
        ]),
        isEmpty,
      );
      expect(muted['topic_mode'], 'never');
      expect(select([muted], '蓝桥面试').ids, isEmpty);
    });

    test('a cancelled or postponed plan stays visible data but is never selected as a live plan', () {
      for (final state in ['cancelled', 'postponed']) {
        final inactive = {...interview, 'plan_state': state};
        expect(select([inactive], '蓝桥面试', explicit: {'interview'}).ids, isEmpty);
        expect(inactive['text'], '你周四有蓝桥面试。');
      }
    });
  });
}
