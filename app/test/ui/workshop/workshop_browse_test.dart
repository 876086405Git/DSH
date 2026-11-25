// 创意工坊 › 发现 and the item's detail sheet (ui/workshop/workshop_browse.dart,
// workshop_item_sheet.dart): what each catalogue state looks like, that a
// failed refresh keeps the rows, that installing goes through the controller
// (and a refusal is said), the replacement question, and that nothing on
// screen is an error code.

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_catalog_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_install_state.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_page.dart';
import 'package:dsh_app/ui/workshop/workshop_screen.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../state/workshop_auth_test_support.dart';
import '../../support/test_fonts.dart';
import '../../workshop/support.dart';

class FixedCatalog extends WorkshopCatalogController {
  FixedCatalog(this.initial);

  final WorkshopCatalogState initial;
  int refreshes = 0;

  @override
  WorkshopCatalogState build() => initial;

  @override
  Future<void> refresh() async => refreshes++;
}

class FixedInstall extends WorkshopInstallController {
  FixedInstall(this.initial, {this.accepts = true});

  final WorkshopInstallState initial;
  final bool accepts;
  final installs = <WorkshopEntry>[];
  final confirmed = <WorkshopReplacementRequest>[];
  final declined = <WorkshopReplacementRequest>[];
  int cancels = 0;

  @override
  WorkshopInstallState build() => initial;

  void show(WorkshopInstallState next) => state = next;

  @override
  Future<bool> install(WorkshopEntry entry) async {
    installs.add(entry);
    return accepts;
  }

  @override
  Future<bool> confirmReplacement(WorkshopReplacementRequest request) async {
    confirmed.add(request);
    return accepts;
  }

  @override
  bool declineReplacement(WorkshopReplacementRequest request) {
    declined.add(request);
    return true;
  }

  @override
  void cancel() => cancels++;
}

/// The controller hands these out; a page test only needs one to pass back.
class FakeRequest implements WorkshopReplacementRequest {
  FakeRequest(this.entry);

  @override
  final WorkshopEntry entry;
}

WorkshopEntry entry({String kind = 'pet', String id = 'cat', String version = '1.0.0', String zh = '小猫', String en = 'Cat'}) =>
    WorkshopEntry.fromJson(
      workshopEntryJson(
        metadata: {
          ...workshopMeta(kind: kind, id: id, version: version),
          'title': {'zh': zh, 'en': en},
          'author': '阿青',
          'description': '一只会打哈欠的猫。',
          'tags': ['猫', '像素'],
        },
      ),
    );

WorkshopInstalled installed(WorkshopEntry e, {String? version}) => WorkshopInstalled(
  localId: e.metadata.id,
  receipt: WorkshopReceipt(
    kind: e.metadata.kind,
    id: e.metadata.id,
    version: version ?? e.metadata.version,
    sha256: e.metadata.sha256,
    origin: workshopTestOrigin,
  ),
);

WorkshopCatalogState catalog(
  List<WorkshopItemState> items, {
  String? refreshError,
  bool localStateKnown = true,
  bool snapshot = true,
  bool loading = false,
}) => WorkshopCatalogState(
  origin: workshopTestOrigin,
  snapshot: snapshot
      ? WorkshopCatalogSnapshot(
          catalog: WorkshopCatalog.fromJson(workshopCatalogJson(entries: [for (final i in items) i.entry.toJson()])),
          fetchedAt: DateTime.utc(2026, 11, 11),
          stale: refreshError != null,
        )
      : null,
  items: items,
  loading: loading,
  localStateKnown: localStateKnown,
  refreshError: refreshError,
);

Future<(FixedCatalog, FixedInstall)> pump(
  WidgetTester tester,
  WorkshopCatalogState state, {
  WorkshopInstallState install = const WorkshopInstallState(),
  bool accepts = true,
  double width = 390,
  double scale = 1,
  bool settle = true,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  addTearDown(tester.view.reset);
  final catalogController = FixedCatalog(state);
  final installController = FixedInstall(install, accepts: accepts);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workshopCatalogProvider.overrideWith(() => catalogController),
        workshopInstallProvider.overrideWith(() => installController),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withTestFonts(buildLightTheme()),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(scale)),
          child: MirroredSideInsets(child: child!),
        ),
        home: const WorkshopScreen(),
      ),
    ),
  );
  // A running install spins a ring for ever: step past the first frames instead.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return (catalogController, installController);
}

