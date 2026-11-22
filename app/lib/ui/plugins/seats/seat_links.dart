// The "open in DSH Web" end of the plugin seats (docs/design/plugin-seams.md
// §2): where an occupant lands in DSH Web, what it is called, and the entry a
// seat draws for it when it can't be a native form or an island in place.

import 'package:dsh_client/dsh_client.dart' show PluginBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/seams/seams.dart';
import '../../../state/plugins_state.dart';
import '../../common/empty_view.dart';
import '../../common/list_page_row.dart';
import '../../engine_settings/engine_settings_page.dart' show namespaceTitle;
import '../../engine_settings/schema_form.dart' show SchemaUnsupportedField;
import '../../theme/app_icons.dart';
import '../../web/dsh_web_launcher.dart';
import '../../web/web_target.dart';
import 'plugin_seat_page.dart';
import 'seat_island.dart' show seatIslandLabels;

/// Opens DSH Web on a target (in 网页模式 the web home itself goes there);
/// tests swap it for a recorder.
final seatWebOpenerProvider = Provider<void Function(BuildContext context, WidgetRef ref, DshWebTarget target)>(
  (ref) =>
      (context, ref, target) => openDshWeb(context, ref, target: target),
);

/// The installed bundle named [package], if listed.
PluginBundle? seatBundleOf(List<PluginBundle>? bundles, String package) =>
    bundles?.where((b) => b.name == package).firstOrNull;

/// What to call [o]: its registered label, else its bundle's title, else the
/// package name.
String seatOccupantTitle(SlotOccupant o, {PluginBundle? bundle}) {
  final label = o.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  return bundle?.title() ?? o.package;
}

/// What to call [o] where the app lists it: its label, else the label of
/// the entry that names it in DSH Web (a panel's sidebar entry, a tab's
/// title; the `main` or tab body itself is registered without one), else
/// its bundle's title, else the package name.
String seatEntryTitle(SlotOccupant o, {SeatInventory? inventory, PluginBundle? bundle}) {
  final label = o.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final named = switch (o.slot) {
    Slots.main => Slots.panelList,
    Slots.rightPaneTab => Slots.rightPaneTabTitle,
    _ => null,
  };
  if (named != null && inventory != null) {
    final entries = [
      for (final e in inventory.occupantsFor(named, package: o.package))
        if (e.label?.trim().isNotEmpty ?? false) e,
    ];
    final entry = entries.where((e) => e.cell == o.cell).firstOrNull ?? (entries.length == 1 ? entries.single : null);
    if (entry != null) return entry.label!.trim();
  }
  return seatOccupantTitle(o, bundle: bundle);
}

/// A config occupant's row title: 「设置」, or the row's own name for one of
/// several rows (`plugins.row.config`).
String seatConfigTitle(SlotOccupant o, {PluginBundle? bundle}) {
  if (o.slot != Slots.rowConfig) return appL10n.commonSettings;
  final row = o.cell.substring(o.cell.lastIndexOf('#') + 1);
  return bundle?.rows.where((r) => r.rowId == row).firstOrNull?.meta?.title?.resolve() ?? appL10n.commonSettings;
}

/// Where [o] lands in DSH Web. The open bridge (`assets/web/dsh_web_open.js`)
/// opens a settings section by its registered names (not its bundle title).
/// Third-party panels and tabs still land one step short.
DshWebTarget seatWebTarget(SlotOccupant o, {String? sessionId, PluginBundle? bundle, List<String> labels = const []}) {
  switch (o.slot) {
    case Slots.settingsSection:
      if (o.cell.isEmpty) return const DshWebTarget(settings: DshWebSettings.general);
      return DshWebTarget(settingsSection: o.cell, settingsPackage: o.package, settingsLabels: [?o.label, ...labels]);
    case Slots.generalItem:
      return const DshWebTarget(settings: DshWebSettings.general);
    case Slots.settingsPluginsTab:
      return const DshWebTarget(settings: DshWebSettings.plugins);
    case Slots.sidebarFooter:
      return const DshWebTarget(sidebar: true);
    case Slots.bundleConfig || Slots.rowConfig || Slots.pluginDetailSection:
      // The plugin's card on the Plugins page, by any of its names.
      return DshWebTarget(pluginItem: [...?bundle?.meta?.title?.all, o.package]);
    case Slots.main || Slots.panelList:
      final panel = DshWebPanel.values.where((p) => p.key == o.cell).firstOrNull;
      return panel == null ? const DshWebTarget(sidebar: true) : DshWebTarget(panel: panel);
    case Slots.cordisView:
      return DshWebTarget(sessionId: sessionId, panel: DshWebPanel.cordis);
  }
  return DshWebTarget(sessionId: sessionId);
}

