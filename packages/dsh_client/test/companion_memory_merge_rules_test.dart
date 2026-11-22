import 'dart:convert';

import 'package:dsh_client/companion.dart';
import 'package:test/test.dart';

MemoryRow _row(String id, int revision, String text, String message, String quote, {int day = 10}) => {
  'id': id,
  'row_rev': revision,
  'kind': 'preference',
  'text': text,
  'scope': 'real',
  'status': 'current',
  'manual': false,
  'eligible': true,
  'topic_mode': 'normal',
  'pinned': false,
  'keywords': ['原味', '酸奶'],
  'current_basis_seq': day,
  'source_at_ms': DateTime.utc(2026, 11, day, 2).millisecondsSinceEpoch,
  'event_time': null,
  'followup': null,
  'plan_state': null,
  'expires_at_ms': null,
  'evidence': <MemoryRow>[
    {
      'message_id': message,
      'source_rev': 1,
      'support_group': 'proof-$id',
      'said_at_utc': DateTime.utc(2026, 11, day, 2).millisecondsSinceEpoch,
      'offset_minutes': 480,
      'quote': quote,
      'role': 'user',
      'scope': 'real',
      'first_seq': day,
    },
  ],
};

MemoryRow _merge(MemoryRow target, MemoryRow source) => {
  'op': 'merge',
  'target_id': target['id'],
  'expected_row_rev': target['row_rev'],
  'from': <MemoryRow>[
    {'id': source['id'], 'expected_row_rev': source['row_rev']},
  ],
  'text': target['text'],
  'evidence': <MemoryRow>[
    for (final row in [target, source])
      for (final proof in (row['evidence'] as List<Object?>).cast<MemoryRow>())
        {'message_id': proof['message_id'], 'quote': proof['quote']},
  ],
};

MemoryRow _envelope(MemoryMergeBatch batch, List<MemoryRow> operations) => {
  'schema_version': 2,
  'batch_id': batch.id,
  'operations': operations,
  'completion': 'complete',
};

