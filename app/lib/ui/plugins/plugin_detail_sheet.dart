import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../plugins/native/native_state.dart';
import '../../plugins/seams/seams.dart' show PluginSeat, SeatPlacement, Slots, seatPlanProvider;
import '../../share_code/plugin_share.dart' show sharedPluginFromBundle;
import '../../state/plugin_config/plugin_config_state.dart';
import '../../links/plugin_links.dart' show marketPluginLink;
import '../../state/plugins_state.dart';
import '../../state/runtime_capabilities_state.dart';
import '../../update/version.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_navigator.dart';
import '../engine_settings/engine_settings_page.dart';
import '../share_code/plugin_share_sheet.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'config/plugin_config_entries.dart';
import 'market_widgets.dart';
import 'plugin_reload_action.dart';
import 'native/native_plugin_section.dart';
import 'plugin_actions.dart';
import 'plugin_load_status.dart';
import 'plugin_widgets.dart';
import 'seats/plugin_seam_controls.dart';
import 'seats/plugin_web_places.dart';

/// Market entry detail and the install confirmation: what it is, where it
/// comes from, the trust warning, live progress and the one primary action.
Future<void> showMarketPluginSheet(BuildContext context, MarketEntry entry) {
  final ownerRoute = ModalRoute.of(context);
  return showAppSheet<void>(
    context,
    heightFactor: 0.88,
    builder: (_) => SheetNavigator(
      root: (_) => MarketPluginSheet(entry: entry, ownerRoute: ownerRoute),
    ),
  );
}

/// Installed bundle detail: switch, components, problems, remove.
Future<void> showBundleSheet(BuildContext context, PluginBundle bundle) {
  final ownerRoute = ModalRoute.of(context);
  return showAppSheet<void>(
    context,
    heightFactor: 0.75,
    builder: (_) => BundleSheet(name: bundle.name, initial: bundle, ownerRoute: ownerRoute),
  );
}

Future<void> _openLink(BuildContext context, String url) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  final ok = uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.hubPluginBrowserFailed(uri?.host ?? url))));
  }
}

String _date(DateTime t) {
  final local = t.toLocal();
  return local.year == DateTime.now().year
      ? appL10n.monthDay(local)
      : appL10n.hubPluginYearMonth(local.year, '${local.month}');
}

String _sourceText(MarketVersion version) => switch (version.source) {
  MarketNpmSource(:final registry) => registry == null ? 'npm' : 'npm · ${Uri.tryParse(registry)?.host ?? registry}',
  MarketGitSource(:final url) => 'Git · ${Uri.tryParse(url)?.path.replaceFirst('/', '') ?? url}',
};

