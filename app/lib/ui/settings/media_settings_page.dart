// 设置 › 能力 › 图像与视频 (docs/design/media-generation.md §5.8): the curated
// page over the media plugin's settings (ui/settings/media/), found under the
// namespace whose schema carries the catalogue (the host may rename the
// instance), else the plugin's own name. The schema form is not drawn here
// any more: services, keys, defaults and the cost guard are curated rows.
// Without the plugin on this host: 「在此主机上安装」, which installs the
// official market's media plugin (docs/design/plugin-market.md §6).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/connection_state.dart';
import '../../state/media_generation.dart';
import '../../state/hosts_state.dart';
import '../../state/plugins_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../plugins/plugin_actions.dart' show installMarketEntry;
import '../plugins/plugin_detail_sheet.dart' show showMarketPluginSheet;
import '../plugins/plugin_widgets.dart' show PluginInstallProgress;
import '../plugins/plugins_screen.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'media/media_settings_home.dart';

class MediaSettingsPage extends ConsumerWidget {
  const MediaSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final namespaces = ref.watch(engineSettingsProvider.select((s) => s.value?.namespaces));
    final ns =
        (namespaces == null ? null : mediaNamespacesOf(namespaces).firstOrNull) ??
        mediaSettingsNamespaces.where((n) => namespaces?.containsKey(n) ?? false).firstOrNull;
    final plugin = ref.watch(mediaPluginProvider);
    if (ns != null) return MediaSettingsHomePage(ns: ns);
    // Still reading what the host has: the scaffold's own loading state.
    if (namespaces == null && plugin == MediaPluginState.ready) {
      return MediaSettingsHomePage(ns: mediaSettingsNamespaces.first);
    }
    return AppPage.list(title: l10n.mediaSettingsTitle, children: const [SizedBox(height: 48), MediaInstallPrompt()]);
  }
}

/// 「图像与视频」 · 「这台主机还没有图像与视频插件」 · 「在此主机上安装」, which
/// installs the official market's media plugin on this host, its progress in
/// place. Where that can't happen from here (a relay host, safe mode, an app
/// too old for it) the plugin's market page says why; without a market entry,
/// or with the plugin installed but off, the plugin pages take over.
class MediaInstallPrompt extends ConsumerWidget {
  const MediaInstallPrompt({super.key, this.compact = false, this.onInstalled});

  final bool compact;

  /// The plugin is on this host now (the sheet closes).
  final VoidCallback? onInstalled;

  Future<void> _install(BuildContext context, WidgetRef ref, MarketEntry? entry) async {
    final listed =
        ref
            .read(installedPluginsProvider)
            .value
            ?.any((b) => isMediaPluginName(b.name) && (b.installed || b.availability == 'profile')) ??
        false;
    if (entry == null || listed) {
      await openMediaPluginMarket(context, tab: listed ? PluginsTab.installed : PluginsTab.market);
      return;
    }
    final host = ref.read(pluginHostProvider);
    if (host == null || !host.canInstall || marketNeedsApp(entry, ref.read(appVersionProvider)) != null) {
      await showMarketPluginSheet(context, entry);
      return;
    }
    // This consumer closes its sheet; the shared install result may still be
    // returned after its Host or route has lost ownership.
    final container = ProviderScope.containerOf(context, listen: false);
    final originHost = container.read(activeHostProvider);
    final route = ModalRoute.of(context);
    var retired = false;
    final hostChanges = container.listen(activeHostProvider, (_, next) {
      if (next != originHost) retired = true;
    });
    // A display PluginHost can disappear/rebuild while this same client
    // recovers a lost install response. Only a replacement client retires it.
    final connectionChanges = container.listen(activeConnectionProvider, (_, next) {
      final client = next.value?.client;
      if (client != null && !identical(client, host.client)) retired = true;
    });
    try {
      final job = await installMarketEntry(context, entry);
      if (job?.phase == PluginInstallPhase.succeeded &&
          context.mounted &&
          !retired &&
          container.read(activeHostProvider) == originHost &&
          identical(container.read(activeConnectionProvider).value?.client, host.client) &&
          route?.isCurrent == true) {
        onInstalled?.call();
      }
    } finally {
      hostChanges.close();
      connectionChanges.close();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final entry = ref.watch(mediaMarketEntryProvider);
    final job = entry == null ? null : ref.watch(pluginInstallsProvider.select((jobs) => jobs[entry.name]));
    // Installed and off still has the plugin pages to go to; otherwise this engine has no way to get it.
    final refused =
        (ref.watch(pluginHostProvider)?.installRefused ?? false) &&
        !(ref
                .watch(installedPluginsProvider)
                .value
                ?.any((b) => isMediaPluginName(b.name) && (b.installed || b.availability == 'profile')) ??
            false);
    return EmptyView(
      icon: AppIcons.generateMedia,
      compact: compact,
      title: l10n.mediaInstallTitle,
      message: refused ? l10n.marketInstallRefused : l10n.mediaInstallBody,
      action: refused
          ? null
          : job != null && job.isActive
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: PluginInstallProgress(
                job: job,
                onCancel: () => unawaited(ref.read(pluginInstallsProvider.notifier).cancel(job.request.name)),
              ),
            )
          : OutlinedButton(
              onPressed: () => unawaited(_install(context, ref, entry)),
              style: OutlinedButton.styleFrom(
                minimumSize: Size(0, compact ? 38 : 44),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              child: Text(l10n.mediaInstallAction),
            ),
    );
  }
}

/// The plugin market, where the media plugin is installed on this host (or
/// [tab]: the installed list, where it is updated).
Future<void> openMediaPluginMarket(BuildContext context, {PluginsTab tab = PluginsTab.market}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PluginsScreen(initialTab: tab)));

/// 生成 where the plugin runs but its catalogue is missing, damaged or of a
/// version this app doesn't know (§4.3): no generation mode, and a word that
/// chat works as usual. The installed plugins (to update it) are one tap away.
Future<void> showMediaUnavailableSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: EmptyView(
        icon: AppIcons.generateMedia,
        compact: true,
        title: context.l10n.mediaUnavailableTitle,
        message: context.l10n.mediaUnavailableBody,
        actionLabel: context.l10n.mediaUnavailableAction,
        onAction: () {
          Navigator.of(sheet).pop();
          openMediaPluginMarket(context, tab: PluginsTab.installed);
        },
      ),
    ),
  ),
);

/// 生成 on a host without the plugin (§2.2, M7): the same prompt as a sheet,
/// closed once the plugin is installed.
Future<void> showMediaInstallSheet(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MediaInstallPrompt(compact: true, onInstalled: () => Navigator.of(sheet).pop()),
    ),
  ),
);
