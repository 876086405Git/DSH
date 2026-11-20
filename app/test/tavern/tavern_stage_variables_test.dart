import 'package:dsh_app/tavern/tavern_preview.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/ui/tavern/tavern_chat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';

/// The preview, its state at the current message being [values]: a card's
/// own state unless [legacy] (then what its macros saved). Edits are kept
/// at a top-level key, or refused by [refuse].
class _Saved extends PreviewTavern {
  _Saved(
    this.values, {
    this.legacy = true,
    this.changes = const [],
    this.hidden = const [],
    this.preview = false,
    this.refuse,
  }) : super(tick: Duration.zero);

  Map<String, Object?> values;
  final bool legacy;
  final List<Map<String, Object?>> changes;
  final List<String> hidden;
  final bool preview;
  final String? refuse;
  final edits = <(String, Object?, String?)>[];

  Future<TavernStateSnapshot> _snapshot(String chatId) async => TavernStateSnapshot(
    chatId: chatId,
    nodeId: (await path(chatId)).last.nodeId,
    legacy: legacy,
    initialized: !preview,
    valueExists: !preview,
    automaticEnabled: !legacy,
    values: preview ? null : values,
    initialValuesAvailable: preview,
    initialValues: preview ? values : null,
    hiddenPaths: hidden,
    changes: changes,
  );

  @override
  Future<TavernStateSnapshot> readState(String chatId) => _snapshot(chatId);

  @override
  Future<TavernStateEditResult> setStateValue(
    String chatId,
    String path,
    Object? value, {
    String? expectedNodeId,
  }) async {
    edits.add((path, value, expectedNodeId));
    final key = path.substring(1);
    final same = values[key] == value;
    if (refuse == null) values = {...values, key: value};
    return TavernStateEditResult(
      applied: refuse == null,
      changed: refuse == null && !same,
      snapshot: await _snapshot(chatId),
      issues: [
        if (refuse case final reason?) {'code': 'permission', 'message': reason},
      ],
    );
  }
}

/// [_Saved], its edits written at their whole path.
class _Nested extends _Saved {
  _Nested(super.values) : super(legacy: true);

  @override
  Future<TavernStateEditResult> setStateValue(
    String chatId,
    String path,
    Object? value, {
    String? expectedNodeId,
  }) async {
    edits.add((path, value, expectedNodeId));
    final steps = path.substring(1).split('/');
    Object? at = values;
    for (final step in steps.take(steps.length - 1)) {
      at = at is Map ? at[step] : (at as List)[int.parse(step)];
    }
    if (at is Map) {
      at[steps.last] = value;
    } else {
      (at as List)[int.parse(steps.last)] = value;
    }
    return TavernStateEditResult(applied: true, changed: true, snapshot: await readState(chatId));
  }
}

Future<void> _open(WidgetTester tester, PreviewTavern tavern, {Size size = const Size(390, 844)}) async {
  SharedPreferences.setMockInitialValues({});
  final chat = (await tester.runAsync(() => tavern.createChat('sample-innkeeper')))!;
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tavernProvider.overrideWith((ref) => tavern)],
      child: MaterialApp(
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: TavernChatPage(chatId: chat),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _stateTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('tavern-stage-tabs')), matching: find.text('状态')));
  await tester.pumpAndSettle();
}

Future<void> _openState(WidgetTester tester, PreviewTavern tavern) async {
  await _open(tester, tavern);
  await tester.tap(find.byKey(const ValueKey('bot-action')));
  await tester.pumpAndSettle();
  await _stateTab(tester);
}

Finder _row(String key) => find.byKey(ValueKey('tavern-variable-$key'));

