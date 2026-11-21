import 'dart:convert';

import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_v4_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine snapshots merge only new counts, including after app restart', () {
    final now = DateTime.utc(2026, 11, 20, 8);
    final ledger = UsageV4Ledger();
    Map<String, dynamic> snapshot(int count) => {
      '2026-11-20': {
        'counts': [count, count, 0, 0, 0, 0, count, 0, 0, 0, 0, count, 0],
        'values': [3 * count, 5 * count, 3 * count, 5 * count, 3 * count, 0, 0, 0, 0, 0],
        'plugins': List<int>.filled(16, 0),
      },
    };
    ledger.engineSnapshot(now, 'one', snapshot(2));
    final restored = UsageV4Ledger.decode(ledger.encode());
    restored.engineSnapshot(now, 'one', snapshot(3));
    restored.engineSnapshot(now, 'one', snapshot(3));
    restored.engineSnapshot(now, 'two', snapshot(1));
    expect(restored.days.values.single.tokens[UsageTokenSource.engine]!.values[1], 20);
  });

  test('source totals stay separate and only ready episodes populate the latency bins', () {
    final now = DateTime.utc(2026, 11, 20, 18);
    final ledger = UsageV4Ledger();
    ledger.token(now, UsageTokenSource.companion, {'outputTokens': 20});
    ledger.token(now, UsageTokenSource.tavern, {'outputTokens': 8}, partial: true);
    ledger.operation(now, UsageOperation.runtimeDirect, UsageOutcome.ready, const Duration(milliseconds: 250));
    ledger.operation(now, UsageOperation.runtimeDirect, UsageOutcome.failed, const Duration(seconds: 200));
    final restored = UsageV4Ledger.decode(ledger.encode()).days.values.single;
    expect(restored.tokens[UsageTokenSource.companion]!.values[1], 20);
    expect(restored.tokens[UsageTokenSource.tavern]!.values[1], 0);
    expect(restored.tokens[UsageTokenSource.tavern]!.values[9], 8);
    expect(restored.operations[UsageOperation.runtimeDirect], [2, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  });

  test('UTC+8 day, explicit zero, missing output, invalid output and matched totals', () {
    final before = DateTime.utc(2026, 11, 20, 15, 59);
    final after = before.add(const Duration(minutes: 1));
    expect(usageV4Day(before.toLocal()), '2026-11-20');
    expect(usageV4Day(after), '2026-11-21');
    final ledger = UsageV4Ledger()..foreground(before);
    ledger.token(before, UsageTokenSource.chatLog, {
      'inputTokens': 10129,
      'outputTokens': 7,
      'cacheReadTokens': 2,
      'cacheWriteTokens': 0,
    });
    ledger.token(before, UsageTokenSource.chatLog, {'inputTokens': 25, 'outputTokens': 0});
    ledger.token(before, UsageTokenSource.chatLog, {'inputTokens': 11});
    ledger.token(before, UsageTokenSource.chatLog, {'outputTokens': -1});
    ledger.token(before, UsageTokenSource.chatLog, null);
    ledger.token(before, UsageTokenSource.chatLog, {'inputTokens': 50, 'outputTokens': 0}, partial: true);
    final day = ledger.days[ledger.due(after).single]!;
    expect(day.tokens[UsageTokenSource.chatLog]!.counts, [6, 3, 0, 1, 2, 0, 1, 1, 1, 2, 1, 2, 0]);
    expect(day.tokens[UsageTokenSource.chatLog]!.values, [10167, 7, 10156, 7, 10165, 2, 0, 1, 50, 0]);
  });

  test('switched off, a day seals the base row only and keeps no device fields', () {
    final day = DateTime.utc(2026, 11, 19, 16);
    final ledger = UsageV4Ledger()..foreground(day);
    ledger.token(day, UsageTokenSource.chatLog, {'inputTokens': 10, 'outputTokens': 2});
    final key = ledger.due(day.add(const Duration(days: 1))).single;
    final sealed = jsonDecode(
      ledger.days[key]!.seal(
        key,
        const UsageDevice(app: '1.0.21', maker: 'vivo', model: 'v2405a', rom: 'originos'),
        dailyOnly: true,
      ),
    ) as Map<String, Object?>;
    expect(sealed['base'], [1, 1]);
    expect(sealed.keys, isNot(contains('chat_log')));
    expect(sealed.keys, isNot(contains('extra')));
    expect([sealed['maker'], sealed['model'], sealed['rom']], ['', '', '']);
  });

  test('onlyDaily keeps the install id and the foreground flags, dropping the rest', () {
    final day = DateTime.utc(2026, 11, 19, 16);
    final ledger = UsageV4Ledger()..foreground(day);
    ledger.token(day, UsageTokenSource.chatLog, {'inputTokens': 10, 'outputTokens': 2});
    ledger.operation(day, UsageOperation.crash, UsageOutcome.failed, Duration.zero);
    final iid = ledger.days.values.single.iid;
    final kept = UsageV4Ledger.decode(ledger.onlyDaily().encode()).days.values.single;
    expect((kept.iid, kept.foreground, kept.first), (iid, true, true));
    expect(kept.tokens[UsageTokenSource.chatLog]!.counts[0], 0);
    expect(kept.operations, isEmpty);
  });

  test('a sealed day persists unchanged across retries, metadata changes and a clock rollback', () {
    final day = DateTime.utc(2026, 11, 19, 16);
    final next = day.add(const Duration(days: 1));
    final ledger = UsageV4Ledger()..foreground(day);
    final key = ledger.due(next).single;
    final sealed = ledger.days[key]!.seal(key, const UsageDevice(app: '1.0.21'));
    expect((jsonDecode(sealed) as Map)['base'], [1, 1]);
    final restored = UsageV4Ledger.decode(ledger.encode());
    restored.token(day, UsageTokenSource.chatLog, {'outputTokens': 10});
    expect(restored.days[key]!.seal(key, const UsageDevice(app: '2.0.0')), sealed);
    restored.days.remove(key);
    restored.foreground(day);
    expect(restored.days, isEmpty);
    restored.foreground(next);
    expect(restored.days.values.single.first, isFalse);
    expect(restored.days.values.single.iid, ledger.days[key]!.iid);
    final rotated = day.add(const Duration(days: 90));
    restored.foreground(rotated);
    final newest = restored.days[usageV4Day(rotated)]!;
    expect(newest.first, isFalse);
    expect(newest.iid, isNot(ledger.days[key]!.iid));
  });
}
