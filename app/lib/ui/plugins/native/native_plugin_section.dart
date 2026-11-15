// 设置 › 插件 › 某插件, the plugin's native part (docs/design/native-plugins.md §3.7
// 用户控制, §3.8): a switch per place it shows up, and one quiet status line —
// problems, the last view's size, the last tap's round trip — that opens the
// problems with their paths. Plugins without a native part get nothing here.

import 'package:dsh_client/dsh_client.dart' show DshGoPanel, PluginBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_capabilities.dart';
import '../../../plugins/native/native_model.dart';
import '../../../plugins/native/native_state.dart';
import '../../../state/hosts_state.dart';
import '../../common/empty_view.dart';
import '../../common/list_page_row.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import 'native_panel.dart';

/// `3.2 KB`, `860 B`.
String nativeBytes(int bytes) =>
    bytes < 1024 ? '$bytes B' : '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';

/// The plugin's problems: the bridge's (declaration) and this run's.
List<NativeIssue> nativeIssuesOf(NativePlugin plugin, NativeDiagnostics diagnostics) => [
  ...diagnostics.issues,
  ...plugin.issues,
];

IconData _surfaceIcon(NativeSurface surface) => switch (surface) {
  NativeSurface.composerActions => AppIcons.write,
  NativeSurface.messageActions => AppIcons.chat,
  NativeSurface.composerStrip => AppIcons.info,
  NativeSurface.panel => AppIcons.panel,
  NativeSurface.composerTools => AppIcons.add,
  NativeSurface.sessionActions => AppIcons.more,
  NativeSurface.turnNote => AppIcons.info,
};

/// The packages a bundle's native parts can sit in: its own, and each component's.
List<String> nativePackagesOf(PluginBundle bundle) => {
  bundle.name,
  for (final row in bundle.rows)
    if (row.moduleName.isNotEmpty) row.moduleName,
}.toList();

/// The panels [package] asked to show on its own detail page.
class NativePluginPanels extends ConsumerWidget {
  const NativePluginPanels({super.key, required this.package});

  final String package;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(nativeSurfaceOnProvider((package, NativeSurface.panel)))) return const SizedBox.shrink();
    final panels = ref.watch(
      nativeContributionsProvider.select(
        (c) => c.plugin(package)?.panels.where((p) => p.placement.contains(DshGoPanel.pluginPage)).toList(),
      ),
    );
    if (panels == null || panels.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final panel in panels)
          Padding(
            key: ValueKey('plugin-page-panel|$package|${panel.id}'),
            padding: const EdgeInsets.only(top: 12),
            child: NativePanelView(panel: panel),
          ),
      ],
    );
  }
}

/// The rows in the plugin's sheet; nothing for a plugin without a native
/// part.
class NativePluginSection extends ConsumerWidget {
  const NativePluginSection({super.key, required this.package, this.named = false});

  final String package;

  /// A component on its bundle's page: says whose it is, or two of these would read the same.
  final bool named;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final plugin = ref.watch(nativeContributionsProvider.select((c) => c.plugin(package)));
    if (plugin == null) return const SizedBox.shrink();
    final diagnostics = ref.watch(nativePluginDiagnosticsProvider(package));
    final issues = nativeIssuesOf(plugin, diagnostics);
    final host = ref.watch(activeHostProvider);
    final stats = [
      if (diagnostics.lastViewBytes case final bytes?) l10n.plugslotsViewSize(nativeBytes(bytes)),
      if (diagnostics.lastInvoke case final elapsed?) l10n.plugslotsInvokeMs(elapsed.inMilliseconds),
    ];
    final String status;
    if (!plugin.native) {
      status = nativeIssueText(plugin.state);
    } else if (issues.isNotEmpty) {
      status = l10n.plugslotsIssueCount(issues.length);
    } else {
      status = l10n.plugslotsAllGood;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ListPageCard(
        margin: EdgeInsets.zero,
        children: [
          for (final surface in NativeSurface.values)
            if (plugin.declared.contains(surface))
              Builder(
                builder: (context) {
                  final on = ref.watch(nativeSurfaceOnProvider((package, surface)));
                  void set(bool value) =>
                      ref.read(nativeSurfacePrefsProvider.notifier).set(host, package, surface, value);
                  return MergeSemantics(
                    child: ListPageRow(
                      key: ValueKey('native-switch-${surface.wire}'),
                      icon: _surfaceIcon(surface),
                      title: surface.label,
                      onTap: () => set(!on),
                      trailing: Switch.adaptive(value: on, onChanged: set),
                    ),
                  );
                },
              ),
          // v1.2: whether it may hear the person speak (asked on first use).
          if (plugin.native && plugin.capabilities.contains('voice'))
            Builder(
              builder: (context) {
                final on = ref.watch(nativeVoiceConsentProvider)[NativeVoiceConsents.keyOf(host, package)] == true;
                void set(bool value) => ref.read(nativeVoiceConsentProvider.notifier).set(host, package, value);
                return MergeSemantics(
                  child: ListPageRow(
                    key: const ValueKey('native-switch-voice'),
                    icon: AppIcons.voice,
                    title: l10n.plugslotsVoiceSwitch,
                    onTap: () => set(!on),
                    trailing: Switch.adaptive(value: on, onChanged: set),
                  ),
                );
              },
            ),
          ListPageRow(
            key: const ValueKey('native-status'),
            icon: AppIcons.diagnostics,
            title: named
                ? '${ref.watch(nativePluginTitleProvider(package))} · ${l10n.plugslotsNativeUi}'
                : l10n.plugslotsNativeUi,
            subtitle: stats.isEmpty ? null : stats.join(' · '),
            value: status,
            chevron: true,
            onTap: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => NativePluginIssuesPage(package: package))),
          ),
        ],
      ),
    );
  }
}

/// The problems, each with where it is.
class NativePluginIssuesPage extends ConsumerWidget {
  const NativePluginIssuesPage({super.key, required this.package});

  final String package;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final plugin = ref.watch(nativeContributionsProvider.select((c) => c.plugin(package)));
    final diagnostics = ref.watch(nativePluginDiagnosticsProvider(package));
    final issues = plugin == null ? diagnostics.issues : nativeIssuesOf(plugin, diagnostics);
    return AppPage.list(
      title: l10n.plugslotsNativeUi,
      children: [
        if (diagnostics.lastViewBytes != null || diagnostics.lastInvoke != null) ...[
          ListPageCard(
            children: [
              if (diagnostics.lastViewBytes case final bytes?)
                ListPageRow(title: l10n.plugslotsLastView, value: nativeBytes(bytes)),
              if (diagnostics.lastInvoke case final elapsed?)
                ListPageRow(title: l10n.plugslotsLastInvoke, value: '${elapsed.inMilliseconds} ms'),
            ],
          ),
          const SizedBox(height: 24),
        ],
        if (issues.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: EmptyView(icon: AppIcons.success, title: l10n.plugslotsNoProblems),
          )
        else
          ListPageCard(
            title: l10n.plugslotsProblems,
            children: [
              for (final issue in issues)
                ListPageRow(
                  icon: issue.error ? AppIcons.error : AppIcons.warning,
                  title: issue.message,
                  titleMaxLines: 2,
                  subtitle: issue.pointer.isEmpty ? null : issue.pointer,
                  subtitleMaxLines: 2,
                ),
            ],
          ),
      ],
    );
  }
}
