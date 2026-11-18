// The chat page's 「插件」 sheet (docs/design/plugin-ui-v3.md §3.4): the
// conversation's native `chat.panel` panels, sorted by plugin name, then the
// web plugins' chat-page parts (the seven slots of [Slots.chatPanel]) in one
// panel island under a line naming whose they are. The entry is the last
// capsule above the composer, there only while the sheet has something.
//
// The island is made when the sheet opens and goes 30 s after it closes
// (the island host's grace). It is only tried where each part could be an
// island on its own (this phone's route guard, the bridge's occupancy, no
// ui.json asking for the web) and the budget has room; it gets 8 s to show
// (IslandTiming.sheetReady).
// Anything else — and an island that gives up — is one 「在网页版打开」 row.
//
// Under the island every web plugin gets its ways into the app as rows: the
// conversation tabs it registered (`sidebar.right.pane.tab`, its own page)
// and its settings. A part that is only a switch for something outside the
// island (one that opens a panel the island never shows) then still has a
// way in, instead of a button that does nothing visible.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show DshGoPanel;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_state.dart';
import '../../../plugins/seams/seams.dart';
import '../../../state/plugins_state.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../web/web_target.dart';
import '../plugin_detail_sheet.dart' show showBundleSheet;
import '../seats/plugin_seat_page.dart';
import '../seats/seat_links.dart' show seatBundleOf, seatEntryTitle, seatWebOpenerProvider, seatWebTarget;
import '../seats/session_plugins_tab.dart' show sessionPluginPlanProvider;
import 'native_panel.dart';

/// The measured geometry (`chat_plugins_sheet_test.dart`).
abstract final class ChatPluginsMetrics {
  /// Both sides of every card: the sheets' gutter.
  static const side = kSheetGutter;

  /// Between two cards.
  static const gap = 12.0;

  /// The sources line → the web card.
  static const sourcesGap = 8.0;

  /// Of the room under the status bar: where the sheet opens, and how far
  /// it pulls up.
  static const initial = 0.5;
  static const full = 1.0;
}

/// The chat page's seven slots in page order (the header's, then the
/// composer's): how the island stacks them (`recipes.json` `dsh-go.chat`)
/// and how the sources line names them.
const chatSheetSlots = [
  Slots.headerActions,
  Slots.headerUtilities,
  Slots.inputDock,
  Slots.inputLeft,
  Slots.inputRight,
  Slots.inputOverlay,
  Slots.composerDock,
];

