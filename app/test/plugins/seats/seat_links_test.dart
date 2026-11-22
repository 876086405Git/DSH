// The seats' pure parts: where an occupant lands in DSH Web, the names an island
// looks for, what a row calls an occupant, and the route-guard report the
// islands' security gate reads from the inventory.

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/islands/island_gate.dart';
import 'package:dsh_app/ui/plugins/seats/seat_island.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('seatWebTarget', () {
    test('settings: official and third-party section ids are kept', () {
      expect(
        seatWebTarget(occupant(Slots.settingsSection, probe, 'models')),
        const DshWebTarget(settingsSection: 'models', settingsPackage: probe),
      );
      expect(
        seatWebTarget(occupant(Slots.settingsSection, probe, 'k4-probe')),
        const DshWebTarget(settingsSection: 'k4-probe', settingsPackage: probe),
      );
      expect(
        seatWebTarget(occupant(Slots.generalItem, pet, 'x')),
        const DshWebTarget(settings: DshWebSettings.general),
      );
    });

    test('a section keeps registered names, never its bundle title', () {
      final target = seatWebTarget(
        occupant(Slots.settingsSection, probe, 'k4-probe', label: '探针设置'),
        bundle: probeBundle,
        labels: ['Probe settings', '探针设置'],
      );
      expect(target.toJson(), {
        'settings': 'k4-probe',
        'settingsPackage': probe,
        'settingsLabels': ['探针设置', 'Probe settings'],
      });
    });

    test('a plugin\'s config: its card on the Plugins page, by every name', () {
      expect(seatWebTarget(occupant(Slots.bundleConfig, probe, probe), bundle: probeBundle).pluginItem, [
        '岛屿探针',
        'Island probe',
        probe,
      ]);
      expect(seatWebTarget(occupant(Slots.rowConfig, pet, '$pet#$pet')).pluginItem, [pet]);
    });

    test('common page seams fall back to the corresponding web surface', () {
      expect(seatWebTarget(occupant(Slots.sidebarFooter, probe, 'footer')), const DshWebTarget(sidebar: true));
      expect(
        seatWebTarget(occupant(Slots.settingsPluginsTab, probe, 'extra')),
        const DshWebTarget(settings: DshWebSettings.plugins),
      );
      expect(seatWebTarget(occupant(Slots.pluginDetailSection, probe, 'details')).pluginItem, [probe]);
    });

    test('panels: an official one by id, a third-party one opens the sidebar', () {
      expect(seatWebTarget(occupant(Slots.main, probe, 'schedules')), const DshWebTarget(panel: DshWebPanel.schedules));
      expect(seatWebTarget(occupant(Slots.main, probe, 'k4-panel')), const DshWebTarget(sidebar: true));
    });

    test('conversation slots land on the conversation; Cordis on its panel there', () {
      expect(
        seatWebTarget(occupant(Slots.rightPaneTab, probe, 'k4-tab'), sessionId: 's1'),
        const DshWebTarget(sessionId: 's1'),
      );
      expect(
        seatWebTarget(occupant(Slots.cordisView, 'clock', 'clock'), sessionId: 's1'),
        const DshWebTarget(sessionId: 's1', panel: DshWebPanel.cordis),
      );
      expect(seatWebTarget(occupant('some.root.slot', probe, 'x')), const DshWebTarget());
    });
  });

  group('names', () {
    final inventory = seatInventory(occupancy: fullOccupancy);

    test('a row\'s name: label, then the entry naming it, then the bundle, then the package', () {
      expect(seatEntryTitle(occupant(Slots.settingsSection, probe, 'k4-probe', label: '探针')), '探针');
      expect(seatEntryTitle(occupant(Slots.main, probe, 'k4-panel'), inventory: inventory), '探针面板');
      expect(seatEntryTitle(occupant(Slots.rightPaneTab, probe, 'k4-tab'), inventory: inventory), '探针页签');
      expect(seatEntryTitle(occupant(Slots.main, probe, 'other'), bundle: probeBundle), '岛屿探针');
      expect(seatEntryTitle(occupant(Slots.main, 'dsh-x', 'other')), 'dsh-x');
      expect(seatConfigTitle(occupant(Slots.bundleConfig, probe, probe)), '设置');
    });

    test('an island looks for every language of the label, and a panel by its sidebar entry', () {
      final bridge = BridgeInventory(
        slots: {
          Slots.main: [const ClientSlotOccupant(slot: Slots.main, package: probe, cell: 'k4-panel')],
          Slots.panelList: [
            ClientSlotOccupant(
              slot: Slots.panelList,
              package: probe,
              cell: 'k4-panel',
              label: LocalizedText.fromJson({'zh': '探针面板', 'en': 'Probe panel'}),
            ),
            ClientSlotOccupant(
              slot: Slots.panelList,
              package: pet,
              cell: 'k4-panel',
              label: LocalizedText.fromJson('别人的'),
            ),
          ],
        },
      );
      final item = SeatItem.island(
        occupant(Slots.main, probe, 'k4-panel'),
        const IslandSpec(host: HostRef.local, form: IslandForm.page, slot: Slots.main, cell: 'k4-panel'),
      );
      expect(seatIslandLabels([item], bridge), ['探针面板', 'Probe panel']);
      expect(seatIslandLabels([item], null), isEmpty);
    });
  });

  group('route guard report', () {
    ProviderContainer container(HostRef active, BridgeInventory? bridge) {
      final c = ProviderContainer(
        overrides: [
          activeHostProvider.overrideWith(() => FixedHost(active)),
          bridgeInventoryProvider.overrideWith((ref) async => bridge),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('the active host\'s bridge answers; other hosts are unknown', () async {
      final c = container(HostRef.local, const BridgeInventory(routeGuard: true));
      c.listen(islandRouteGuardReportProvider(HostRef.local), (_, _) {});
      await c.read(bridgeInventoryProvider.future);
      expect(c.read(islandRouteGuardReportProvider(HostRef.local)), isTrue);
      expect(c.read(islandRouteGuardReportProvider(const HostRef.ssh('box'))), isNull);
    });

    test('no bridge, or a bridge without the guard', () async {
      final none = container(HostRef.local, null);
      await none.read(bridgeInventoryProvider.future);
      expect(none.read(seatRouteGuardReportProvider(HostRef.local)), isNull);
      final off = container(HostRef.local, const BridgeInventory());
      await off.read(bridgeInventoryProvider.future);
      expect(off.read(seatRouteGuardReportProvider(HostRef.local)), isFalse);
    });
  });
}
