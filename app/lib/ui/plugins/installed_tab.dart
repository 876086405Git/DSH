import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../plugins/native/native_state.dart';
import '../../state/plugins_state.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/read_list_status.dart';
import '../common/search_capsule.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'plugin_actions.dart';
import 'plugin_detail_sheet.dart';
import 'plugin_widgets.dart';
import 'plugins_screen.dart';

/// 「已安装」: third-party bundles of the profile, then DSH's own optional
/// and on-demand bundles. Infrastructure bundles (dsh-base, web-app, ...)
/// are not listed.
class InstalledPluginsSliver extends ConsumerStatefulWidget {
  const InstalledPluginsSliver({super.key, required this.onBrowse});

  /// Switches to the market tab.
  final VoidCallback onBrowse;

  @override
  ConsumerState<InstalledPluginsSliver> createState() => _InstalledPluginsSliverState();
}

class _InstalledPluginsSliverState extends ConsumerState<InstalledPluginsSliver> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(installedPluginsProvider);
    final view = ref.watch(pluginListViewProvider);
    final jobs = ref.watch(pluginInstallsProvider);
    if (view.readOnly && !view.authoritative && view.value == null) {
      if (async.hasError) {
        final failure = describePluginError(async.error!);
        return SliverToBoxAdapter(
          child: PluginsErrorCard(
            title: l10n.pluginsListReadFailed,
            message: failure.message,
            onRetry: () => ref.invalidate(installedPluginsProvider),
          ),
        );
      }
      return SliverToBoxAdapter(child: PluginsLoading(l10n.pluginsReadingPlugins));
    }
    final cached = view.value;
    final bundles = cached == null
        ? async.value ?? const <PluginBundle>[]
        : [for (final row in cached.rows) row.bundle];
    final groups = {
      if (cached != null)
        for (final row in cached.rows) row.bundle.name: row.group,
    };
    BundleGroup group(PluginBundle b) => groups[b.name] ?? bundleGroup(b);
    final terms = _search.text.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    bool matches(Iterable<String> fields) {
      final text = fields.join(' ').toLowerCase();
      return terms.every(text.contains);
    }

    bool matchesBundle(PluginBundle bundle) =>
        terms.isEmpty ||
        matches([
          bundle.name,
          ?bundle.description,
          ...?bundle.meta?.title?.all,
          ...?bundle.meta?.description?.all,
          if (cached == null) ref.watch(nativePluginTitleProvider(bundle.name)),
        ]);

    final installed = [
      for (final b in bundles)
        if (group(b) == BundleGroup.installed && matchesBundle(b)) b,
    ];
    final official = [
      for (final b in bundles)
        if (group(b) == BundleGroup.official && matchesBundle(b)) b,
      for (final b in bundles)
        if (group(b) == BundleGroup.onDemand && matchesBundle(b)) b,
    ];
    final listed = {
      for (final b in bundles)
        if (group(b) == BundleGroup.installed) b.name,
    };
    final pending = [
      for (final job in jobs.values)
        if (!view.readOnly &&
            job.isActive &&
            !listed.contains(job.request.name) &&
            matches([job.request.name, ?job.request.title]))
          job,
    ];

    var index = 0;
    Widget ease(String name, Widget child) => FadeSlideIn(key: ValueKey(name), index: index++, child: child);
    return SliverList.list(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SearchCapsule(
            controller: _search,
            hint: l10n.pluginsSearch,
            onChanged: (_) => setState(() {}),
            onClear: () => setState(_search.clear),
          ),
        ),
        if (terms.isNotEmpty && installed.isEmpty && official.isEmpty && pending.isEmpty)
          FeatureMessage(icon: AppIcons.noResults, title: readListHeading(l10n.pluginsNoMatchingPlugins, view.status)),
        if (terms.isEmpty && installed.isEmpty && pending.isEmpty)
          Column(
            children: [
              if (view.readOnly) Text(readListStatusText(view.status), style: Theme.of(context).textTheme.bodySmall),
              _EmptyInstalled(onBrowse: widget.onBrowse),
            ],
          )
        else if (installed.isNotEmpty || pending.isNotEmpty)
          ListPageCard(
            title: readListHeading(l10n.commonInstalled, view.status),
            children: [
              for (final job in pending) ease(job.request.name, _PendingTile(job: job)),
              for (final bundle in installed)
                ease(
                  bundle.name,
                  BundleTile(
                    bundle: bundle,
                    readOnly: view.readOnly,
                    displaySnapshot: cached != null,
                    job: view.readOnly ? null : jobs[bundle.name],
                  ),
                ),
            ],
          ),
        if (official.isNotEmpty) ...[
          const SizedBox(height: 24),
          ListPageCard(
            title: readListHeading(l10n.pluginsDshOfficial, view.status),
            children: [
              for (final bundle in official)
                ease(
                  bundle.name,
                  BundleTile(
                    bundle: bundle,
                    readOnly: view.readOnly,
                    displaySnapshot: cached != null,
                    job: view.readOnly ? null : jobs[bundle.name],
                  ),
                ),
            ],
          ),
          _Footnote(l10n.pluginsOfficialToggleOnly),
        ],
      ],
    );
  }
}