/// The conversation's native panels for the chat page, by plugin name.
final chatNativePanelsProvider = Provider.autoDispose<List<NativePanel>>((ref) {
  final panels = [
    for (final p in ref.watch(nativePanelsProvider))
      if (p.placement.contains(DshGoPanel.chatPanel)) p,
  ];
  final names = {for (final p in panels) p.package: ref.watch(nativePluginTitleProvider(p.package)).toLowerCase()};
  panels.sort((a, b) {
    final byName = names[a.package]!.compareTo(names[b.package]!);
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return panels;
});

/// The web plugins' chat-page parts of one conversation.
@immutable
class ChatWebPlugins {
  const ChatWebPlugins({required this.seat, this.items = const [], this.island});

  final SeatContext seat;

  /// Their entries, in page order ([chatSheetSlots]).
  final List<SeatItem> items;

  /// The one island for all of them; null: 「在网页版打开」.
  final IslandSpec? island;

  bool get isEmpty => items.isEmpty;

  /// Whose they are, first seen first.
  List<String> get packages => [
    ...{for (final i in items) i.occupant.package},
  ];
}

final chatWebPluginsProvider = Provider.autoDispose.family<ChatWebPlugins, String>((ref, sessionId) {
  final plans = [
    for (final slot in chatSheetSlots)
      ref.watch(seatPlanProvider(SeatRequest(slot: slot, placement: SeatPlacement.panel, sessionId: sessionId))),
  ];
  final seat = plans.first.seat;
  final items = [
    for (final plan in plans)
      for (final item in plan.items)
        if (item.mode == SeatMode.island || item.mode == SeatMode.webLink) item,
  ];
  if (items.isEmpty) return ChatWebPlugins(seat: seat);
  // One island shows all seven slots: only when every part could be one,
  // and nothing in them was hidden (it would show there all the same).
  final whole = plans.every((p) => p.items.every((i) => i.mode == SeatMode.island));
  if (!whole) return ChatWebPlugins(seat: seat, items: items);
  final spec = IslandSpec(
    host: seat.host,
    form: IslandForm.panel,
    slot: Slots.chatSheet,
    sessionId: sessionId,
    maskOfficial: true,
  );
  return ChatWebPlugins(seat: seat, items: items, island: ref.watch(islandBudgetProvider).canOpen(spec) ? spec : null);
});

/// Whether the sheet has anything: the entry capsule shows only then.
final chatPluginsHaveContentProvider = Provider.autoDispose.family<bool, String>(
  (ref, sessionId) =>
      ref.watch(chatNativePanelsProvider).isNotEmpty || !ref.watch(chatWebPluginsProvider(sessionId)).isEmpty,
);

/// The conversation's plugin tabs (`sidebar.right.pane.tab`) and views
/// (`conversation.view`): a web plugin's own pages in the app. The sheet
/// lists them under its parts, so a plugin whose part is a switch for
/// something the island never shows still has a way in
/// (`docs/design/plugin-ui-v3.md` §3.3).
final chatSheetPagesProvider = Provider.autoDispose.family<List<SeatItem>, String>((ref, sessionId) {
  final tabs = ref.watch(
    seatPlanProvider(SeatRequest(slot: Slots.rightPaneTab, placement: SeatPlacement.page, sessionId: sessionId)),
  );
  final views = ref.watch(
    seatPlanProvider(SeatRequest(slot: Slots.conversationView, placement: SeatPlacement.page, sessionId: sessionId)),
  );
  return [...tabs.visible, ...views.visible];
});

Future<void> showChatPluginsSheet(BuildContext context, {required String sessionId}) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (_) => ChatPluginsSheet(sessionId: sessionId));

class ChatPluginsSheet extends ConsumerWidget {
  const ChatPluginsSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final native = ref.watch(chatNativePanelsProvider);
    final web = ref.watch(chatWebPluginsProvider(sessionId));
    final bottom = MediaQuery.paddingOf(context).bottom;
    // Everything went (a plugin switched off) while it was open: nothing to
    // stay open for.
    if (native.isEmpty && web.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) unawaited(Navigator.of(context).maybePop());
      });
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: ChatPluginsMetrics.initial,
      minChildSize: ChatPluginsMetrics.initial,
      maxChildSize: ChatPluginsMetrics.full,
      snap: true,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.plugslotsChatEntry),
          Expanded(
            child: ListView(
              key: const ValueKey('chat-plugins-list'),
              controller: controller,
              padding: EdgeInsets.fromLTRB(ChatPluginsMetrics.side, 4, ChatPluginsMetrics.side, bottom + 24),
              children: [
                for (final (i, panel) in native.indexed) ...[
                  if (i > 0) const SizedBox(height: ChatPluginsMetrics.gap),
                  KeyedSubtree(
                    key: ValueKey('chat-plugins-native|${panel.package}|${panel.id}'),
                    child: NativePanelView(panel: panel, sessionId: sessionId),
                  ),
                ],
                if (!web.isEmpty) ...[
                  if (native.isNotEmpty) const SizedBox(height: ChatPluginsMetrics.gap + 4),
                  _WebPlugins(web: web, sessionId: sessionId),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The web plugins' chat-page parts for the side panel: what the sheet shows of them, with
/// a way on to the plugin pages it doesn't list (those of plugins with no such part).
class ChatWebPluginsPane extends ConsumerWidget {
  const ChatWebPluginsPane({super.key, required this.sessionId, required this.onOtherPages});

  final String sessionId;
  final VoidCallback onOtherPages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final web = ref.watch(chatWebPluginsProvider(sessionId));
    // What 对话详情's tab holds. A conversation's own pages of these plugins are rows under
    // their parts; global pages, even beside those views, are listed nowhere here.
    final plan = ref.watch(sessionPluginPlanProvider(sessionId));
    final others = plan.visible.where(
      (item) => item.occupant.slot == Slots.main || !web.packages.contains(item.occupant.package),
    );
    return ListView(
      key: const ValueKey('chat-plugins-pane'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        _WebPlugins(web: web, sessionId: sessionId),
        if (others.isNotEmpty)
          ListPageCard(
            key: const ValueKey('chat-plugins-other-pages'),
            margin: const EdgeInsets.only(top: ChatPluginsMetrics.gap),
            children: [
              ListPageRow(icon: AppIcons.plugin, title: context.l10n.hubPlugins, chevron: true, onTap: onOtherPages),
            ],
          ),
      ],
    );
  }
}

/// The capsule row's id for the entry (`composer_capsules.dart`).
const chatPluginsCapsuleId = 'dsh-go:plugins';

/// The web plugins' part: whose they are, then their island or the way to
/// DSH Web.
class _WebPlugins extends ConsumerStatefulWidget {
  const _WebPlugins({required this.web, required this.sessionId});

  final ChatWebPlugins web;
  final String sessionId;

  @override
  ConsumerState<_WebPlugins> createState() => _WebPluginsState();
}

class _WebPluginsState extends ConsumerState<_WebPlugins> {
  /// The island that fell back: the rows from then on.
  IslandSpec? _fallen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final web = widget.web;
    final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
    final names = [for (final package in web.packages) seatBundleOf(bundles, package)?.title() ?? package];
    final spec = web.island;
    final island = ref.watch(seatRenderersProvider).island;
    final pages = [
      for (final item in ref.watch(chatSheetPagesProvider(widget.sessionId)))
        if (web.packages.contains(item.occupant.package)) item,
    ];
    Widget fallback(BuildContext context) {
      if (_fallen != spec) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _fallen = spec);
        });
      }
      // The ways in below cover it: nothing to show in the island's place.
      return const SizedBox.shrink();
    }

    final islandBody = spec == null || spec == _fallen || island == null
        ? null
        : GlassSurface(
            key: const ValueKey('chat-plugins-island'),
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            child: KeyedSubtree(
              key: ValueKey('island|${spec.key}'),
              child: Builder(builder: (context) => island(context, spec, web.items, fallback)),
            ),
          );

    // A conversation tab of one of them: its own page in the app.
    Widget pageRow(SeatItem item) {
      final o = item.occupant;
      final bundle = seatBundleOf(bundles, o.package);
      final title = seatEntryTitle(o, bundle: bundle);
      // Nothing native or on an island: the tab is the way to DSH Web.
      final onWeb = item.mode == SeatMode.webLink;
      return Builder(
        key: ValueKey('chat-plugins-page|${o.package}|${o.cell}'),
        builder: (context) => ListPageRow(
          icon: AppIcons.plugin,
          title: title,
          meta: onWeb ? l10n.commonWeb : null,
          chevron: true,
          onTap: () {
            if (onWeb) {
              final target = seatWebTarget(o, sessionId: widget.sessionId, bundle: bundle);
              ref.read(seatWebOpenerProvider)(context, ref, target);
            } else {
              Navigator.of(context).push(
                PluginSeatPage.route(
                  title: title,
                  request: SeatRequest(
                    slot: o.slot,
                    placement: SeatPlacement.page,
                    sessionId: widget.sessionId,
                    package: o.package,
                    cell: o.cell,
                  ),
                ),
              );
            }
          },
        ),
      );
    }

    // The ways in: one row per conversation tab, its settings, DSH Web.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            l10n.plugslotsChatWebFrom(names.join(l10n.viewListSeparator)),
            key: const ValueKey('chat-plugins-sources'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
        if (islandBody != null) ...[const SizedBox(height: ChatPluginsMetrics.sourcesGap), islandBody],
        const SizedBox(height: ChatPluginsMetrics.sourcesGap),
        ListPageCard(
          key: const ValueKey('chat-plugins-ways-in'),
          margin: EdgeInsets.zero,
          children: [
            for (final item in pages) pageRow(item),
            for (final package in web.packages)
              if (seatBundleOf(bundles, package) case final bundle?)
                ListPageRow(
                  key: ValueKey('chat-plugins-settings|$package'),
                  icon: AppIcons.settings,
                  title: l10n.commonSettings,
                  meta: web.packages.length > 1 ? bundle.title() : null,
                  chevron: true,
                  onTap: () => unawaited(showBundleSheet(context, bundle)),
                ),
            ListPageRow(
              key: const ValueKey('chat-plugins-web-link'),
              icon: AppIcons.webApp,
              title: l10n.commonOpenInWeb,
              meta: l10n.commonWeb,
              chevron: true,
              onTap: () => ref.read(seatWebOpenerProvider)(context, ref, DshWebTarget(sessionId: widget.sessionId)),
            ),
          ],
        ),
      ],
    );
  }
}