void expectNoCodes(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    expect(text.data ?? text.textSpan?.toPlainText() ?? '', isNot(contains('workshop_')));
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('rows show title, author and the capsule for each install state', (tester) async {
    final cat = entry();
    final fox = entry(id: 'fox', zh: '小狐狸', en: 'Fox', version: '2.0.0');
    final whale = entry(kind: 'companion', id: 'whale', zh: '鲸娘', en: 'Whale girl');
    await pump(
      tester,
      catalog([
        WorkshopItemState(entry: cat),
        WorkshopItemState(entry: fox, installed: installed(fox, version: '1.0.0'), updateAvailable: true),
        WorkshopItemState(entry: whale, installed: installed(whale)),
      ]),
    );
    expect(find.text('小猫'), findsOneWidget);
    expect(find.textContaining('阿青'), findsNWidgets(3));
    expect(find.widgetWithText(FilledButton, '获取'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '已安装'), findsOneWidget);
    expectNoCodes(tester);
  });

  testWidgets('kind chips and search narrow the list; nothing left says so', (tester) async {
    final (controller, _) = await pump(
      tester,
      catalog([
        WorkshopItemState(entry: entry()),
        WorkshopItemState(entry: entry(kind: 'companion', id: 'whale', zh: '鲸娘', en: 'Whale girl')),
      ]),
    );
    await tester.tap(find.widgetWithText(ChoiceChip, '伙伴'));
    await tester.pumpAndSettle();
    expect(find.text('小猫'), findsNothing);
    expect(find.text('鲸娘'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '不存在的名字');
    await tester.pumpAndSettle();
    expect(find.text('没有找到'), findsOneWidget);
    expect(controller.state.query, '不存在的名字');
  });

  testWidgets('a failed refresh keeps the rows and offers one retry', (tester) async {
    final (controller, _) = await pump(
      tester,
      catalog([WorkshopItemState(entry: entry())], refreshError: 'workshop_network', localStateKnown: false),
    );
    expect(find.text('小猫'), findsOneWidget);
    expect(find.textContaining('没能刷新'), findsOneWidget);
    expect(find.textContaining('读不出本机已装了哪些'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '重试'));
    await tester.pump();
    expect(controller.refreshes, 1);
    expectNoCodes(tester);
  });

  testWidgets('no catalogue and no service configured: says the workshop is not open, no retry', (tester) async {
    await pump(tester, catalog(const [], snapshot: false, refreshError: 'workshop_unconfigured'));
    expect(find.text('工坊还没有开放'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expectNoCodes(tester);
  });

  testWidgets('no catalogue after a failure: says why in words and offers retry', (tester) async {
    final (controller, _) = await pump(tester, catalog(const [], snapshot: false, refreshError: 'workshop_timeout'));
    expect(find.text('暂时打不开工坊'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(controller.refreshes, 1);
    expectNoCodes(tester);
  });

  testWidgets('the empty theme filter links directly to submission', (tester) async {
    final client = AuthClient();
    await pump(
      tester,
      catalog([WorkshopItemState(entry: entry())]).copyWith(kind: WorkshopKindFilter.theme),
      overrides: [
        workshopAccountProvider.overrideWith(() => AuthAccountController(authSignedOut)),
        workshopClientProvider.overrideWith((ref) async => client),
        workshopPreferencesProvider.overrideWithValue(AuthPreferences()),
      ],
    );
    expect(find.text('没有找到'), findsOneWidget);
    await tester.tap(find.text('投稿'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkshopPublishPage), findsOneWidget);
    expect(find.text('先登录 GitHub 账号'), findsOneWidget);
  });

  testWidgets('the sheet installs through the controller and says when it is refused', (tester) async {
    final cat = entry();
    final (_, install) = await pump(tester, catalog([WorkshopItemState(entry: cat)]), accepts: false);
    await tester.tap(find.text('小猫'));
    await tester.pumpAndSettle();
    expect(find.text('阿青 制作'), findsOneWidget);
    expect(find.text('一只会打哈欠的猫。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '获取').last);
    await tester.pumpAndSettle();
    expect(install.installs.single.metadata.identity, 'pet/cat');
    expect(find.textContaining('上一个安装或卸载还没结束'), findsOneWidget);
  });

  testWidgets('while installing the sheet shows real bytes and cancels through the controller', (tester) async {
    final cat = entry();
    final (_, install) = await pump(
      tester,
      catalog([WorkshopItemState(entry: cat)]),
      install: WorkshopInstallState(phase: WorkshopInstallPhase.downloading, entry: cat, received: 512 * 1024, total: 2 * 1024 * 1024),
      settle: false,
    );
    expect(find.widgetWithText(FilledButton, '安装中'), findsOneWidget);
    await tester.tap(find.text('小猫'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('正在下载'), findsOneWidget);
    expect(find.text('512 KB / 2.0 MB'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump();
    expect(install.cancels, 1);
  });

  testWidgets('a conflict asks once and answers with the same request', (tester) async {
    final cat = entry();
    final (_, install) = await pump(tester, catalog([WorkshopItemState(entry: cat)]));
    await tester.tap(find.text('小猫'));
    await tester.pumpAndSettle();

    final request = FakeRequest(cat);
    install.show(WorkshopInstallState(phase: WorkshopInstallPhase.awaitingReplacement, entry: cat, replacement: request));
    await tester.pumpAndSettle();
    expect(find.text('覆盖本机已有的？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '覆盖'));
    await tester.pumpAndSettle();
    expect(identical(install.confirmed.single, request), isTrue);
    expect(install.declined, isEmpty);

    final second = FakeRequest(cat);
    install.show(WorkshopInstallState(phase: WorkshopInstallPhase.awaitingReplacement, entry: cat, replacement: second));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(identical(install.declined.single, second), isTrue);
  });

  testWidgets('a replacement question already waiting is asked when the sheet opens', (tester) async {
    final cat = entry();
    final request = FakeRequest(cat);
    final (_, install) = await pump(
      tester,
      catalog([WorkshopItemState(entry: cat)]),
      install: WorkshopInstallState(phase: WorkshopInstallPhase.awaitingReplacement, entry: cat, replacement: request),
    );
    await tester.tap(find.text('小猫'));
    await tester.pumpAndSettle();

    expect(find.text('覆盖本机已有的？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '覆盖'));
    await tester.pumpAndSettle();
    expect(identical(install.confirmed.single, request), isTrue);
    expect(install.installs, isEmpty);
  });

  testWidgets('a failure is said in words under the button, never as a code', (tester) async {
    final cat = entry();
    final (_, install) = await pump(tester, catalog([WorkshopItemState(entry: cat)]));
    await tester.tap(find.text('小猫'));
    await tester.pumpAndSettle();
    install.show(WorkshopInstallState(phase: WorkshopInstallPhase.failed, entry: cat, error: 'workshop_no_space'));
    await tester.pumpAndSettle();
    expect(find.textContaining('手机空间不够'), findsOneWidget);
    install.show(WorkshopInstallState(phase: WorkshopInstallPhase.failed, entry: cat, error: 'workshop_some_future_code'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有成功'), findsOneWidget);
    expectNoCodes(tester);
  });

  testWidgets('withdrawn and too-old items explain themselves and cannot be installed', (tester) async {
    final cat = entry();
    await pump(tester, catalog([WorkshopItemState(entry: cat, unavailable: 'workshop_min_app')]));
    await tester.tap(find.text('小猫'));
    await tester.pumpAndSettle();
    expect(find.textContaining('需要 DSH Go'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '获取').last).onPressed, isNull);
  });

  testWidgets('360 wide at 1.3× text does not overflow, list or sheet', (tester) async {
    final long = entry(id: 'long', zh: '一个名字非常非常非常非常非常非常长的像素宠物', en: 'A pet with a very long name indeed');
    await pump(
      tester,
      catalog([WorkshopItemState(entry: long, installed: installed(long, version: '0.9.0'), updateAvailable: true)]),
      width: 360,
      scale: 1.3,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.textContaining('一个名字非常'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