/// One bundle: icon · title (+ 官方) · version / summary / problem · switch.
class BundleTile extends ConsumerWidget {
  const BundleTile({super.key, required this.bundle, this.job, this.readOnly = false, this.displaySnapshot = false});

  final PluginBundle bundle;
  final PluginInstallJob? job;
  final bool readOnly;
  final bool displaySnapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    bool currentBundle() =>
        !readOnly &&
        !ref.read(pluginListViewProvider).readOnly &&
        (ref.read(installedPluginsProvider).value?.any((b) => identical(b, bundle)) ?? false);
    final summary = bundle.summary();
    final switchable = bundle.readOnlyReason == null && (bundle.installed || bundle.optional);
    final running = job?.isActive ?? false;
    // The official market's entry: a newer pinned version, or this one withdrawn.
    final listed = ref.watch(officialMarketProvider.select((c) => c.value?.byName[bundle.name]));
    final update =
        listed != null && marketInstallStatus(listed.plugin, [bundle]) == MarketInstallStatus.updateAvailable;
    final blocked = listed != null && marketBlockedInstall(listed, bundle);
    final error = blocked ? l10n.marketBlockedRow : bundleErrorText(bundle);
    final subtitle = running
        ? job!.phaseLabel
        : error.isNotEmpty
        ? error
        : [?bundle.version, ?summary].join(' · ');
    final badges = [
      if (bundle.official) PluginBadge(l10n.pluginsOfficial, tone: PluginBadgeTone.official),
      if (blocked)
        PluginBadge(l10n.marketBlockedBadge, tone: PluginBadgeTone.danger)
      else if (update)
        PluginBadge(l10n.marketUpdateAvailable, tone: PluginBadgeTone.official),
    ];

    Widget? trailing;
    if (running) {
      trailing = const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
      );
    } else if (!readOnly && bundle.isOnDemand) {
      trailing = PluginInstallButton(
        status: MarketInstallStatus.notInstalled,
        onPressed: () {
          if (currentBundle()) unawaited(showBundleSheet(context, bundle));
        },
      );
    } else if (switchable || readOnly && (bundle.installed || bundle.optional)) {
      trailing = Switch.adaptive(
        value: bundle.enabled,
        onChanged: readOnly
            ? null
            : (v) {
                if (currentBundle()) unawaited(togglePluginBundle(context, bundle, v));
              },
      );
    }

    // The plugin's own name for people (its native title), else the bundle's.
    final title = displaySnapshot
        ? bundle.title(Localizations.localeOf(context).languageCode)
        : ref.watch(nativePluginTitleProvider(bundle.name));
    return Semantics(
      button: !readOnly,
      child: ListPageRow(
        leading: PluginAvatar(name: bundle.name, title: title, icon: bundle.meta?.icon),
        leadingWidth: 40,
        title: title,
        titleStyle: pluginRowTitle(context),
        badge: badges.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: badges),
        subtitle: subtitle.isEmpty ? null : subtitle,
        subtitleColor: error.isNotEmpty && !running ? colors.danger : null,
        trailing: trailing,
        trailingSemanticLabel: trailing is Switch && !readOnly ? title : null,
        chevron: false,
        onTap: readOnly
            ? null
            : () {
                if (currentBundle()) unawaited(showBundleSheet(context, bundle));
              },
      ),
    );
  }
}

/// An install that has not shown up in the list yet.
class _PendingTile extends ConsumerWidget {
  const _PendingTile({required this.job});

  final PluginInstallJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final title = job.request.title ?? job.request.name;
    return ListPageRow(
      leading: PluginAvatar(name: job.request.name, title: title),
      leadingWidth: 40,
      title: title,
      titleStyle: pluginRowTitle(context),
      subtitle: job.phaseLabel,
      trailing: job.cancellable
          ? TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => unawaited(ref.read(pluginInstallsProvider.notifier).cancel(job.request.name)),
              child: Text(l10n.commonCancel),
            )
          : const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
            ),
    );
  }
}

class _EmptyInstalled extends StatelessWidget {
  const _EmptyInstalled({required this.onBrowse});

  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EmptyView(
      art: const FeatureTile(FeatureKind.plugins, size: FeatureTile.empty),
      title: l10n.pluginsNoThirdParty,
      message: l10n.pluginsPluginsDescription,
      actionLabel: l10n.pluginsBrowseMarket,
      onAction: onBrowse,
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
    );
  }
}
