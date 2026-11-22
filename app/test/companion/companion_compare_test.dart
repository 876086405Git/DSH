import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_compare_peer.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/companion_reminders');
  const clock = CompanionReminders();

  test('I exact spoken example preserves A before B, queue, continue and tonight deadline', () {
    expect(parseCompanionCompare(compareSpokenExample), {
      'kind': 'host.compare_drafts',
      'operation': 'create',
      'allowQueue': true,
      'afterExit': 'continue',
      'deadlineTime': '20:00',
    });
    final noDeadline = compareSpokenExample
        .replaceFirst('电脑上线就帮我对一遍', '请电脑帮我对一遍')
        .replaceFirst('晚上八点前', '')
        .replaceFirst('我先去排练', '我离开就停');
    expect(parseCompanionCompare(noDeadline), {
      'kind': 'host.compare_drafts',
      'operation': 'create',
      'allowQueue': false,
      'afterExit': 'pause',
      'deadlineTime': null,
    });
  });

  for (final text in [
    '“$compareSpokenExample”',
    '故事里他说：$compareSpokenExample',
    '不要$compareSpokenExample',
    '假设$compareSpokenExample',
  ]) {
    test('I quoted or hypothetical comparison is not an actionable command: $text', () {
      expect(parseCompanionCompare(text), isNull);
    });
  }

  for (final text in [
    compareSpokenExample.replaceFirst('A 稿和 B 稿', 'B 稿和 A 稿'),
    compareSpokenExample.replaceFirst('我先去排练，', ''),
    compareSpokenExample.replaceFirst('晚上八点', '八点'),
    compareSpokenExample.replaceFirst('两个原文件都别动', '顺便覆盖 A 稿'),
    compareSpokenExample.replaceFirst('我先去排练', '我先去排练，我离开就停'),
  ]) {
    test('I unresolved ordering scope or time asks before input binding: $text', () {
      expect(parseCompanionCompare(text)!['operation'], 'clarify');
    });
  }

  test('I explicit cancellation stays finite and does not match a quoted cancellation', () {
    expect(parseCompanionCompare('取消对稿。'), {'kind': 'host.compare_drafts', 'operation': 'cancel'});
    expect(parseCompanionCompare('“取消对稿”'), isNull);
    expect(parseCompanionCompare('不是要取消对稿'), isNull);
  });

  test(
    'I deadline uses the original source day even after midnight and does not roll an elapsed evening forward',
    () async {
      final observed = DateTime.parse('2026-11-21T15:30:00Z').millisecondsSinceEpoch;
      var now = observed;
      final store = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => now);
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'kind': 'unique',
          'moments': [
            {'epochMs': DateTime.parse('2026-11-21T12:00:00Z').millisecondsSinceEpoch, 'offsetSeconds': 28800},
          ],
        };
      });
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        store.close();
      });
      final source = store.submitMessage(
        id: 'original-evening',
        sessionId: 'light:original-room',
        text: compareSpokenExample,
        saidAtUtc: observed,
        offsetMinutes: 480,
        offsetSeconds: 28800,
        zoneId: 'Asia/Shanghai',
      );
      now += const Duration(days: 1).inMilliseconds;
      final plan = await companionCompareAgreement(source, parseCompanionCompare(compareSpokenExample)!, clock);
      expect(calls.single.method, 'resolve');
      expect(calls.single.arguments, {'localDate': '2026-11-21', 'localTime': '20:00', 'zoneId': 'Asia/Shanghai'});
      expect(plan!['deadlineAtMs'], lessThan(observed));
      expect(plan.containsKey('args'), isFalse);
      expect(store.messages().single['said_at_utc'], observed);
    },
  );

  test('I absent deadline needs no invented time zone while a nonunique spoken deadline stays unresolved', () async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'kind': 'overlap', 'moments': <Object?>[]};
    });
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final command = parseCompanionCompare(compareSpokenExample)!;
    final withoutDeadline = await companionCompareAgreement(
      {'said_at_utc': 1795219200000},
      {...command, 'deadlineTime': null},
      clock,
    );
    expect(withoutDeadline!['deadlineAtMs'], isNull);
    expect(calls, isEmpty);
    final ambiguous = await companionCompareAgreement(
      {'said_at_utc': 1795219200000, 'zone_id': 'Asia/Shanghai', 'offset_seconds': 28800},
      command,
      clock,
    );
    expect(ambiguous, isNull);
    expect(calls, hasLength(1));
  });
}
