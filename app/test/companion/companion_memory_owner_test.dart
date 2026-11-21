// Real SQLite owner and real memory page. Only the native widget channel is
// replaced. No host or model is needed to edit, control or delete a memory.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_memory_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _oldStore = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _channel = MethodChannel('dsh/companion_widget');

class _Phone {
  _Phone() {
    store = CompanionMemoryStore(db, nowMilliseconds: () => now);
    owner = CompanionMemoryOwner(store, CompanionLocal.at(Directory('/unused-companion-ui-test')),
      nowMilliseconds: () => now);
    addTearDown(owner.dispose);
  }

  final db = sqlite3.openInMemory();
  int now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner owner;

  MemoryRow manual(String text) {
    store.saveManual(CompanionMemory(id: _id, text: text), expectedRowRev: null,
      currentValueChange: true, realityKnown: true);
    return store.cards().single;
  }

  MemoryRow automatic(String text, {String source = 'original', String kind = 'fact', List<String> keywords = const []}) {
    store.submitMessage(id: source, sessionId: store.lightSessionId, text: text,
      saidAtUtc: now, offsetMinutes: 480);
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    final proposal = parseExtractionProposal(jsonEncode({
      'schema_version': 2, 'batch_id': batch.id, 'covered_message_ids': [source],
      'completion': 'complete', 'operations': [
        {'op': 'create', 'kind': kind, 'text': text, 'keywords': keywords,
          'evidence': [{'message_id': source, 'quote': text}]},
      ],
    }), batch);
    expect(store.commitExtraction(batch, proposal), isTrue);
    return store.cards().singleWhere((row) => (row['evidence'] as List)
      .any((evidence) => (evidence as Map)['message_id'] == source));
  }

  Widget app() => ProviderScope(overrides: [
    activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
  ], child: MaterialApp(theme: buildDarkTheme(), localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales, locale: const Locale('zh'),
    home: CompanionMemoryPage(memory: owner)));
}

Future<void> _edit(WidgetTester tester, String text, {bool save = true}) async {
  await tester.enterText(find.byType(TextField), text);
  if (save) {
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
  }
}

