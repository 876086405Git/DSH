// 导入体检 (docs/design/roleplay-roadmap.md P0, engine T22): what an imported
// card, preset, lorebook or regex script holds, how much of it runs here, and
// what is kept but not run. Read from the report the import filed; an asset
// imported before reports existed is checked on request.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The report filed for an asset; null when there is none.
final tavernImportReportProvider = FutureProvider.autoDispose.family<TavernImportReport?, (TavernImportKind, String)>(
  (ref, key) => ref.watch(tavernProvider).readImportReport(key.$1, key.$2),
);

/// A verdict in a word.
String tavernVerdictText(L10n l10n, TavernImportVerdict verdict) => switch (verdict) {
  TavernImportVerdict.usable => l10n.tavernVerdictUsable,
  TavernImportVerdict.partial => l10n.tavernVerdictPartial,
  TavernImportVerdict.preserveOnly => l10n.tavernVerdictPreserve,
};

class TavernImportReportPage extends ConsumerStatefulWidget {
  const TavernImportReportPage({super.key, required this.kind, required this.assetId, required this.name});

  final TavernImportKind kind;
  final String assetId;

  /// What the asset is called, for the title.
  final String name;

  static Route<void> route({required TavernImportKind kind, required String assetId, required String name}) =>
      MaterialPageRoute<void>(
        builder: (_) => TavernImportReportPage(kind: kind, assetId: assetId, name: name),
      );

  @override
  ConsumerState<TavernImportReportPage> createState() => _TavernImportReportPageState();
}

class _TavernImportReportPageState extends ConsumerState<TavernImportReportPage> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await ref.read(tavernProvider).recheckImport(widget.kind, widget.assetId);
      ref.invalidate(tavernImportReportProvider((widget.kind, widget.assetId)));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final report = ref.watch(tavernImportReportProvider((widget.kind, widget.assetId)));
    final title = '${l10n.tavernReport} · ${widget.name}';
    return AppPage.list(
      title: title,
      children: switch (report) {
        AsyncData(value: null) || AsyncError() => [
          EmptyView(
            key: const ValueKey('tavern-report-none'),
            icon: AppIcons.article,
            title: l10n.tavernReportNone,
            message: l10n.tavernReportNoneMessage,
            actionLabel: l10n.tavernReportCheckNow,
            onAction: _checking ? null : () => unawaited(_check()),
          ),
        ],
        AsyncData(value: final report?) => [
          Padding(
            key: const ValueKey('tavern-report-verdict'),
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tavernVerdictText(l10n, report.verdict),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: switch (report.verdict) {
                      TavernImportVerdict.usable => dsh.success,
                      TavernImportVerdict.partial => dsh.warning,
                      TavernImportVerdict.preserveOnly => dsh.textTertiary,
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    l10n.tavernReportChecked(shortTime(report.checkedAt)),
                    if (report.renderLevel case final level?)
                      [l10n.tavernReportRender0, l10n.tavernReportRender1, l10n.tavernReportRender2][level],
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                ),
              ],
            ),
          ),
          if (report.stale)
            SettingsSection(
              children: [
                SettingsTile(
                  key: const ValueKey('tavern-report-stale'),
                  title: l10n.tavernReportStale,
                  value: Text(l10n.tavernReportRecheck),
                  onTap: _checking ? null : () => unawaited(_check()),
                ),
              ],
            ),
          if (report.counts.entries.where((e) => e.value > 0).toList() case final counts when counts.isNotEmpty)
            SettingsSection(
              title: l10n.tavernReportCounts,
              children: [
                for (final MapEntry(:key, :value) in counts)
                  SettingsTile(tinted: false, title: _countName(context, key), value: Text('$value'), chevron: false),
              ],
            ),
          SettingsSection(
            title: l10n.tavernReportFindings,
            children: [
              if (report.findings.isEmpty)
                SettingsTile(
                  key: const ValueKey('tavern-report-clean'),
                  tinted: false,
                  title: l10n.tavernReportNoFindings,
                  chevron: false,
                )
              else
                for (final finding in report.findings)
                  SettingsTile(
                    icon: switch (finding.kind) {
                      TavernImportFindingKind.invalid => AppIcons.error,
                      TavernImportFindingKind.unsupported => AppIcons.remove,
                      _ => AppIcons.info,
                    },
                    tinted: false,
                    title: finding.message,
                    subtitle: finding.path,
                    chevron: false,
                  ),
            ],
          ),
        ],
        _ => const [QuietSpinner()],
      },
    );
  }
}

/// A count's name: the engine's key, in words where it is a common one.
String _countName(BuildContext context, String key) {
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  const names = {
    'worldInfoBooks': ('世界书', 'Lorebooks'),
    'entriesStored': ('世界书条目', 'Lorebook entries'),
    'entriesEnabled': ('启用的条目', 'Entries on'),
    'entriesDisabled': ('关闭的条目', 'Entries off'),
    'regexScripts': ('正则脚本', 'Regex scripts'),
    'regexIncompatible': ('不兼容的正则', 'Regex that will not run'),
    'scripts': ('脚本', 'Scripts'),
    'helperScripts': ('酒馆助手脚本', 'Helper scripts'),
    'htmlFragments': ('HTML 片段', 'HTML fragments'),
    'assets': ('资源', 'Assets'),
    'embeddedFiles': ('内嵌文件', 'Embedded files'),
    'prompts': ('提示词', 'Prompts'),
    'macroOccurrences': ('宏', 'Macros'),
    'decoratorLines': ('装饰器', 'Decorators'),
  };
  final name = names[key];
  return name == null ? key : (zh ? name.$1 : name.$2);
}