/// How a row leads into an occupant.
@immutable
class SeatRowEntry {
  const SeatRowEntry({required this.web, required this.open});

  /// It leaves for DSH Web (the row says 「网页版」).
  final bool web;
  final void Function(BuildContext context) open;
}

/// A row's way into [item] (from a [SeatPlacement.row] seat): the occupant's
/// own page when it can be a native form or an island at page size, DSH Web
/// otherwise. Call from a build: it watches the page's plan.
SeatRowEntry seatRowEntry(WidgetRef ref, SeatContext seat, SeatItem item, {required String title}) {
  final o = item.occupant;
  final page = SeatRequest(
    slot: o.slot,
    placement: SeatPlacement.page,
    sessionId: seat.sessionId,
    package: o.package,
    cell: o.cell,
  );
  final paged = ref
      .watch(seatPlanProvider(page))
      .visible
      .any((i) => i.mode == SeatMode.island || i.mode == SeatMode.native);
  if (paged) {
    return SeatRowEntry(
      web: false,
      open: (context) => Navigator.of(context).push(PluginSeatPage.route(title: title, request: page)),
    );
  }
  final bundle = seatBundleOf(ref.watch(installedPluginsProvider.select((s) => s.value)), o.package);
  final target = seatWebTarget(
    o,
    sessionId: seat.sessionId,
    bundle: bundle,
    labels: seatIslandLabels([item], ref.watch(bridgeInventoryProvider.select((s) => s.value))),
  );
  return SeatRowEntry(web: true, open: (context) => ref.read(seatWebOpenerProvider)(context, ref, target));
}

/// The seats' "open in DSH Web" entry (`SeatRenderers.webLink`).
///
/// - In a list ([SeatPlacement.row], [SeatPlacement.panel]): a row named for
///   the occupant, 「网页版」 at its end. When an island fits at page size the
///   row opens that page instead, and says nothing about the web.
/// - Filling a page: the occupant's name over 「在网页版打开」.
class SeatWebLink extends ConsumerWidget {
  const SeatWebLink({super.key, required this.seat, required this.item});

  final SeatContext seat;
  final SeatItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final o = item.occupant;
    final bundle = seatBundleOf(ref.watch(installedPluginsProvider.select((s) => s.value)), o.package);
    if (item.configNamespace case final ns?) {
      final title =
          bundle?.rows.where((row) => row.rowId == ns).firstOrNull?.meta?.title?.resolve() ?? namespaceTitle(ns);
      return SchemaUnsupportedField(title: title, ns: ns);
    }
    final name = seatEntryTitle(o, inventory: ref.watch(seatInventoryProvider), bundle: bundle);
    if (seat.placement == SeatPlacement.page || seat.placement == SeatPlacement.overlay) {
      final target = seatWebTarget(
        o,
        sessionId: seat.sessionId,
        bundle: bundle,
        labels: seatIslandLabels([item], ref.watch(bridgeInventoryProvider.select((s) => s.value))),
      );
      // Like the pages' empty states: centred, a little high.
      return Align(
        alignment: const Alignment(0, -0.5),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: EmptyView(
            icon: AppIcons.webApp,
            title: name,
            actionLabel: l10n.commonOpenInWeb,
            onAction: () => ref.read(seatWebOpenerProvider)(context, ref, target),
          ),
        ),
      );
    }
    final config = o.slot == Slots.bundleConfig || o.slot == Slots.rowConfig;
    final entry = seatRowEntry(ref, seat, item, title: config ? (bundle?.title() ?? name) : name);
    return ListPageRow(
      icon: config ? AppIcons.configure : AppIcons.plugin,
      title: config ? seatConfigTitle(o, bundle: bundle) : name,
      meta: entry.web ? l10n.commonWeb : null,
      chevron: true,
      onTap: () => entry.open(context),
    );
  }
}
