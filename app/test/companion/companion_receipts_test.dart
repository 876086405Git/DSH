import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/companion_receipts_peer.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/companion_reminders');
  const clock = CompanionReminders();

  test('J exact spoken example keeps four inputs new filename deadline and permission to continue', () {
    expect(parseCompanionReceipts(receiptSpokenExample), {
      'kind': 'host.receipts_to_sheet',
      'operation': 'create',
      'allowQueue': true,
      'afterExit': 'continue',
      'deadlineTime': '20:00',
      'outputName': '差旅小表.xlsx',
    });
    expect(
      parseCompanionReceipts(
        receiptSpokenExample.replaceFirst('等电脑开了', '请电脑现在处理').replaceFirst('今晚八点前，', '').replaceFirst('我先去吃饭', '我离开就停'),
      ),
      {
        'kind': 'host.receipts_to_sheet',
        'operation': 'create',
        'allowQueue': false,
        'afterExit': 'pause',
        'deadlineTime': null,
        'outputName': '差旅小表.xlsx',
      },
    );
  });

  for (final text in [
    '“$receiptSpokenExample”',
    '故事里他说：$receiptSpokenExample',
    '不要$receiptSpokenExample',
    '假设$receiptSpokenExample',
  ]) {
    test('J quotation and hypothetical words do not accept a receipt task: $text', () {
      expect(parseCompanionReceipts(text), isNull);
    });
  }

  for (final text in [
    receiptSpokenExample.replaceFirst('这四张票', '这五张票'),
    receiptSpokenExample.replaceFirst('今晚八点', '八点'),
    receiptSpokenExample.replaceFirst('新建', '覆盖'),
    receiptSpokenExample.replaceFirst('差旅小表.xlsx', '../差旅小表.xlsx'),
    receiptSpokenExample.replaceFirst('我先去吃饭。', ''),
    receiptSpokenExample.replaceFirst('我先去吃饭', '我先去吃饭，我离开就停'),
  ]) {
    test('J unresolved count overwrite deadline or exit terms ask before any file binding: $text', () {
      expect(parseCompanionReceipts(text)!['operation'], 'clarify');
    });
  }

  test('J explicit cancellation has a finite whole-sentence boundary', () {
    expect(parseCompanionReceipts('取消整理票据。'), {'kind': 'host.receipts_to_sheet', 'operation': 'cancel'});
    expect(parseCompanionReceipts('“取消整理票据”'), isNull);
    expect(parseCompanionReceipts('不是要取消整理票据'), isNull);
  });

  test('J source time fixes tonight before a later retry and never becomes a five-minute deadline', () async {
    final at = DateTime.parse('2026-11-21T15:30:00Z').millisecondsSinceEpoch;
    var now = at;
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
      id: 'receipt-clock',
      sessionId: 'light:original-room',
      text: receiptSpokenExample,
      saidAtUtc: at,
      offsetMinutes: 480,
      zoneId: 'Asia/Shanghai',
      offsetSeconds: 28800,
    );
    now += const Duration(days: 1).inMilliseconds;
    final agreement = await companionCompareAgreement(source, parseCompanionReceipts(receiptSpokenExample)!, clock);
    expect(calls.single.method, 'resolve');
    expect(calls.single.arguments, {'localDate': '2026-11-21', 'localTime': '20:00', 'zoneId': 'Asia/Shanghai'});
    expect(agreement!['deadlineAtMs'], lessThan(at));
    expect(store.messages().single['said_at_utc'], at);
  });
}