Future<void> _menu(WidgetTester tester, String action) async {
  await tester.tap(find.byTooltip('这件事的选项').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

void main() {
  late List<Map<String, Object?>> native;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    native = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      native.add(Map<String, Object?>.from(call.arguments as Map));
      return true;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  testWidgets('the phone page opens without any host and saves directly to its shared owner', (tester) async {
    final phone = _Phone();
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    expect(find.textContaining('两种模式共用'), findsOneWidget);
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();
    await _edit(tester, '我的咖啡甜度是无糖');
    expect(phone.store.cards().single['text'], '我的咖啡甜度是无糖');
    expect(phone.owner.select('咖啡甜度').ids, hasLength(1));
    expect(phone.store.messages(), isEmpty, reason: 'A manual edit must not invent a user chat source');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a dialog keeps row revision and cannot overwrite a later same-phone change', (tester) async {
    final phone = _Phone();
    final initial = phone.manual('我的咖啡甜度是低糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的咖啡甜度是低糖'));
    await tester.pumpAndSettle();
    await _edit(tester, '我的咖啡甜度是无糖', save: false);
    phone.store.saveManual(const CompanionMemory(id: _id, text: '我的咖啡甜度是半糖'),
      expectedRowRev: initial['row_rev']! as int, currentValueChange: true, realityKnown: true);
    phone.owner.changed();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(phone.store.cards().single['text'], '我的咖啡甜度是半糖');
    expect(find.text('刚才另一处改过了，已经刷新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('current details and wording use different explicit edit actions, without inventing history', (tester) async {
    final phone = _Phone();
    final initial = phone.manual('我的咖啡甜度是低糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await _menu(tester, '只改文字');
    await _edit(tester, '我的咖啡甜度：低糖');
    expect(phone.store.cards().single['current_basis_seq'], initial['current_basis_seq']);
    await tester.tap(find.text('我的咖啡甜度：低糖'));
    await tester.pumpAndSettle();
    await _edit(tester, '我的咖啡甜度是半糖');
    expect(phone.store.cards().single['current_basis_seq'], greaterThan(initial['current_basis_seq']! as int));
    expect(phone.store.cards(), hasLength(1));
    expect(phone.store.messages(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a legal long automatic card can be pinned without turning into manual evidence', (tester) async {
    final phone = _Phone();
    final card = phone.automatic('咖啡${'好' * 600}');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    final beforeControl = phone.store.archive['control_revision'];
    await _menu(tester, '置顶');
    final pinned = phone.store.cards().single;
    expect(pinned['pinned'], isTrue);
    for (final key in ['manual', 'eligible', 'current_basis_seq', 'source_at_ms', 'updated_at_ms']) {
      expect(pinned[key], card[key], reason: key);
    }
    expect(phone.store.archive['control_revision'], beforeControl);
    expect(pinned['evidence'], card['evidence']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('legacy reality confirmation is reachable and pin does not grant it', (tester) async {
    final phone = _Phone();
    phone.store.importLegacy(CompanionMigrationSnapshot.fromJson({
      'v': 1, 'storeId': _oldStore, 'revision': 2, 'memoryRevision': 2,
      'memories': [{'id': _id, 'kind': 'fact', 'text': '我的咖啡甜度是无糖', 'keywords': [],
        'pinned': false, 'source': {'kind': 'manual'}, 'expiresAt': null,
        'createdAt': 1000, 'updatedAt': 2000}],
    }));
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    expect(phone.owner.select('咖啡甜度').ids, isEmpty);
    await _menu(tester, '置顶');
    expect(phone.store.cards().single['eligible'], isFalse);
    await _menu(tester, '这是我的现实情况');
    final row = phone.store.cards().single;
    expect(row['eligible'], isTrue);
    expect(row['current_basis_seq'], isNull);
    expect(row['source_at_ms'], 2000);
    expect(row['event_time'], isNull);
    expect(phone.owner.select('咖啡甜度').ids, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('never keeps the card and forget removes it; both clear line and saidAt with native acknowledgement', (tester) async {
    final phone = _Phone();
    phone.automatic('我的咖啡甜度是无糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    native.clear();
    await _menu(tester, '别主动提');
    expect(phone.store.cards().single['topic_mode'], 'never');
    expect(phone.owner.select('咖啡甜度').ids, isEmpty);
    expect(native.last['line'], isNull);
    expect(native.last.containsKey('line'), isTrue);
    expect(native.last['saidAt'], isNull);
    expect(native.last.containsKey('saidAt'), isTrue);
    expect(phone.store.archive['widget_clear_pending'], 0);
    await _menu(tester, '忘掉');
    await tester.tap(find.widgetWithText(FilledButton, '忘掉'));
    await tester.pumpAndSettle();
    expect(phone.store.cards(), isEmpty);
    expect(phone.store.messages().single['text'], '我的咖啡甜度是无糖');
    expect(native.last['line'], isNull);
    expect(native.last['saidAt'], isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native failure leaves clear pending after a successful local control', (tester) async {
    final phone = _Phone();
    phone.manual('我的咖啡甜度是无糖');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (_) async => null);
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await _menu(tester, '别主动提');
    expect(phone.store.cards().single['topic_mode'], 'never');
    expect(phone.store.archive['widget_clear_pending'], 1);
    expect(find.textContaining('小组件的旧一句还没清掉'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancel this plan preserves a separate plan sharing its expression topic', (tester) async {
    final phone = _Phone();
    const firstText = '我周四去甲公司面试';
    final first = phone.automatic(firstText, source: 'plan-a', kind: 'episode', keywords: ['面试']);
    phone.store.applyControl(topicIds: [first['topic_id']! as String], kind: 'less');
    final second = phone.automatic('我周五去乙公司面试', source: 'plan-b', kind: 'episode', keywords: ['面试']);
    expect(second['topic_id'], first['topic_id'], reason: 'Expression control shares a topic, not a plan');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    final tile = find.ancestor(of: find.text(firstText), matching: find.byType(SettingsTile));
    await tester.tap(find.descendant(of: tile, matching: find.byTooltip('这件事的选项')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消这项计划'));
    await tester.pumpAndSettle();
    final cards = {for (final card in phone.store.cards()) card['id']: card};
    expect(cards[first['id']]!['plan_state'], 'cancelled');
    expect(cards[second['id']]!['plan_state'], second['plan_state']);
    expect(cards[second['id']]!['row_rev'], second['row_rev']);
    expect(cards[second['id']]!['topic_mode'], 'less');
    expect(phone.store.messages().map((row) => row['id']), containsAll(['plan-a', 'plan-b']));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('usage view keeps four components separate and pending coverage is never shown as free', (tester) async {
    final phone = _Phone();
    final id = phone.store.reserveRequest(category: 'chat', provider: 'deepseek', model: 'deepseek-flash',
      inputTokens: 100, outputTokens: 800)!;
    phone.store.markRequestSent(id);
    phone.store.recordUsage(id, {
      'provider': 'deepseek', 'model': 'deepseek-flash',
      'start_usage': {'input_tokens': 90}, 'final_usage': {'input_tokens': 9, 'output_tokens': 3},
      'usage_semantics': 'cumulative', 'input_uncached': 9, 'input_cache_read': null,
      'input_cache_write': null, 'output_tokens': 3, 'terminal': 'incomplete', 'complete': false,
    });
    phone.store.finishRequest(id, terminal: 'incomplete');
    phone.store.rememberHostChatDelivery(hostKey: 'host', instanceId: 'old-instance', sessionId: 'old-session',
      requestId: 'unsettled', archiveId: phone.store.archive['id']! as String,
      controlRevision: 0, historyAfterSeq: 0, observedAt: phone.now);
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('模型用量'));
    await tester.pumpAndSettle();
    expect(find.text('等待本次的用量记录'), findsOneWidget);
    expect(find.textContaining('未缓存输入: 9'), findsOneWidget);
    expect(find.textContaining('缓存读取: 未知'), findsOneWidget);
    expect(find.textContaining('缓存写入: 未知'), findsOneWidget);
    expect(find.textContaining('输出: 3'), findsOneWidget);
    expect(find.textContaining('估算费用: 未知'), findsOneWidget);
    expect(find.text('还没有记录到用量'), findsNothing);
    expect(phone.store.requests().single['output_tokens'], 3);
    await tester.pumpWidget(const SizedBox());
  });
}
