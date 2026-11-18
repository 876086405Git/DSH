import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../plugins/native/native_state.dart';
import '../../state/hosts_state.dart';
import '../../state/plugins_state.dart';
import '../common/ask_ai.dart';
import '../common/segmented_pill.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'installed_tab.dart';
import 'market_tab.dart';

enum PluginsTab { installed, market }

/// 插件: what is installed on the active host (switch, remove) and the
/// market (dshfind's format-1 index) to install from.
///
/// Installs go to the host picked in the host switcher, into the `web`
/// profile its `dsh web` runs with. Over the relay only switching works;
/// installs show the command to run on that computer.
class PluginsScreen extends ConsumerStatefulWidget {
  const PluginsScreen({super.key, this.initialTab = PluginsTab.installed});

  final PluginsTab initialTab;

  @override
  ConsumerState<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends ConsumerState<PluginsScreen> {
  late PluginsTab _tab = widget.initialTab;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // A list read earlier (the chat page keeps it) may miss what was added
    // since, in the terminal or by the agent: read it again, quietly.
    if (ref.read(installedPluginsProvider).hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        rereadNativeContributions(ref);
        unawaited(ref.read(installedPluginsProvider.notifier).refresh().catchError((Object _) {}));
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _refreshing = true);
    try {
      // Installed entries use this catalogue for update and withdrawal notices.
      ref.invalidate(officialMarketProvider);
      if (_tab == PluginsTab.installed) {
        rereadNativeContributions(ref);
        await ref.read(installedPluginsProvider.notifier).refresh();
      } else {
        ref.invalidate(marketCatalogProvider);
        // The official sections show their own failure; a pull reports dshfind's.
        await ref.read(marketCatalogProvider.future);
      }
    } on Object catch (error) {
      final text = error is MarketFetchException ? error.message : describePluginError(error).message;
      messenger?.showSnackBar(SnackBar(content: Text(appL10n.pluginsRefreshFailure(text))));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = ref.watch(pluginHostProvider);
    // Engine plugins changed (contributions say so): the list follows.
    ref.listen(nativePluginsSyncProvider, (_, _) {});
    final scroll = ScrollConfiguration.of(context);
    // Pull down to read again, however short the list.
    return ScrollConfiguration(
      behavior: scroll.copyWith(physics: AlwaysScrollableScrollPhysics(parent: scroll.getScrollPhysics(context))),
      child: RefreshIndicator(
        onRefresh: _refresh,
        edgeOffset: MediaQuery.paddingOf(context).top + 56,
        child: _page(context, l10n, host),
      ),
    );
  }

  Widget _page(BuildContext context, L10n l10n, PluginHost? host) {
    return AppPage(
      title: l10n.pluginsTitle,
      subtitle: Text(_subtitle(host)),
      actions: [
        const AskAiButton(AskAiTopic.plugins),
        GlassIconButton(
          icon: AppIcons.refresh,
          tooltip: l10n.pluginsRefresh,
          onPressed: _refreshing ? null : () => unawaited(_refresh()),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedPill<PluginsTab>(
              segments: [
                PillSegment(PluginsTab.installed, l10n.commonInstalled),
                PillSegment(PluginsTab.market, l10n.pluginsMarketTitle),
              ],
              selected: _tab,
              onChanged: (t) => setState(() => _tab = t),
            ),
          ),
        ),
        switch (_tab) {
          PluginsTab.installed when host == null && ref.watch(pluginListViewProvider).value == null =>
            const SliverToBoxAdapter(child: _NotConnected()),
          PluginsTab.installed => InstalledPluginsSliver(onBrowse: () => setState(() => _tab = PluginsTab.market)),
          PluginsTab.market => const MarketSliver(),
        },
      ],
    );
  }

  static String _subtitle(PluginHost? host) {
    if (host == null) return appL10n.pluginsConnectToManage;
    if (host.safeMode) return appL10n.pluginsSafeModeOperationsBlocked;
    if (host.installRefused) return appL10n.marketInstallRefused;
    if (!host.canInstall) return appL10n.pluginsRelayToggleOnly(host.label);
    return host.kind == HostKind.local ? appL10n.pluginsInstallThisPhone : appL10n.pluginsInstallHost(host.label);
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyView(
      icon: AppIcons.disconnected,
      title: l10n.commonEngineUnreachable,
      message: l10n.pluginsOfflineDescription,
      padding: EdgeInsets.fromLTRB(32, 24, 32, 8),
    );
  }
}

/// A failure with one retry, shared by both tabs.
class PluginsErrorCard extends StatelessWidget {
  const PluginsErrorCard({super.key, required this.title, required this.message, required this.onRetry});

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyView(
      icon: AppIcons.error,
      title: title,
      message: message,
      actionLabel: l10n.commonRetry,
      onAction: onRetry,
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
    );
  }
}

/// Loading: a small quiet ring with one line.
class PluginsLoading extends StatelessWidget {
  const PluginsLoading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => QuietSpinner(label: text);
}