void main() {
  late MemoryRow first;
  late MemoryRow second;
  late MemoryMergeBatch batch;
  setUp(() {
    // Literal B1 card/quote pairs from 09s. Storage-only fields are synthetic.
    first = _row('m11', 2, '你买酸奶只选原味。', 's11', '酸奶我只买原味。');
    second = _row('m12', 4, '酸奶你只买原味的。', 's12', '我买酸奶还是只选原味。', day: 16);
    batch = MemoryMergeBatch(id: 'b1', controlRevision: 9, memoryRevision: 12, rows: [first, second]);
  });

  test('09s B1 retains the first exact sentence with both supplied citations', () {
    final parsed = parseMergeProposal(jsonEncode(_envelope(batch, [_merge(first, second)])), batch);
    final operation = (parsed['operations'] as List<MemoryRow>).single;
    expect(operation['target_id'], 'm11');
    expect(operation['text'], '你买酸奶只选原味。');
    expect(operation['evidence'], [
      {'message_id': 's11', 'quote': '酸奶我只买原味。'},
      {'message_id': 's12', 'quote': '我买酸奶还是只选原味。'},
    ]);
    // Different dates of saying an enduring preference are allowed.
    expect(sameMemoryMergeConditions(first, second), isTrue);
  });

  test('09s B2 can retain the second row but cannot keep the first text under its ID', () {
    final a = _row('m21', 1, '你想让小屋叫你阿橙。', 's21', '在小屋就叫我阿橙。');
    final b = _row('m22', 3, '在小屋你希望被叫作阿橙。', 's22', '我希望在小屋里你都叫我阿橙。', day: 14);
    final input = MemoryMergeBatch(id: 'b2', controlRevision: 9, memoryRevision: 12, rows: [a, b]);
    final proposal = _envelope(input, [_merge(b, a)]);
    final parsed = parseMergeProposal(jsonEncode(proposal), input);
    expect((parsed['operations'] as List<MemoryRow>).single['text'], b['text']);
    (proposal['operations'] as List<MemoryRow>).single['text'] = a['text'];
    expect(() => parseMergeProposal(jsonEncode(proposal), input), throwsFormatException);
  });

  test('outgoing B input carries original source clocks and only its specified fields', () {
    final input = consolidationInput(batch);
    expect(input.keys, unorderedEquals(['batch_id', 'scope', 'rows']));
    expect(input['scope'], 'real');
    final rows = input['rows'] as List<MemoryRow>;
    expect(rows.first.keys, unorderedEquals(['id', 'row_rev', 'kind', 'text', 'evidence']));
    final proof = (rows.last['evidence'] as List<MemoryRow>).single;
    expect(proof, {
      'message_id': 's12',
      'source_rev': 1,
      'said_at_utc': '2026-11-16T02:00:00.000Z',
      'offset_minutes': 480,
      'quote': '我买酸奶还是只选原味。',
    });
    expect((second['evidence'] as List<MemoryRow>).single['support_group'], 'proof-m12');
  });

  test('a complete empty result is a proposal, not proof that mutable database state is current', () {
    final parsed = parseMergeProposal(jsonEncode(_envelope(batch, [])), batch);
    expect(parsed['operations'], isEmpty);
    // Current claim/control/source checks belong to commitMerge in store tests.
    expect(batch.controlRevision, 9);
  });

  final invalidEnvelopes = <String, void Function(MemoryRow)>{
    'old batch': (value) => value['batch_id'] = 'old',
    'partial completion': (value) => value['completion'] = 'needs_more',
    'non-integer schema': (value) => value['schema_version'] = 2.0,
    'extraction-only field': (value) => value['covered_message_ids'] = ['s11', 's12'],
  };
  for (final scenario in invalidEnvelopes.entries) {
    test('rejects ${scenario.key}', () {
      final proposal = _envelope(batch, [_merge(first, second)]);
      scenario.value(proposal);
      expect(() => parseMergeProposal(jsonEncode(proposal), batch), throwsFormatException);
    });
  }

  final invalidMerges = <String, void Function(MemoryRow)>{
    'new sentence': (value) => value['text'] = '以后所有口味都只买原味。',
    'mark historical': (value) => value['op'] = 'mark_historical',
    'extra model authority': (value) => value['pinned'] = true,
    'unknown target': (value) => value['target_id'] = 'missing',
    'wrong target revision': (value) => value['expected_row_rev'] = 1,
    'non-integer source revision': (value) => (value['from'] as List<MemoryRow>).single['expected_row_rev'] = 4.0,
    'empty source list': (value) => value['from'] = <Object?>[],
    'two source rows': (value) => (value['from'] as List<MemoryRow>).add({'id': 'm11', 'expected_row_rev': 2}),
    'self merge': (value) => value['from'] = <MemoryRow>[
      {'id': 'm11', 'expected_row_rev': 2},
    ],
    'one-sided evidence': (value) => (value['evidence'] as List<MemoryRow>).removeLast(),
    'substring rather than supplied quote': (value) => (value['evidence'] as List<MemoryRow>).first['quote'] = '只买原味',
    'invented source': (value) => (value['evidence'] as List<MemoryRow>).last['message_id'] = 'invented',
  };
  for (final scenario in invalidMerges.entries) {
    test('rejects ${scenario.key}', () {
      final operation = _merge(first, second);
      scenario.value(operation);
      expect(() => parseMergeProposal(jsonEncode(_envelope(batch, [operation])), batch), throwsFormatException);
    });
  }

  test('citations cannot be borrowed from an unrelated third row in this same batch', () {
    final third = _row('m13', 1, '你喜欢橙子。', 's13', '我喜欢橙子。');
    final input = MemoryMergeBatch(id: 'batch', controlRevision: 9, memoryRevision: 12, rows: [first, second, third]);
    final operation = _merge(first, second);
    (operation['evidence'] as List<MemoryRow>).add({'message_id': 's13', 'quote': '我喜欢橙子。'});
    expect(() => parseMergeProposal(jsonEncode(_envelope(input, [operation])), input), throwsFormatException);
  });

  test('two disjoint merges are allowed, while reusing any target or source is not', () {
    final third = _row('m13', 1, '你喜欢橙子。', 's13', '我喜欢橙子。');
    final fourth = _row('m14', 1, '橙子是你喜欢的水果。', 's14', '橙子是我喜欢的水果。');
    final input = MemoryMergeBatch(
      id: 'batch',
      controlRevision: 9,
      memoryRevision: 12,
      rows: [first, second, third, fourth],
    );
    final valid = _envelope(input, [_merge(first, second), _merge(fourth, third)]);
    expect(parseMergeProposal(jsonEncode(valid), input)['operations'], hasLength(2));
    final reused = _envelope(input, [_merge(first, second), _merge(third, first)]);
    expect(() => parseMergeProposal(jsonEncode(reused), input), throwsFormatException);
  });

  test('manual cards without original chat cannot obtain fabricated consolidation citations', () {
    first['manual'] = true;
    second['manual'] = true;
    first['evidence'] = <MemoryRow>[];
    second['evidence'] = <MemoryRow>[];
    expect((consolidationInput(batch)['rows'] as List<MemoryRow>).map((row) => row['evidence']), [[], []]);
    final operation = _merge(first, second);
    operation['evidence'] = [
      {'message_id': 'old-entry', 'quote': '酸奶我只买原味。'},
    ];
    expect(() => parseMergeProposal(jsonEncode(_envelope(batch, [operation])), batch), throwsFormatException);
  });

  test('represented period and condition differences reject a merge even if the model keeps target text', () {
    first['event_time'] = {'local_date': '2026-11-20', 'precision': 'day', 'wording': '周五'};
    second['event_time'] = {'wording': '周五', 'precision': 'day', 'local_date': '2026-11-20'};
    expect(sameMemoryMergeConditions(first, second), isTrue); // JSON key order is irrelevant.
    (second['event_time'] as MemoryRow)['local_date'] = '2026-11-27';
    expect(
      () => parseMergeProposal(jsonEncode(_envelope(batch, [_merge(first, second)])), batch),
      throwsFormatException,
    );
    second['event_time'] = first['event_time'];
    second['followup'] = {
      'local_date': '2026-11-21',
      'precision': 'day',
      'wording': '过后问问我',
      'basis': 'explicit_invitation',
    };
    expect(sameMemoryMergeConditions(first, second), isFalse);
    second['followup'] = null;
    second['status'] = 'past';
    expect(sameMemoryMergeConditions(first, second), isFalse);
    second['status'] = 'current';
    second['topic_mode'] = 'less';
    expect(sameMemoryMergeConditions(first, second), isFalse);
  });

  test('a birthday-to-all-days rewrite and an invented successful outcome are not consolidation', () {
    final daily = _row('m31', 2, '你平常点无糖拿铁。', 's31', '我平常喝拿铁不加糖。');
    final birthday = _row('m32', 1, '你生日这杯拿铁要半糖。', 's32', '生日这杯拿铁，我想喝半糖。', day: 17);
    final input = MemoryMergeBatch(id: 'b3', controlRevision: 9, memoryRevision: 12, rows: [daily, birthday]);
    for (final rewrite in ['以后所有日子都加糖。', '你的面试已经成功。']) {
      final operation = _merge(daily, birthday)..['text'] = rewrite;
      expect(() => parseMergeProposal(jsonEncode(_envelope(input, [operation])), input), throwsFormatException);
    }
    // The parser checks retention/source/version contracts. It is not a model
    // replay claiming that all naturally worded exceptions are recognized.
  });

  test('complete connected groups include every old card when one card joins two literal edges', () {
    final a = _row('a', 3, '你的琴课在周五。', 'a-source', '琴课周五上。')
      ..['keywords'] = ['琴课', '周五']
      ..['maintenance_row_rev'] = 3;
    final b = _row('b', 2, '你每周去上琴课。', 'b-source', '我每周有琴课。')
      ..['keywords'] = ['琴课']
      ..['maintenance_row_rev'] = 2;
    final c = _row('c', 1, '星期五那天你有课。', 'c-source', '周五有课。')
      ..['keywords'] = ['周五']
      ..['maintenance_row_rev'] = 0;
    final groups = memoryMergeGroups([a, b, c]);
    expect(groups, hasLength(1));
    expect(groups.single.map((row) => row['id']), ['a', 'b', 'c']);
    // No A/B then C/A pairing can mark B/C as examined without sending them.
    // The store budget test must send this entire group or keep it unchecked.
  });

  test('candidate groups exclude unsupported keywords and keep represented conditions apart', () {
    first['keywords'] = ['酸奶', '想象词'];
    second['keywords'] = ['想象词'];
    expect(memoryMergeGroups([first, second]), isEmpty);
    second['keywords'] = ['酸奶'];
    expect(memoryMergeGroups([first, second]), hasLength(1));
    second['plan_state'] = 'postponed';
    expect(memoryMergeGroups([first, second]), isEmpty);
  });

  test('candidate heuristic does not claim universal synonym recall or local exact equivalence', () {
    final a = _row('a', 1, '你喜欢马铃薯。', 's1', '我喜欢马铃薯。')..['keywords'] = ['马铃薯'];
    final b = _row('b', 1, '土豆是你喜欢的食物。', 's2', '土豆是我喜欢的食物。')..['keywords'] = ['土豆'];
    expect(memoryMergeGroups([a, b]), isEmpty);
    b['text'] = '  你喜欢马铃薯。  ';
    expect(memoryMergeGroups([a, b]), hasLength(1));
    // Only candidate grouping normalizes text. Local exact must keep raw text
    // and source/time conditions, and parseMergeProposal still retains target.
  });
}
