// Every file a session delivered or generated, on the 对话详情 「文件」 tab and its own
// page (the chat shows them turn by turn).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/artifacts.dart';
import '../chat/widgets/artifact_card.dart';
import '../common/empty_view.dart';
import '../common/list_page_row.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Newest first, each path once (its latest turn).
List<Artifact> latestArtifacts(List<TurnArtifacts> groups) {
  final seen = <String>{};
  return [
    for (final group in groups.reversed)
      for (final file in group.files)
        if (seen.add(file.path)) file,
  ];
}

/// The block atop the 「文件」 tab: the latest few delivered files, and the way
/// to the full list. Takes no room while the conversation has delivered none.
class SessionArtifactsSection extends ConsumerWidget {
  const SessionArtifactsSection({super.key, required this.sessionId});

  final String sessionId;

  static const shownCount = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final groups = ref.watch(sessionArtifactsProvider(sessionId));
    final files = latestArtifacts(groups);
    if (files.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final shown = files.take(shownCount).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: GlassSurface(
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: l10n.featuresArtifactsSemantic(files.length),
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => Navigator.of(context).push(SessionArtifactsPage.route(sessionId)),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Icon(AppIcons.artifacts, size: 16, color: colors.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.featuresArtifactsTitle,
                            style: theme.textTheme.titleSmall?.copyWith(fontSize: 14, height: 1.3),
                          ),
                        ),
                        Text(
                          files.length > shownCount
                              ? l10n.featuresArtifactsAllCount(files.length)
                              : l10n.featuresArtifactsCount(files.length),
                          style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                        ),
                        Icon(AppIcons.disclosure, size: 18, color: dsh.textTertiary),
                      ],
                    ),
                  ),
                ),
              ),
              for (final file in shown) ArtifactTile(key: ValueKey(file.path), sessionId: sessionId, artifact: file),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every file the conversation delivered, grouped by round, newest first.
class SessionArtifactsPage extends ConsumerWidget {
  const SessionArtifactsPage({super.key, required this.sessionId});

  final String sessionId;

  static Route<void> route(String sessionId) =>
      MaterialPageRoute<void>(builder: (_) => SessionArtifactsPage(sessionId: sessionId));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final groups = ref.watch(sessionArtifactsProvider(sessionId));
    final total = latestArtifacts(groups).length;
    final theme = Theme.of(context);
    return AppPage(
      title: l10n.featuresArtifactsTitle,
      subtitle: Text(
        total == 0 ? l10n.featuresArtifactsNoFiles : l10n.featuresArtifactsTotal(total),
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      slivers: [
        if (groups.isEmpty)
          SliverToBoxAdapter(
            child: EmptyView(
              icon: AppIcons.artifacts,
              title: l10n.featuresArtifactsEmpty,
              message: l10n.featuresArtifactsEmptyHint,
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
            ),
          ),
        SliverList.list(
          children: [
            for (final (i, group) in groups.reversed.indexed)
              ListPageCard(
                margin: EdgeInsets.fromLTRB(16, i == 0 ? 0 : 24, 16, 0),
                title: group.delivered
                    ? l10n.featuresArtifactsDeliveredTurn(group.turn)
                    : l10n.featuresArtifactsGeneratedTurn(group.turn),
                children: [
                  for (final file in group.files)
                    ArtifactTile(
                      key: ValueKey('${group.endSeq}:${file.path}'),
                      sessionId: sessionId,
                      artifact: file.withImageSnapshot(),
                      dense: true,
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
