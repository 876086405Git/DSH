import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shell/golden_harness.dart';
import '../support/fake_plugin_host.dart';
import 'support.dart';

const _nativeRow = 'native-a';
const _customRow = 'custom-b';
const _customTitle = '自定义 B';

PluginBundle _bundle({bool enabled = true}) => PluginBundle.fromJson({
  ...bundleJson(probe, title: {'zh': '混合设置', 'en': 'Mixed settings'}, enabled: enabled),
  'source': 'npm',
  'rows': [
    for (final (id, title) in [(_nativeRow, '原生 A'), (_customRow, _customTitle)])
      {
        'rowId': id,
        'moduleName': probe,
        'entryId': 'include:$id',
        'meta': {'title': title},
      },
  ],
});

SeatInventory _inventory({
  List<String> rows = const [_customRow],
  bool native = true,
  bool bundleConfig = false,
  bool enabled = true,
  bool routeGuard = true,
}) => SeatInventory(
  tier: ClientInventoryTier.bridge,
  routeGuard: routeGuard,
  webReachable: true,
  packages: {
    probe: PluginClientInfo(
      package: probe,
      hasClient: true,
      installed: true,
      enabled: enabled,
      rowIds: const [_nativeRow, _customRow],
      configNamespaces: native ? const [_nativeRow] : const [],
    ),
  },
  occupancy: {
    if (bundleConfig) Slots.bundleConfig: [occupant(Slots.bundleConfig, probe, probe)],
    Slots.rowConfig: [for (final id in rows) occupant(Slots.rowConfig, probe, '$probe#$id')],
  },
);

SeatInventory _legacyInventory({bool native = true}) => SeatInventory.from(
  ClientInventory.combine(
    bundles: [_bundle()],
    boot: const WebBootGraph(
      rev: 'legacy-boot',
      entries: [WebBootEntry(id: probe)],
    ),
  ),
  namespaces: {
    if (native)
      _nativeRow: SettingsNamespaceView.fromJson({
        'ns': _nativeRow,
        'schema': {
          'type': 'object',
          'dict': {
            'enabled': {'type': 'boolean'},
          },
        },
        'value': {'enabled': true},
        'revision': 1,
      }),
  },
  webReachable: true,
);

class _Config extends PluginConfigController {
  _Config(this.config);
  final PluginConfigState config;

  @override
  Future<PluginConfigState?> build() async => config;
}