/// The share key in a plugin sheet's header.
class _ShareKey extends StatelessWidget {
  const _ShareKey({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      SheetIconButton(icon: AppIcons.share, tooltip: context.l10n.hubPluginShare, onPressed: onPressed);
}

class MarketPluginSheet extends ConsumerWidget {
  const MarketPluginSheet({super.key, required this.entry, this.ownerRoute});

  final Route<dynamic>? ownerRoute;

  final MarketEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final plugin = entry.plugin;
    final listing = entry.listing;
    final latest = plugin.latest;
    final host = ref.watch(pluginHostProvider);
    final bundles = ref.watch(installedPluginsProvider).value;
    final status = marketInstallStatus(plugin, bundles);
    final job = ref.watch(pluginInstallsProvider.select((jobs) => jobs[plugin.name]));
    final installed = bundles?.where((b) => b.name == plugin.name).firstOrNull;
    final needsApp = marketNeedsApp(entry, ref.watch(appVersionProvider));
    final blocked = marketBlockedInstall(entry, installed);
    final title = entry.title(locale);
    final description = entry.summary(locale);

    Widget? jobView;
    if (job != null && job.isActive) {
      jobView = PluginInstallProgress(
        job: job,
        onCancel: () => unawaited(ref.read(pluginInstallsProvider.notifier).cancel(plugin.name)),
      );
    } else if (job?.failure case final failure? when job!.phase != PluginInstallPhase.succeeded) {
      // Blocked build scripts: the primary button below asks for consent.
      jobView = PluginFailureBox(failure: failure);
    }

    final stars = plugin.sortKeys['stars'];
    final source = _sourceText(latest);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          l10n.hubPluginDetails,
          actions: [
            _ShareKey(
              onPressed: () => unawaited(
                shareMarketPlugin(
                  context,
                  plugin,
                  card: entry,
                  // The official market's page for it (§6); the share-code
                  // link for plugins only dshfind lists.
                  webLink: listing == null ? null : marketPluginLink(plugin.name),
                ),
              ),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              PluginHero(
                avatar: PluginAvatar(name: plugin.name, title: title, icon: plugin.icon, size: 64),
                title: title,
                subtitle: [?plugin.author, ?entry.categoryTitleIn(locale)].join(' · '),
                badges: [
                  ...marketEntryBadges(context, entry),
                  if (status == MarketInstallStatus.updateAvailable)
                    PluginBadge(l10n.marketUpdateAvailable, tone: PluginBadgeTone.official),
                  if (entry.featured) PluginBadge(l10n.hubPluginFeatured, tone: PluginBadgeTone.featured),
                  if (entry.webOnly) PluginBadge(l10n.hubPluginWebOnly),
                ],
              ),
              const SizedBox(height: 20),
              PluginStats([
                if (stars != null)
                  ('${stars.round()}', l10n.hubPluginStars)
                else
                  (source.split(' · ').first, l10n.hubPluginSource),
                (latest.version, l10n.commonVersion),
                (_date(latest.published), l10n.commonUpdate),
              ]),
              if (blocked) ...[
                const SizedBox(height: 16),
                MarketBlockedBox(
                  version: installed!.version!,
                  onUninstall: host?.canInstall ?? false
                      ? () => unawaited(removePluginBundle(context, installed, ownerRoute: ownerRoute))
                      : null,
                ),
              ],
              if (jobView != null) ...[const SizedBox(height: 16), jobView],
              if (listing != null && listing.screenshots.isNotEmpty) ...[
                const SizedBox(height: 20),
                MarketScreenshots(urls: listing.screenshots),
              ],
              if (description != null) ...[
                const SizedBox(height: 16),
                SelectableText(description, style: theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
              ],
              if (listing != null) ...[const SizedBox(height: 24), MarketRiskCard(listing: listing)],
              const SizedBox(height: 20),
              ListPageCard(
                margin: EdgeInsets.zero,
                children: [
                  if (installed?.version case final version?)
                    ListPageRow(title: l10n.hubPluginInstalledVersion, value: version),
                  if (listing != null) ListPageRow(title: l10n.marketPinnedVersion, value: latest.version),
                  ListPageRow(title: l10n.hubPluginSource, value: source),
                  if (latest.enginesDsh case final range?) ListPageRow(title: l10n.hubPluginRequiresDsh, value: range),
                  if (listing?.minApp case final min?) ListPageRow(title: l10n.marketRequiresApp, value: min.name),
                  ListPageRow(title: l10n.hubPluginPackageName, value: plugin.name),
                  // The pinned version's own page: what the checks looked at.
                  if (listing != null && latest.source is MarketNpmSource)
                    ListPageRow(
                      title: 'npm',
                      meta: 'npmjs.com',
                      chevron: true,
                      onTap: () => unawaited(
                        _openLink(
                          context,
                          'https://www.npmjs.com/package/${plugin.name}/v/${Uri.encodeComponent(latest.version)}',
                        ),
                      ),
                    ),
                  if (plugin.homepage case final url?)
                    ListPageRow(
                      title: l10n.hubPluginHomepage,
                      meta: Uri.tryParse(url)?.host,
                      chevron: true,
                      onTap: () => unawaited(_openLink(context, url)),
                    ),
                  if (plugin.repositoryUrl case final url?)
                    ListPageRow(
                      title: l10n.hubPluginRepository,
                      meta: Uri.tryParse(url)?.host,
                      chevron: true,
                      onTap: () => unawaited(_openLink(context, url)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              PluginTrustNote(local: host?.isLocal ?? true, thirdParty: true),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: _primaryAction(
              context,
              host,
              status,
              job,
              installed,
              needsApp,
              ref.watch(marketInstallRefusedProvider),
            ),
          ),
        ),
      ],
    );
  }

  Widget _primaryAction(
    BuildContext context,
    PluginHost? host,
    MarketInstallStatus status,
    PluginInstallJob? job,
    PluginBundle? installed,
    AppVersion? needsApp,
    bool installRefused,
  ) {
    final l10n = context.l10n;
    final plugin = entry.plugin;
    const size = Size.fromHeight(48);
    if (host == null) {
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: null,
        child: Text(l10n.commonEngineUnreachable),
      );
    }
    final manageable =
        installed != null &&
        (installed.installed || installed.availability == 'profile') &&
        bundleGroup(installed) != BundleGroup.hidden;
    Widget manage() => OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: size),
      onPressed: () => SheetNavigator.of(context).push(
        (_) => BundleSheet(
          name: installed!.name,
          initial: installed,
          title: l10n.hubPluginManageTitle,
          ownerRoute: ownerRoute,
        ),
      ),
      child: Text(l10n.hubPluginManage),
    );
    // Nothing to install or update from here: manage what is there.
    if (manageable && (status == MarketInstallStatus.installed || host.safeMode || !host.canInstall)) {
      return manage();
    }
    // Listed, but this app is too old for it or the engine takes no market
    // installs: shown, not installed.
    final barred = needsApp != null
        ? l10n.marketNeedsApp(needsApp.name)
        : (installRefused ? l10n.marketInstallRefused : null);
    if (barred != null) {
      final reason = FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: null,
        child: Text(barred, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
      if (!manageable) return reason;
      return Row(
        spacing: 12,
        children: [
          Expanded(child: manage()),
          Expanded(child: reason),
        ],
      );
    }
    if (host.safeMode) {
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: null,
        child: Text(l10n.hubPluginSafeModeInstall),
      );
    }
    if (!host.canInstall) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: size),
        icon: const Icon(AppIcons.command, size: 18),
        label: Text(l10n.hubPluginInstallCommand),
        onPressed: () => unawaited(
          showPluginCommandSheet(
            context,
            title: l10n.hubPluginInstallComputer,
            command: pluginInstallCommand(plugin.latest.installTarget(plugin.name).spec),
            hostLabel: host.label,
          ),
        ),
      );
    }
    if (job != null && job.isActive) {
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: null,
        child: Text(l10n.hubPluginInstalling),
      );
    }
    switch (status) {
      case MarketInstallStatus.installed:
        return OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: size),
          onPressed: null,
          child: Text(l10n.commonInstalled),
        );
      case MarketInstallStatus.updateAvailable:
        final update = FilledButton(
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: () => unawaited(updateMarketEntry(context, entry, from: installed?.version)),
          child: Text(l10n.hubPluginUpdateTo(plugin.latest.version)),
        );
        if (!manageable) return update;
        return Row(
          spacing: 12,
          children: [
            Expanded(child: manage()),
            Expanded(child: update),
          ],
        );
      case MarketInstallStatus.notInstalled:
        final failure = job?.phase == PluginInstallPhase.failed ? job!.failure : null;
        if (failure != null && failure.canApproveBuilds) {
          return FilledButton(
            style: FilledButton.styleFrom(minimumSize: size),
            onPressed: () => unawaited(approveBuildsAndRetry(context, job!)),
            child: Text(l10n.hubPluginAllowBuilds),
          );
        }
        return FilledButton(
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: () => unawaited(installMarketEntry(context, entry)),
          child: Text(
            failure != null && failure.retryable ? l10n.hubPluginRetryInstall : l10n.hubPluginInstallOn(host.label),
          ),
        );
    }
  }
}

