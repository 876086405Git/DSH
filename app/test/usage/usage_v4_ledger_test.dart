import 'dart:convert';

import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_v4_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UTC+8 day, explicit zero, missing output, invalid output and matched totals', () {
    final before = DateTime.utc(2026, 11, 20, 15, 59);
    final after = before.add(const Duration(minutes: 1));
    expect(usageV4Day(before.toLocal()), '2026-11-20');
    expect(usageV4Day(after), '2026-11-21');
    final ledger = UsageV4Ledger()..foreground(before);
    ledger.chatLog(before, {'inputTokens': 10129, 'outputTokens': 7, 'cacheReadTokens': 2, 'cacheWriteTokens': 0});
    ledger.chatLog(before, {'inputTokens': 25, 'outputTokens': 0});
    ledger.chatLog(before, {'inputTokens': 11});
    ledger.chatLog(before, {'outputTokens': -1});
    ledger.chatLog(before, null);
    ledger.chatLog(before, {'inputTokens': 50, 'outputTokens': 0}, partial: true);
    final day = ledger.days[ledger.due(after).single]!;
    expect(day.counts, [6, 3, 0, 1, 2, 0, 1, 1, 1, 2, 1, 2, 0]);
    expect(day.values, [10167, 7, 10156, 7, 10165, 2, 0, 1]);
  });

  test('a sealed day persists unchanged across retries, metadata changes and a clock rollback', () {
    final day = DateTime.utc(2026, 11, 19, 16);
    final next = day.add(const Duration(days: 1));
    final ledger = UsageV4Ledger()..foreground(day);
    final key = ledger.due(next).single;
    final sealed = ledger.days[key]!.seal(key, const UsageDevice(app: '1.0.21'));
    expect((jsonDecode(sealed) as Map)['base'], [1, 1]);
    final restored = UsageV4Ledger.decode(ledger.encode());
    restored.chatLog(day, {'outputTokens': 10});
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