/// Opens [key], 改, writes [text] in the editor and saves it.
Future<void> _change(WidgetTester tester, String key, String text) async {
  await tester.tap(_row(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('tavern-state-edit')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('tavern-message-field')), text);
  await tester.pump();
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('状态 lists what the macros saved, sorted; one opens whole', (tester) async {
    await _openState(
      tester,
      _Saved({
        'location': '旅店',
        'affection': 5,
        'stat_data': {
          'hp': 10,
          'items': ['钥匙'],
        },
      }),
    );

    expect(find.byKey(const ValueKey('tavern-stage-variables')), findsOneWidget);
    expect(find.text('变量'), findsOneWidget);
    expect(find.descendant(of: _row('affection'), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: _row('location'), matching: find.text('旅店')), findsOneWidget);
    expect(find.descendant(of: _row('stat_data'), matching: find.text('2 项')), findsOneWidget);
    expect(tester.getTopLeft(_row('affection')).dy, lessThan(tester.getTopLeft(_row('location')).dy)); // sorted by name

    // An object opens in place; its values are rows of their own.
    await tester.tap(_row('stat_data'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _row('/stat_data/hp'), matching: find.text('10')), findsOneWidget);
    expect(find.descendant(of: _row('/stat_data/items'), matching: find.text('钥匙')), findsOneWidget);
    await tester.tap(_row('stat_data'));
    await tester.pumpAndSettle();
    expect(_row('/stat_data/hp'), findsNothing);

    // Held, it shows whole.
    await tester.longPress(_row('stat_data'));
    await tester.pumpAndSettle();
    final whole = tester.widget<SelectableText>(find.byKey(const ValueKey('tavern-variable-whole')));
    expect(whole.data, contains('"hp": 10'));
    expect(whole.data, contains('"钥匙"'));
  });

  testWidgets('a value deep inside is changed at its own path', (tester) async {
    final tavern = _Nested({
      'stat_data': {
        'hp': 10,
        'bag': [
          {'name': '钥匙'},
        ],
      },
    });
    await _openState(tester, tavern);
    await tester.tap(_row('stat_data'));
    await tester.pumpAndSettle();
    await tester.tap(_row('/stat_data/bag'));
    await tester.pumpAndSettle();
    await tester.tap(_row('/stat_data/bag/0'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _row('/stat_data/bag/0/name'), matching: find.text('钥匙')), findsOneWidget);

    await _change(tester, '/stat_data/hp', '7');
    expect(tavern.edits.single.$1, '/stat_data/hp');
    expect(tavern.edits.single.$2, 7);
    expect(find.descendant(of: _row('/stat_data/hp'), matching: find.text('7')), findsOneWidget);
  });

  testWidgets('with many values, 搜 finds them by name or value, each by its whole path', (tester) async {
    await _openState(
      tester,
      _Saved({
        for (var i = 0; i < 6; i++) 'v$i': i,
        'stat_data': {'hp': 10, 'mood': '平静'},
      }),
    );
    expect(find.byKey(const ValueKey('tavern-state-search')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('tavern-state-search')), '平静');
    await tester.pumpAndSettle();
    expect(find.descendant(of: _row('/stat_data/mood'), matching: find.text('stat_data › mood')), findsOneWidget);
    expect(_row('v0'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('tavern-state-search')), '没有这个');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tavern-state-no-match')), findsOneWidget);
  });

  testWidgets('with nothing saved, 状态 says what will be there', (tester) async {
    await _openState(tester, _Saved({}));
    expect(find.byKey(const ValueKey('tavern-stage-variables')), findsNothing);
    expect(find.byKey(const ValueKey('tavern-stage-state')), findsOneWidget);
  });

  testWidgets("a card's own state: in its order, this turn's change marked, a kept value folded", (tester) async {
    await _openState(
      tester,
      _Saved(
        {'好感': 8, '地点': '旅店', '秘密': '她是逃犯'},
        legacy: false,
        changes: [
          {'path': '/好感', 'oldExists': true, 'old': 5, 'newExists': true, 'new': 8, 'actor': 'model'},
          {'path': '/地点', 'oldExists': true, 'old': '街上', 'newExists': true, 'new': '旅店', 'actor': 'model'},
        ],
        hidden: ['/秘密'],
      ),
    );
    expect(find.text('变量'), findsNothing);
    expect(tester.getTopLeft(_row('好感')).dy, lessThan(tester.getTopLeft(_row('地点')).dy)); // the card's order
    expect(tester.widget<Text>(find.byKey(const ValueKey('tavern-state-change-好感'))).data, '+3');
    expect(tester.widget<Text>(find.byKey(const ValueKey('tavern-state-change-地点'))).data, '变了');
    expect(find.byKey(const ValueKey('tavern-state-change-秘密')), findsNothing);
    expect(find.descendant(of: _row('秘密'), matching: find.text('她是逃犯')), findsNothing);
    expect(find.descendant(of: _row('秘密'), matching: find.text('剧透 · 点开看')), findsOneWidget);
    await tester.tap(_row('秘密'));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('tavern-variable-whole'))).data, '她是逃犯');
  });

  testWidgets("before anything is saved, the card's starting values say so", (tester) async {
    await _openState(tester, _Saved({'好感': 0}, legacy: false, preview: true));
    expect(find.descendant(of: _row('好感'), matching: find.text('0')), findsOneWidget);
    expect(find.textContaining('下面是初始值'), findsOneWidget);
  });

  testWidgets('a value changed by hand goes to the engine at that message, and shows', (tester) async {
    final tavern = _Saved({'affection': 5, 'location': '旅店'}, legacy: false);
    await _openState(tester, tavern);
    final at = (await tester.runAsync(
      () async => (await tavern.path((await tavern.watchChats().first).single.id)).last,
    ))!;

    await _change(tester, 'affection', '9');
    expect(tavern.edits.single, ('/affection', 9, at.nodeId));
    expect(find.descendant(of: _row('affection'), matching: find.text('9')), findsOneWidget);
    expect(find.text('改好了'), findsOneWidget);

    // Text stays text; JSON that does not read is not sent.
    await _change(tester, 'location', '地下室');
    expect(tavern.edits.last, ('/location', '地下室', at.nodeId));
    await _change(tester, 'affection', '九');
    expect(tavern.edits, hasLength(2));
    expect(find.text('这不是有效的 JSON，没有改'), findsOneWidget);
  });

  testWidgets('a change the card refuses says why, and the value stays', (tester) async {
    await _openState(tester, _Saved({'affection': 5}, legacy: false, refuse: '好感只能由剧情改变'));
    await _change(tester, 'affection', '99');
    expect(find.text('没改成：好感只能由剧情改变'), findsOneWidget);
    expect(find.descendant(of: _row('affection'), matching: find.text('5')), findsOneWidget);
  });

  testWidgets('beside the story, a new message reads them again', (tester) async {
    final tavern = _Saved({'affection': 5});
    await _open(tester, tavern, size: const Size(1200, 900));
    await _stateTab(tester);
    expect(find.descendant(of: _row('affection'), matching: find.text('5')), findsOneWidget);

    tavern.values = {'affection': 6};
    await tester.enterText(find.byType(TextField), '外面怎么了？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    await tester.pumpAndSettle();
    expect(find.descendant(of: _row('affection'), matching: find.text('6')), findsOneWidget);
  });
}
