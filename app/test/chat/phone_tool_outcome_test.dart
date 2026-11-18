// HarmonyOS's phone tools in the chat: a row says what is known. An opened page
// isn't the job done, an unknown isn't a failure, and a press isn't the app's
// success. Android's phone tools answer in prose and stay as they are.

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);

String _json(String status, String effect, String evidence, bool dispatched, String code, [String message = '原生说明']) =>
    jsonEncode({
      'status': status,
      'effect': effect,
      'evidence': evidence,
      'dispatched': dispatched,
      'code': code,
      'message': message,
    });

ToolChatItem _item(ToolStatus status, String result, {String name = 'mcp__phone__open'}) => ToolChatItem(
  callId: 'call-1',
  name: name,
  arguments: '{"url":"https://example.test"}',
  status: status,
  resultParts: [TextPart(result)],
);

Future<void> _row(WidgetTester tester, ToolChatItem item) async {
  await tester.pumpWidget(
    goldenApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ToolRow(item: item, onRespond: (_, _) async {}),
        ),
      ),
      brightness: Brightness.light,
    ),
  );
  await tester.pump();
  await tester.tap(find.byType(ToolRow));
  await tester.pumpAndSettle();
}

void main() {
  for (final (what, status, result, word, sentence, fault) in <(String, ToolStatus, String, String, String, bool)>[
    (
      'a page opened',
      ToolStatus.succeeded,
      _json('succeeded', 'opened_ui', 'opened_ui', true, 'opened_ui'),
      _zh.systemActionsOpenedUi,
      _zh.systemActionsResultOpened,
      false,
    ),
    (
      'a reminder handed to the system',
      ToolStatus.succeeded,
      _json('succeeded', 'reminder_scheduled', 'unknown', true, 'reminder_scheduled'),
      _zh.harmonyReminderSet,
      _zh.systemActionsResultReminder,
      false,
    ),
    (
      'a continue press',
      ToolStatus.succeeded,
      _json('succeeded', 'none', 'user_confirmed', true, 'user_confirmed'),
      _zh.phoneDecisionContinued,
      _zh.systemActionsResultContinued,
      false,
    ),
    (
      'an unknown after dispatch',
      ToolStatus.failed,
      'Error: ${_json('unknown', 'none', 'unknown', true, 'sdk_failed')}',
      _zh.systemActionsResultUnknown,
      _zh.systemActionsResultUnknownDetail,
      false,
    ),
    (
      'unsupported',
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', false, 'unsupported')}',
      _zh.systemActionsNotSupported,
      _zh.systemActionsResultUnsupported,
      false,
    ),
    (
      'the system refusing a reminder: its reason, and nothing set',
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', true, 'reminder_refused', '系统没有接受提醒：有效提醒已达上限，或这个版本还没开通系统代理提醒。')}',
      _zh.systemActionsNotRun,
      '系统没有接受提醒：有效提醒已达上限，或这个版本还没开通系统代理提醒。',
      true,
    ),
    (
      'a build without the permission',
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', false, 'permission_denied', '系统提醒权限尚未授予；请检查应用签名和提醒权限。')}',
      _zh.systemActionsNotRun,
      '系统提醒权限尚未授予；请检查应用签名和提醒权限。',
      true,
    ),
    (
      'off screen',
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', false, 'not_foreground')}',
      _zh.systemActionsNotRun,
      _zh.systemActionsResultOffScreen,
      true,
    ),
    (
      'the switch off',
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', false, 'native_unavailable')}',
      _zh.systemActionsNotRun,
      _zh.systemActionsResultUnavailable,
      true,
    ),
  ]) {
    testWidgets('$what reads as "$word"', (tester) async {
      final item = _item(status, result);
      await _row(tester, item);
      expect(find.text(word), findsOneWidget);
      expect(find.text(sentence), findsOneWidget);
      expect(find.textContaining('"status"'), findsNothing, reason: 'no raw JSON');
      expect(ToolView.of(item).phoneResult!.isFault, fault);
    });
  }

  test('a refused reminder in English says so, where the native reason only has Chinese', () {
    final view = _item(
      ToolStatus.failed,
      'Error: ${_json('failed', 'none', 'unknown', true, 'reminder_refused', '系统没有接受提醒。')}',
    );
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final en = lookupL10n(AppLocale.en);
    expect(ToolView.of(view).phoneResult!.sentence, en.harmonyReminderRefused);
    expect(ToolView.of(view).phoneResult!.word, en.systemActionsNotRun);
  });

  test('an unknown or unsupported call isn\'t counted as a failure of the turn', () {
    expect(
      summarizeTools([
        _item(ToolStatus.failed, 'Error: ${_json('unknown', 'none', 'unknown', true, 'sdk_failed')}'),
        _item(ToolStatus.failed, 'Error: ${_json('failed', 'none', 'unknown', false, 'unsupported')}'),
      ]).failed,
      0,
    );
  });

  group('everything else is untouched', () {
    for (final (what, item) in <(String, ToolChatItem)>[
      ('Android\'s prose', _item(ToolStatus.succeeded, '已打开 微信')),
      ('Android\'s JSON of another shape', _item(ToolStatus.succeeded, '{"ok":true,"screen":"x"}')),
      (
        'another tool with the same text',
        _item(ToolStatus.succeeded, _json('unknown', 'none', 'unknown', true, 'x'), name: 'mcp__other__open'),
      ),
      ('an Android failure', _item(ToolStatus.failed, 'Error: refused')),
    ]) {
      test(what, () => expect(ToolView.of(item).phoneResult, isNull));
    }

    test('a call still running has no outcome yet', () {
      expect(
        ToolView.of(_item(ToolStatus.running, _json('unknown', 'none', 'unknown', true, 'x'))).phoneResult,
        isNull,
      );
    });
  });
}