class BundleSheet extends ConsumerWidget {
  const BundleSheet({super.key, required this.name, required this.initial, this.title, this.ownerRoute});

  final Route<dynamic>? ownerRoute;

  final String name;
  final PluginBundle initial;
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final host = ref.watch(pluginHostProvider);
    final bundles = ref.watch(installedPluginsProvider).value;
    final bundle = bundles?.where((b) => b.name == name).firstOrNull ?? initial;
    final gone = bundles != null && !bundles.any((b) => b.name == name && bundleGroup(b) != BundleGroup.hidden);
    final job = ref.watch(pluginInstallsProvider.select((jobs) => jobs[name]));
    final summary = bundle.summary();
    final error = bundleErrorText(bundle);
    final canSwitch = bundle.readOnlyReason == null && (bundle.installed || bundle.optional) && !gone;
    final configSource = ref.watch(pluginConfigProvider);
    final config = configSource.value;
    final configurable = bundleSettingsRows(bundle, config);
    // Every plugin with fields gets its native page; a third-party one
    // without any keeps its config seat (an island page, or DSH Web).
    final configSeat = PluginSeat(slot: Slots.bundleConfig, placement: SeatPlacement.row, package: bundle.name);
    final configSeated =
        !bundle.official && !gone && configurable.isEmpty && !ref.watch(seatPlanProvider(configSeat.request)).isEmpty;

