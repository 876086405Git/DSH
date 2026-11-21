// Real SQLite owner and real memory page. Only the native widget channel is
// replaced. No host or model is needed to edit, control or delete a memory.
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_memory_page.dart';
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
    owner = CompanionMemoryOwner(
      store,
      CompanionLocal.at(Directory('/unused-companion-ui-test')),
      nowMilliseconds: () => now,
    );
    addTearDown(owner.dispose);
  }

  final db = sqlite3.openInMemory();
  int now = DateTime.utc(2026, 11, 21, 1).millisecondsSinceEpoch;
  late final CompanionMemoryStore store;
  late final CompanionMemoryOwner owner;

  MemoryRow manual(String text) {
    store.saveManual(
      CompanionMemory(id: _id, text: text),
      expectedRowRev: null,
      currentValueChange: true,
      realityKnown: true,
    );
    return store.cards().single;
  }

  MemoryRow automatic(
    String text, {
    String source = 'original',
    String kind = 'fact',
    List<String> keywords = const [],
  }) {
    store.submitMessage(id: source, sessionId: store.lightSessionId, text: text, saidAtUtc: now, offsetMinutes: 480);
    final batch = store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'covered_message_ids': [source],
        'completion': 'complete',
        'operations': [
          {
            'op': 'create',
            'kind': kind,
            'text': text,
            'keywords': keywords,
            'evidence': [
              {'message_id': source, 'quote': text},
            ],
          },
        ],
      }),
      batch,
    );
    expect(store.commitExtraction(batch, proposal), isTrue);
    return store.cards().singleWhere(
      (row) => (row['evidence'] as List).any((evidence) => (evidence as Map)['message_id'] == source),
    );
  }

  Widget app() => ProviderScope(
    overrides: [activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))],
    child: MaterialApp(
      theme: buildDarkTheme(),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('zh'),
      home: CompanionMemoryPage(memory: owner),
    ),
  );
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
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
  );

  testWidgets('local consolidation notifies the real memories page when the host has no model route', (tester) async {
    final phone = _Phone();
    const text = '我只买原味酸奶';
    phone.store.submitMessage(
      id: 'duplicate-source',
      sessionId: phone.store.lightSessionId,
      text: text,
      saidAtUtc: phone.now,
      offsetMinutes: 480,
    );
    final batch = phone.store.nextBatch(forceTail: true, estimateTokens: (text) => text.runes.length)!;
    final proposal = parseExtractionProposal(
      jsonEncode({
        'schema_version': 2,
        'batch_id': batch.id,
        'covered_message_ids': ['duplicate-source'],
        'completion': 'complete',
        'operations': [
          for (var i = 0; i < 2; i++)
            {
              'op': 'create',
              'kind': 'preference',
              'text': text,
              'keywords': ['酸奶'],
              'evidence': [
                {'message_id': 'duplicate-source', 'quote': text},
              ],
            },
        ],
      }),
      batch,
    );
    expect(phone.store.commitExtraction(batch, proposal), isTrue);
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    expect(find.text(text), findsNWidgets(2));
    final room = Object();
    phone.owner.enter(room, transport: () => null, estimateTokens: (text) => text.runes.length);
    await phone.owner.consolidate(room);
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);
    expect(phone.store.cards(), hasLength(1));
    expect(phone.store.requests(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

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
    phone.store.saveManual(
      const CompanionMemory(id: _id, text: '我的咖啡甜度是半糖'),
      expectedRowRev: initial['row_rev']! as int,
      currentValueChange: true,
      realityKnown: true,
    );
    phone.owner.changed();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(phone.store.cards().single['text'], '我的咖啡甜度是半糖');
    expect(find.text('刚才另一处改过了，已经刷新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing what she remembers is a new current value, without inventing history', (tester) async {
    final phone = _Phone();
    final initial = phone.manual('我的咖啡甜度是低糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的咖啡甜度是低糖'));
    await tester.pumpAndSettle();
    await _edit(tester, '我的咖啡甜度是半糖');
    expect(phone.store.cards().single['current_basis_seq'], greaterThan(initial['current_basis_seq']! as int));
    expect(phone.store.cards(), hasLength(1));
    expect(phone.store.messages(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the page offers only edit and forget, no mechanism controls', (tester) async {
    final phone = _Phone();
    phone.automatic('我的咖啡甜度是无糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('这件事的选项').first);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    expect(find.byTooltip('模型用量'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hand-written memories carried over from before count as real', (tester) async {
    final phone = _Phone();
    phone.store.importLegacy(
      CompanionMigrationSnapshot.fromJson({
        'v': 1,
        'storeId': _oldStore,
        'revision': 2,
        'memoryRevision': 2,
        'memories': [
          {
            'id': _id,
            'kind': 'fact',
            'text': '我的咖啡甜度是无糖',
            'keywords': [],
            'pinned': false,
            'source': {'kind': 'manual'},
            'expiresAt': null,
            'createdAt': 1000,
            'updatedAt': 2000,
          },
        ],
      }),
      realityKnownIds: {_id},
    );
    expect(phone.store.cards().single['eligible'], isTrue);
    expect(phone.owner.select('咖啡甜度').ids, hasLength(1));
  });

  testWidgets('forget removes the card and clears line and saidAt with native acknowledgement', (tester) async {
    final phone = _Phone();
    phone.automatic('我的咖啡甜度是无糖');
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    native.clear();
    await _menu(tester, '忘掉');
    await tester.tap(find.widgetWithText(FilledButton, '忘掉'));
    await tester.pumpAndSettle();
    expect(phone.store.cards(), isEmpty);
    expect(phone.store.messages().single['text'], '我的咖啡甜度是无糖');
    expect(native.last['line'], isNull);
    expect(native.last.containsKey('line'), isTrue);
    expect(native.last['saidAt'], isNull);
    expect(native.last.containsKey('saidAt'), isTrue);
    expect(phone.store.archive['widget_clear_pending'], 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native failure leaves clear pending after a successful forget', (tester) async {
    final phone = _Phone();
    phone.manual('我的咖啡甜度是无糖');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (_) async => null,
    );
    await tester.pumpWidget(phone.app());
    await tester.pumpAndSettle();
    await _menu(tester, '忘掉');
    await tester.tap(find.widgetWithText(FilledButton, '忘掉'));
    await tester.pumpAndSettle();
    expect(phone.store.cards(), isEmpty);
    expect(phone.store.archive['widget_clear_pending'], 1);
    expect(find.text('小组件上那句旧话稍后会清掉。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
