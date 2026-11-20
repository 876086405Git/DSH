// 酒馆设置 › 数据 › 用量统计 (docs/design/roleplay-roadmap.md §4, 我的 › 用量):
// what every chat has taken, as the model reported it: the whole at a glance,
// then each chat, the one that took the most first. A chat opens from here.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_session_usage.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_page.dart';
import 'tavern_widgets.dart';

class TavernUsagePage extends ConsumerWidget {
  const TavernUsagePage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernUsagePage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final all = ref.watch(tavernAllUsageProvider).value;
    final names = {
      for (final c in ref.watch(tavernCharactersProvider).value ?? const <TavernCharacter>[]) c.id: c.name,
    };
    return AppPage.list(
      title: l10n.tavernUsageStats,
      children: [
        if (all == null)
          const QuietSpinner()
        else if (all.isEmpty)
          EmptyView(
            key: const ValueKey('tavern-usage-none'),
            icon: AppIcons.chart,
            title: l10n.tavernSessionUsageNone,
            compact: true,
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          )
        else ...[
          // The whole, as 本局用量 shows one chat.
          Padding(
            key: const ValueKey('tavern-usage-total'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                TavernFigure(
                  label: l10n.tavernStageTokensIn,
                  value: tavernTokenCount(all.fold(0, (n, c) => n + c.usage.prompt), zh: zh),
                ),
                const SizedBox(width: 8),
                TavernFigure(
                  label: l10n.tavernStageCache,
                  value: switch (all.fold(0, (n, c) => n + c.usage.prompt)) {
                    0 => '—',
                    final prompt => '${(100 * all.fold(0, (n, c) => n + c.usage.cacheHit) / prompt).round()}%',
                  },
                ),
                const SizedBox(width: 8),
                TavernFigure(
                  label: l10n.tavernStageTokensOut,
                  value: tavernTokenCount(all.fold(0, (n, c) => n + c.usage.completion), zh: zh),
                ),
              ],
            ),
          ),
          // What the priced replies cost, as 本局用量 says it; the rest counted apart.
          if (all.fold(0, (n, c) => n + c.usage.replies - c.usage.unpriced) > 0)
            Padding(
              key: const ValueKey('tavern-usage-cost'),
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 6),
              child: Text(
                l10n.tavernSessionUsageCost('US\$${tavernUsd(all.fold(0.0, (n, c) => n + c.usage.cost))}'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (all.fold(0, (n, c) => n + c.usage.unpriced) case final unpriced when unpriced > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
              child: Text(l10n.tavernSessionUsageUnpriced(unpriced), style: quiet),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(l10n.tavernUsageAllNote, style: quiet),
          ),
          SettingsSection(
            children: [
              for (final c in all)
                SettingsTile(
                  key: ValueKey('tavern-usage-${c.chat.id}'),
                  title: [
                    ?names[c.chat.characterId],
                    if (c.chat.title.trim().isNotEmpty) c.chat.title.trim(),
                  ].join(' · '),
                  subtitle: [
                    l10n.tavernUsageChatReplies(c.usage.replies, tavernTokenCount(c.usage.completion, zh: zh)),
                    if (c.usage.replies > c.usage.unpriced) tavernCostLabel(l10n, c.usage.cost),
                  ].join('\n'),
                  value: Text(tavernTokenCount(c.total, zh: zh)),
                  onTap: () => unawaited(Navigator.of(context).push(TavernChatPage.route(c.chat.id))),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