    // Local installs can't be shared; a market entry adds the picture card.
    final shareable = !gone && sharedPluginFromBundle(bundle) != null;
    final market = shareable ? ref.watch(marketCatalogProvider.select((c) => c.value?.byName[bundle.name])) : null;
    // The official market's entry: a newer pinned version, or this one withdrawn.
    final listed = gone ? null : ref.watch(officialMarketProvider.select((c) => c.value?.byName[bundle.name]));
    final update = listed != null && marketInstallStatus(listed.plugin, [bundle]) == MarketInstallStatus.updateAvailable
        ? listed
        : null;
    final blocked = listed != null && marketBlockedInstall(listed, bundle);
    // The plugin's name for people (its native title, else the bundle's);
    // the package name stays as the quiet line under it.
    final display = ref.watch(nativePluginTitleProvider(bundle.name));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(
          title ?? l10n.hubPluginDetails,
          actions: [
            if (shareable) _ShareKey(onPressed: () => unawaited(shareInstalledPlugin(context, bundle, card: market))),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
            children: [
              PluginHero(
                avatar: PluginAvatar(name: bundle.name, title: display, icon: bundle.meta?.icon, size: 64),
                title: display,
                subtitle: display == bundle.name ? '' : bundle.name,
                monoSubtitle: true,
                badges: [
                  if (bundle.official) PluginBadge(l10n.hubPluginOfficial, tone: PluginBadgeTone.official),
                  if (update != null) PluginBadge(l10n.marketUpdateAvailable, tone: PluginBadgeTone.official),
                ],
              ),
              if (blocked) ...[
                const SizedBox(height: 16),
                // 卸载 is this sheet's own button.
                MarketBlockedBox(version: bundle.version!),
              ],
              if (summary != null) ...[
                const SizedBox(height: 16),
                SelectableText(summary, style: theme.textTheme.bodyMedium?.copyWith(height: 1.7)),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 16),
                PluginFailureBox(
                  failure: PluginFailure(
                    PluginFailureKind.unknown,
                    l10n.hubPluginNotLoaded,
                    error,
                    detail: bundle.error?.diagnostic,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (canSwitch) ...[
                ListPageCard(
                  margin: EdgeInsets.zero,
                  children: [
                    MergeSemantics(
                      child: ListPageRow(
                        icon: AppIcons.power,
                        title: l10n.commonEnable,
                        onTap: () => unawaited(togglePluginBundle(context, bundle, !bundle.enabled)),
                        trailing: Switch.adaptive(
                          value: bundle.enabled,
                          onChanged: (v) => unawaited(togglePluginBundle(context, bundle, v)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              ListPageCard(
                margin: EdgeInsets.zero,
                children: [
                  if (bundle.version case final version?) ListPageRow(title: l10n.commonVersion, value: version),
                  if (update != null)
                    ListPageRow(
                      title: l10n.marketUpdateAvailable,
                      value: update.plugin.latest.version,
                      chevron: true,
                      onTap: () => unawaited(showMarketPluginSheet(context, update)),
                    ),
                  if (bundle.source case final source?) ListPageRow(title: l10n.hubPluginSource, value: source),
                  if (bundle.rows.isNotEmpty)
                    ListPageRow(
                      title: l10n.hubPluginComponents,
                      value: l10n.hubPluginComponentCount(bundle.rows.length),
                    ),
                ],
              ),
              if (bundle.rows.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    [for (final row in bundle.rows) row.meta?.title?.resolve() ?? row.moduleName]
                        .join(l10n.hubPluginComponentSeparator),
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.6),
                  ),
                ),
              if (!gone) PluginReloadAction(bundle: bundle),
              if (configSeated) ...[
                // A third-party plugin's own config page in DSH Web: its
                // schema form, its island page, or the way to DSH Web.
                const SizedBox(height: 16),
                ListPageCard(
                  margin: EdgeInsets.zero,
                  children: [
                    // Unknown fields are not absent fields: wait for the first
                    // catalog before offering an alternate settings route.
                    if (configSource.isLoading && !configSource.hasValue)
                      ListPageRow(icon: AppIcons.configure, title: l10n.commonSettings, meta: l10n.pluginsLoading)
                    else
                      configSeat,
                  ],
                ),
              ] else if (configurable.isNotEmpty) ...[
                const SizedBox(height: 16),
                ListPageCard(
                  margin: EdgeInsets.zero,
                  children: [
                    for (final row in configurable)
                      // A plugin's form on a bridge R7 Host: named and marked
                      // as everywhere else it is listed. A curated page, and
                      // any Host that does not say who carries the entry
                      // (no bridge, an older one): as before.
                      if (!curatedNamespaces.contains(row.rowId) && pluginConfigNamedByBundle(config, row.rowId))
                        ListPageRow(
                          icon: AppIcons.configure,
                          title: configurable.length == 1
                              ? l10n.commonSettings
                              : pluginConfigEntryName(row.rowId, bundles, state: config, l10n: l10n),
                          subtitle: pluginConfigReadOnlyNote(config, row.rowId, l10n: l10n),
                          chevron: true,
                          onTap: () => unawaited(
                            openSettingsPage(
                              context,
                              row.rowId,
                              title: pluginConfigTitle(row.rowId, bundles, state: config, l10n: l10n),
                            ),
                          ),
                        )
                      else
                        ListPageRow(
                          icon: AppIcons.configure,
                          title: configurable.length == 1
                              ? l10n.commonSettings
                              : row.meta?.title?.resolve() ?? row.rowId,
                          chevron: true,
                          onTap: () => unawaited(
                            openSettingsPage(
                              context,
                              row.rowId,
                              title: configurable.length == 1 ? bundle.title() : row.meta?.title?.resolve(),
                            ),
                          ),
                        ),
                  ],
                ),
              ],
              // Loader evidence, then native UI switches and diagnostics.
              if (!gone) PluginLoadStatus(bundle: bundle),
              if (!gone)
                for (final package in nativePackagesOf(bundle)) ...[
                  NativePluginSection(package: package, named: package != bundle.name),
                  NativePluginPanels(package: package),
                ],
              if (!gone) PluginSeamControls(package: bundle.name),
              if (!gone) PluginWebPlacesSection(package: bundle.name, pluginNames: [...?bundle.meta?.title?.all]),
              if (job != null && job.isActive) ...[
                const SizedBox(height: 16),
                PluginInstallProgress(
                  job: job,
                  onCancel: () => unawaited(ref.read(pluginInstallsProvider.notifier).cancel(name)),
                ),
              ],
              if (bundle.isOnDemand) ...[const SizedBox(height: 16), PluginTrustNote(local: host?.isLocal ?? true)],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: _action(context, host, bundle, job, gone),
          ),
        ),
      ],
    );
  }

  Widget _action(BuildContext context, PluginHost? host, PluginBundle bundle, PluginInstallJob? job, bool gone) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    const size = Size.fromHeight(48);
    if (host == null || gone) return const SizedBox.shrink();
    if (bundle.isOnDemand) {
      final spec = bundle.installTargetSpec!;
      if (host.safeMode) {
        return FilledButton(
          style: FilledButton.styleFrom(minimumSize: size),
          onPressed: null,
          child: Text(l10n.hubPluginSafeModeInstall),
        );
      }
      if (!host.canInstall) {
        return FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: size),
          icon: const Icon(AppIcons.command, size: 18),
          label: Text(l10n.hubPluginInstallCommand),
          onPressed: () => unawaited(
            showPluginCommandSheet(
              context,
              title: l10n.hubPluginInstallComputer,
              command: pluginInstallCommand(spec),
              hostLabel: host.label,
            ),
          ),
        );
      }
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: job?.isActive ?? false
            ? null
            : () => unawaited(
                runPluginInstall(context, PluginInstallRequest(name: bundle.name, spec: spec, title: bundle.title())),
              ),
        child: Text(job?.isActive ?? false ? l10n.hubPluginInstalling : l10n.commonInstall),
      );
    }
    if (!bundle.removable) return const SizedBox.shrink();
    if (host.safeMode) {
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: size),
        onPressed: null,
        child: Text(l10n.hubPluginSafeModeRemove),
      );
    }
    if (!host.canInstall) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: size),
        icon: const Icon(AppIcons.command, size: 18),
        label: Text(l10n.hubPluginRemoveCommand),
        onPressed: () => unawaited(
          showPluginCommandSheet(
            context,
            title: l10n.hubPluginRemoveComputer,
            command: 'dsh plugin --profile $pluginProfile remove ${bundle.name}',
            hostLabel: host.label,
          ),
        ),
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: size,
        foregroundColor: colors.danger,
        side: BorderSide(color: colors.danger.withValues(alpha: 0.5)),
      ),
      icon: const Icon(AppIcons.delete, size: 18),
      label: Text(l10n.hubPluginUninstall),
      onPressed: () => unawaited(removePluginBundle(context, bundle, ownerRoute: ownerRoute)),
    );
  }
}