Future<void> _pump(
  WidgetTester tester, {
  required SeatInventory? inventory,
  bool native = true,
  bool enabled = true,
  IslandBudget budget = const OpenIslandBudget(),
}) async {
  usePhoneSurface(tester);
  final bundle = _bundle(enabled: enabled);
  final client = DshClient.withCarrier(FakePluginCarrier());
  addTearDown(client.close);
  final config = PluginConfigState(
    forms: const {},
    lazy: true,
    entries: {
      if (native) _nativeRow: const PluginConfigEntry(_nativeRow, package: probe),
      _customRow: const PluginConfigEntry(_customRow, package: probe, configurable: false, reason: 'no-schema'),
    },
    scope: PluginConfigScope.of([bundle]),
  );
  await tester.pumpWidget(
    goldenApp(
      home: Scaffold(
        body: BundleSheet(name: probe, initial: bundle),
      ),
      brightness: Brightness.light,
      overrides: [
        ...pluginOverrides(fakeHost(client), selectHost: false),
        ...seatOverrides(inventory: inventory, budget: budget, bundles: [bundle]),
        pluginConfigProvider.overrideWith(() => _Config(config)),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Finder _settingsRows() => find.descendant(
  of: find.byType(BundleSheet),
  matching: find.byWidgetPredicate((w) => w is ListPageRow && w.icon == AppIcons.configure),
);

Finder _customEntry() => find.descendant(
  of: find.byType(BundleSheet),
  matching: find.byWidgetPredicate((w) => w is ListPageRow && w.title == _customTitle),
);

Future<void> _reveal(WidgetTester tester, Finder entry) async {
  await tester.scrollUntilVisible(entry.first, 150, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(entry.first), alignment: 0.3);
  await tester.pump();
}

Future<void> _tapCustom(WidgetTester tester) async {
  await _reveal(tester, _customEntry());
  await tester.tap(_customEntry());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    openedWeb.clear();
  });

  testWidgets('混合包的原生 A 不吞掉只有 rowConfig 的自定义 B', (tester) async {
    await _pump(tester, inventory: _inventory());
    await _reveal(tester, _customEntry());
    expect(_settingsRows(), findsNWidgets(2));
    expect(find.byWidgetPredicate((w) => w is ListPageRow && w.title == '设置'), findsOneWidget);
    await _tapCustom(tester);
    final page = tester.widget<PluginSeatPage>(find.byType(PluginSeatPage));
    expect(
      page.request,
      const SeatRequest(
        slot: Slots.rowConfig,
        placement: SeatPlacement.page,
        package: probe,
        cell: '$probe#$_customRow',
      ),
    );
    final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
    expect(
      (spec.slot, spec.package, spec.cell, spec.form),
      (Slots.rowConfig, probe, '$probe#$_customRow', IslandForm.page),
    );
    expect(openedWeb, isEmpty);
  });

  testWidgets('已被原生配置覆盖的 A 不重复生成 rowConfig 入口', (tester) async {
    await _pump(tester, inventory: _inventory(rows: [_nativeRow, _customRow]));
    await _reveal(tester, _customEntry());
    expect(_settingsRows(), findsNWidgets(2));
    final seats = tester.widgetList<PluginSeat>(find.byType(PluginSeat)).where((seat) => seat.slot == Slots.rowConfig);
    expect(seats.map((seat) => seat.cell), ['$probe#$_customRow']);
  });

  for (final guarded in [true, false]) {
    testWidgets('自定义 B 在${guarded ? '岛预算不足' : '本机无路由保护'}时保留网页兜底', (tester) async {
      await _pump(
        tester,
        inventory: _inventory(routeGuard: guarded),
        budget: guarded ? const NoIslandBudget() : const OpenIslandBudget(),
      );
      await _reveal(tester, _customEntry());
      expect(tester.widget<ListPageRow>(_customEntry()).meta, '网页版');
      await _tapCustom(tester);
      expect(find.byType(PluginSeatPage), findsNothing);
      expect(find.byType(FakeIsland), findsNothing);
      expect(openedWeb.single.pluginItem, ['混合设置', 'Mixed settings', probe]);
    });
  }

  testWidgets('停用包即使还报告旧占位也不生成设置入口', (tester) async {
    await _pump(tester, inventory: _inventory(enabled: false, bundleConfig: true), enabled: false);
    expect(_settingsRows(), findsNothing);
    expect(find.byType(PluginSeat), findsNothing);
  });

  testWidgets('已刷新且没有占位的包不凭行声明制造自定义入口', (tester) async {
    await _pump(tester, inventory: _inventory(rows: const []));
    await _reveal(tester, _settingsRows());
    expect(_settingsRows(), findsOneWidget);
    expect(_customEntry(), findsNothing);
    expect(find.byType(PluginSeat), findsNothing);
  });

  testWidgets('旧主机只推断出 B 的行占位时保留原生 A 而不制造自定义入口', (tester) async {
    final inventory = _legacyInventory();
    expect(inventory.tier, ClientInventoryTier.boot);
    expect(inventory.occupancy, isNull);
    expect(inventory.infoOf(probe).configNamespaces, [_nativeRow]);
    expect(inventory.occupantsFor(Slots.rowConfig, package: probe, cell: '$probe#$_customRow').single.inferred, isTrue);
    await _pump(tester, inventory: inventory);
    await _reveal(tester, _settingsRows());
    expect(_settingsRows(), findsOneWidget);
    expect(tester.widget<ListPageRow>(_settingsRows()).title, '设置');
    expect(tester.widget<ListPageRow>(_settingsRows()).meta, isNull);
    expect(_customEntry(), findsNothing);
    expect(find.byType(PluginSeat), findsNothing);
  });

  testWidgets('旧主机没有原生配置时仍保留整包通用网页兜底', (tester) async {
    final inventory = _legacyInventory(native: false);
    expect(inventory.occupantsFor(Slots.bundleConfig, package: probe).single.inferred, isTrue);
    await _pump(tester, inventory: inventory, native: false, budget: const NoIslandBudget());
    await _reveal(tester, _settingsRows());
    expect(_settingsRows(), findsOneWidget);
    expect(tester.widget<PluginSeat>(find.byType(PluginSeat)).slot, Slots.bundleConfig);
    expect(tester.widget<ListPageRow>(_settingsRows()).meta, '网页版');
    expect(_customEntry(), findsNothing);
    await tester.tap(_settingsRows());
    expect(openedWeb.single.pluginItem, ['混合设置', 'Mixed settings', probe]);
    expect(find.byType(PluginSeatPage), findsNothing);
    expect(find.byType(FakeIsland), findsNothing);
  });

  testWidgets('没有座位清单时不生成自定义入口', (tester) async {
    await _pump(tester, inventory: null, native: false);
    expect(_settingsRows(), findsNothing);
    expect(find.byType(PluginSeat), findsNothing);
  });

  testWidgets('没有原生配置且只有 rowConfig 的包也能进入自定义页面', (tester) async {
    await _pump(tester, inventory: _inventory(native: false), native: false);
    await _reveal(tester, _customEntry());
    expect(_settingsRows(), findsOneWidget);
    await _tapCustom(tester);
    expect(find.byType(PluginSeatPage), findsOneWidget);
    expect(tester.widget<FakeIsland>(find.byType(FakeIsland)).spec.cell, '$probe#$_customRow');
    expect(openedWeb, isEmpty);
  });

  testWidgets('没有原生配置时保留整包入口而不重复列出它的逐行入口', (tester) async {
    await _pump(tester, inventory: _inventory(native: false, bundleConfig: true), native: false);
    await _reveal(tester, _settingsRows());
    expect(_settingsRows(), findsOneWidget);
    final seat = tester.widget<PluginSeat>(find.byType(PluginSeat));
    expect(seat.slot, Slots.bundleConfig);
    expect(_customEntry(), findsNothing);
  });
}
