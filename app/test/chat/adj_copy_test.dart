// ADJ-COPY: two adjacent windows of the activity pill never show the same
// line, judged by the text actually shown (not by the hash index), and the
// same input always gives the same line. Started from the 023 counterexample;
// nothing here depends on the time zone the test runs in, so run it under
// several TZ values.

import 'package:dsh_app/ui/chat/activity_copy.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turn starts whose seeds do not draw the rare egg (it has its own pool).
DateTime plainStart(DateTime from) {
  var t = from;
  while (rareTurn(t)) {
    t = t.add(const Duration(milliseconds: 1));
  }
  return t;
}

/// Every window's line from [from] to [to] (slots), at three moments inside it.
List<String> shown(RunActivity a, int from, int to) {
  final start = a.since!;
  return [
    for (var slot = from; slot <= to; slot++)
      () {
        final at = [
          for (final ms in [0, 1999, 3999])
            activityFlavor(a, start.add(phraseWindow * slot + Duration(milliseconds: ms)))!.text,
        ];
        expect(at.toSet(), hasLength(1), reason: 'window $slot changed inside itself');
        return at.first;
      }(),
  ];
}

void expectNoRepeat(List<String> lines, String what) {
  for (var i = 1; i < lines.length; i++) {
    expect(lines[i], isNot(lines[i - 1]), reason: '$what: windows ${i - 1} and $i');
  }
}

void main() {
  group('the counterexample', () {
    test('ADJ-1 pickAt must not repeat the phrase it actually emitted', () {
      const pool = ['a', 'b', 'c'];
      final actual = [
        for (final s in [3, 4, 5]) pickAt(pool, 0, s),
      ];
      expect(actual[1], isNot(actual[0]), reason: 'adjacent slots 3 and 4');
      expect(actual[2], isNot(actual[1]), reason: 'adjacent slots 4 and 5');
    });

    test('ADJ-2 production retry flavor must differ at 16 and 20 seconds', () {
      final start = DateTime(2026, 10, 20, 15);
      final activity = RunActivity(kind: ActivityKind.retry, title: '重试中', since: start, turnStart: start);
      final a = activityFlavor(activity, start.add(const Duration(seconds: 16)))!;
      final b = activityFlavor(activity, start.add(const Duration(seconds: 20)))!;
      expect(b.text, isNot(a.text));
    });

    test('ADJ-3 production compaction flavor must differ at 72 and 76 seconds', () {
      final start = DateTime(2026, 10, 20, 15);
      final activity = RunActivity(kind: ActivityKind.compaction, title: '压缩中', since: start, turnStart: start);
      final a = activityFlavor(activity, start.add(const Duration(seconds: 72)))!;
      final b = activityFlavor(activity, start.add(const Duration(seconds: 76)))!;
      expect(b.text, isNot(a.text));
    });
  });

  group('pickAt', () {
    final seeds = [
      0,
      1,
      12345,
      0x7FFFFFFF,
      0xFFFFFFFF,
      DateTime.utc(2026, 10, 20, 7).millisecondsSinceEpoch,
      for (var i = 0; i < 200; i++) i * 7919 + 3,
    ];

    test('adjacent windows differ for every seed and pool size, and a window repeats itself', () {
      for (var size = 3; size <= 7; size++) {
        final pool = [for (var i = 0; i < size; i++) 'p$i'];
        for (final seed in seeds) {
          final lines = [for (var slot = 0; slot < 300; slot++) pickAt(pool, seed, slot)];
          expectNoRepeat(lines, 'size $size seed $seed');
          for (var slot = 0; slot < 300; slot += 37) {
            expect(pickAt(pool, seed, slot), lines[slot], reason: 'same input, same line');
          }
        }
      }
    });

    test('compares text: two entries reading the same count as one line', () {
      const pool = ['same', 'other', 'same', 'third'];
      for (final seed in seeds) {
        expectNoRepeat([for (var slot = 0; slot < 120; slot++) pickAt(pool, seed, slot)], 'seed $seed');
      }
    });

    test('every line of the pool still gets its turn', () {
      const pool = ['a', 'b', 'c', 'd', 'e'];
      expect({for (var slot = 0; slot < 200; slot++) pickAt(pool, 0, slot)}, pool.toSet());
    });

    test('two different lines take turns; one line is all there is', () {
      for (final seed in seeds) {
        expectNoRepeat([
          for (var slot = 0; slot < 60; slot++) pickAt(const ['x', 'y', 'x'], seed, slot),
        ], 'seed $seed');
      }
      expect(pickAt(const ['only'], 0, 9), 'only');
      expect(pickAt(const ['only', 'only'], 5, 10), 'only');
    });
  });

  group('activityFlavor, all the real pools', () {
    final starts = [
      DateTime(2026, 10, 20, 15),
      DateTime(2026, 10, 20, 15, 0, 0, 1),
      DateTime(2026, 10, 20, 9, 31, 7, 345),
      DateTime(2026, 10, 21, 18, 2, 59, 999),
    ];

    test('retry, rate limited, compaction: never the same line twice in a row', () {
      for (final start in starts) {
        for (final (kind, limited) in [
          (ActivityKind.retry, false),
          (ActivityKind.retry, true),
          (ActivityKind.compaction, false),
        ]) {
          for (final turnStart in [start, start.subtract(const Duration(seconds: 41))]) {
            final a = RunActivity(kind: kind, title: '…', since: start, turnStart: turnStart, rateLimited: limited);
            expectNoRepeat(shown(a, 0, 60), '$kind limited=$limited $start');
          }
        }
      }
    });

    test('waiting, writing, thinking through the 30 s, 1 min and 5 min pools', () {
      for (final start in starts) {
        final turnStart = plainStart(start.subtract(const Duration(seconds: 13)));
        for (final kind in [ActivityKind.waiting, ActivityKind.writing, ActivityKind.thinking]) {
          final a = RunActivity(kind: kind, title: '…', since: start, turnStart: turnStart);
          // Up to 6 min 40 s: every tier change, but short of the 10-minute reminder.
          expectNoRepeat(shown(a, 0, 100), '$kind $start');
        }
      }
    });

    test('the night pool ending at 06:00 does not repeat the line across the switch', () {
      for (var ms = 0; ms < 4000; ms += 250) {
        final start = DateTime(2026, 10, 20, 5, 59, 50).add(Duration(milliseconds: ms));
        final a = RunActivity(
          kind: ActivityKind.thinking,
          title: '思考中',
          since: start,
          turnStart: plainStart(start.subtract(const Duration(minutes: 1))),
        );
        expectNoRepeat(shown(a, 0, 7), 'start $start');
      }
    });

    test('the rare egg rotates without repeating, from its first window on', () {
      var start = DateTime(2026, 10, 20, 14, 59);
      while (!rareTurn(start)) {
        start = start.add(const Duration(milliseconds: 1));
      }
      final a = RunActivity(kind: ActivityKind.thinking, title: '思考中', since: start, turnStart: start, firstStep: true);
      final lines = shown(a, 0, 40);
      expect(rarePhrases.toSet().containsAll(lines), isTrue);
      expectNoRepeat(lines, 'rare');
    });
  });
}