/// Rows of [bundle] with a settings page (a row id is its settings
/// namespace), in bundle order. Empty while the bundle is off or the
/// configuration is unknown.
List<PluginBundleRow> bundleSettingsRows(PluginBundle bundle, PluginConfigState? config) =>
    bundleConfigRows(bundle, config);

/// The detail sheet's head: the big icon, the name (two lines at most), one
/// quiet line, then the tags.
class PluginHero extends StatelessWidget {
  const PluginHero({
    super.key,
    required this.avatar,
    required this.title,
    this.subtitle = '',
    this.subtitleMaxLines = 1,
    this.monoSubtitle = false,
    this.badges = const [],
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final int subtitleMaxLines;
  final bool monoSubtitle;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Row(
      children: [
        avatar,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(height: 1.3),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: subtitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: monoSubtitle
                      ? AppType.monoLabel(color: colors.textTertiary)
                      : theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ],
              if (badges.isNotEmpty) ...[const SizedBox(height: 8), Wrap(spacing: 6, runSpacing: 6, children: badges)],
            ],
          ),
        ),
      ],
    );
  }
}

/// Three equal cells of numbers, app-store style: value on top, a small
/// label under it, hairlines between.
class PluginStats extends StatelessWidget {
  const PluginStats(this.cells, {super.key});

  final List<(String value, String label)> cells;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final line = theme.colorScheme.outlineVariant.withValues(alpha: 0.7);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, (value, label)) in cells.indexed) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: VerticalDivider(width: 1, thickness: 0.5, color: line),
              ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.tabular(theme.textTheme.titleMedium!.copyWith(height: 1.3)),
                  ),
                  const SizedBox(height: 2),
                  Text(label, style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
