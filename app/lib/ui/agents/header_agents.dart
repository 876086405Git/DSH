// The chat header's multi-agent pieces (DSH Web shows
// them in its session header: the lineage breadcrumb, 「N 个子代理」 and the
// Agent Teams action).
//
// Each piece reads the current conversation itself, so the header only places
// them: [HeaderLeadSlot] swaps the drawer key for a breadcrumb back to the
// parent in a subagent conversation, [HeaderTitleText] names a child by its
// task, and [HeaderTrailingSlot] adds the agents capsule before the model chip
// (a child has no model chip: its model belongs to its parent's routing).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../../state/sessions_state.dart';
import '../common/fluid_bits.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'lineage_sheet.dart';
import 'team_page.dart';

/// What the header shows for the conversation on screen; null for a new chat.
final _currentAgentsProvider = Provider.autoDispose<(String, HeaderAgents)?>((ref) {
  final sessionId = ref.watch(currentSessionProvider);
  if (sessionId == null) return null;
  return (sessionId, ref.watch(headerAgentsProvider(sessionId)));
});

/// The left key: [menu] (the drawer), or 「‹ 上级对话」 in a subagent
/// conversation.
class HeaderLeadSlot extends ConsumerWidget {
  const HeaderLeadSlot({super.key, required this.menu});

  final Widget menu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(_currentAgentsProvider)?.$2.parent;
    if (parent == null) return menu;
    return HeaderBackKey(parent: parent);
  }
}

/// The title pill's first line: a subagent conversation is named by the task
/// its parent gave it (its creation label, as DSH Web's breadcrumb does).
class HeaderTitleText extends ConsumerWidget {
  const HeaderTitleText(this.title, {super.key, this.style});

  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = ref.watch(_currentAgentsProvider)?.$2.parent;
    final shown = parent?.label ?? title;
    return FluidTextSwap(
      value: shown,
      child: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
    );
  }
}

/// The right side: the agents capsule (when there is one), then [trailing]
/// (the model chip) except in a subagent conversation.
class HeaderTrailingSlot extends ConsumerWidget {
  const HeaderTrailingSlot({super.key, this.trailing});

  /// Null on a phone, where the model chip gives its room to the title.
  final Widget? trailing;

  /// Between the header's pieces.
  static const gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(_currentAgentsProvider);
    final agents = current?.$2;
    final key = agents == null ? null : HeaderAgentsKey(sessionId: current!.$1, agents: agents);
    final showsKey = agents != null && (agents.hasTeam || agents.children > 0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showsKey) ...[const SizedBox(width: gap), key!],
        if (trailing case final trailing? when !(agents?.isChild ?? false)) ...[const SizedBox(width: gap), trailing],
      ],
    );
  }
}

/// 「‹ 上级对话标题」:回到派出这个子代理的对话。
class HeaderBackKey extends ConsumerWidget {
  const HeaderBackKey({super.key, required this.parent});

  final SubagentParent parent;

  static const height = 44.0;
  static const padding = 12.0;
  static const maxWidth = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: l10n.botsBackToParent(parent.parentTitle),
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        style: DshThemeStyle.of(context).headerGlass(Theme.of(context).colorScheme),
        stadium: true,
        grouped: true,
        onTap: () => selectConversation(ref, parent.address.parentSessionId),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height, minWidth: height, maxWidth: maxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: padding),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.back, size: 20, color: theme.colorScheme.onSurface),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    parent.parentTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The agents capsule: the team (members) when the Agent Teams bundle is on,
/// else the subagents (「N 个子代理」; on a phone the compact form DSH Web
/// also uses in a narrow header: glyph + count). A breathing dot on the glyph
/// while any of them runs.
class HeaderAgentsKey extends StatelessWidget {
  const HeaderAgentsKey({super.key, required this.sessionId, required this.agents});

  final String sessionId;
  final HeaderAgents agents;

  static const height = 44.0;
  static const padding = 14.0;
  static const glyph = 18.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final team = agents.hasTeam ? agents.team : null;
    final count = team != null ? team.teammates.length : agents.children;
    final running = agents.running > 0;
    final label = team != null
        ? (count > 0 ? l10n.botsTeamMemberCount(count) : l10n.botsAgentTeam)
        : running
        ? l10n.botsSubagentRunningCount(count, agents.running)
        : l10n.botsSubagentCount(count);
    final icon = Icon(
      team != null ? AppIcons.team : AppIcons.subagents,
      size: glyph,
      color: theme.colorScheme.onSurface,
    );
    // While any of them runs, a breathing dot sits on the glyph's corner.
    final mark = SizedBox.square(
      dimension: glyph,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: icon),
          Positioned(
            top: -2,
            right: -3,
            child: AnimatedOpacity(
              opacity: running ? 1 : 0,
              duration: AppMotion.of(context, AppMotion.quick),
              // Hidden is not enough: the dot's pulse would keep asking for
              // frames while nothing runs (#1094).
              child: TickerMode(
                enabled: running,
                child: const StatusDot(tone: StatusTone.busy, size: 7),
              ),
            ),
          ),
        ],
      ),
    );
    void open() {
      if (team != null) {
        Navigator.of(context).push(TeamPage.route(sessionId: sessionId));
      } else {
        showLineageSheet(context, sessionId: sessionId);
      }
    }

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: count == 0
            ? SizedBox.square(
                dimension: height,
                child: GlassSurface(
                  tier: GlassTier.chrome,
                  style: DshThemeStyle.of(context).headerGlass(Theme.of(context).colorScheme),
                  circle: true,
                  grouped: true,
                  onTap: open,
                  child: Center(child: mark),
                ),
              )
            : GlassSurface(
                tier: GlassTier.chrome,
                style: DshThemeStyle.of(context).headerGlass(Theme.of(context).colorScheme),
                stadium: true,
                grouped: true,
                onTap: open,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: height, minWidth: height),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: padding),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        mark,
                        const SizedBox(width: 6),
                        Text(
                          // Phones have room for the count only (next to
                          // the title and the model chip); tablets say it.
                          MediaQuery.sizeOf(context).width >= 600 && team == null
                              ? l10n.botsSubagentCount(count)
                              : '$count',
                          style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(fontSize: 13, height: 1.2)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
