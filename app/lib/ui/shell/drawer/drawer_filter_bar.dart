// The drawer's status filters (全部 / 运行中 / 待确认 /
// 未读) as quiet capsules, and the list's options key.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_attention_state.dart';
import '../../common/capsule_chip.dart';
import '../../common/read_list_status.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// One row of filter capsules, the first one's edge on the drawer's 10 line.
/// Scrolls sideways when a large text size needs it. Hidden while the list is
/// empty and nothing is filtered.
class DrawerFilterBar extends ConsumerWidget {
  const DrawerFilterBar({super.key});

  /// Gap between capsules.
  static const gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final filter = ref.watch(drawerFilterProvider);
    final scope = ref.watch(drawerScopeProvider);
    if (scope == null || (scope.sessions.isEmpty && filter == DrawerFilter.all)) {
      return const SizedBox(width: double.infinity);
    }
    late final listed = {for (final s in scope.sessions) s.sessionId};
    final pending = scope.readOnly
        ? 0
        : ref.watch(pendingInteractionsProvider).keys.where((id) => listed.contains(id)).length;
    final unread = scope.readOnly ? 0 : ref.watch(unreadSessionIdsProvider).where((id) => listed.contains(id)).length;
    String label(DrawerFilter f) => switch (f) {
      _ when f == filter && scope.readOnly => readListHeading(f.label, scope.status),
      DrawerFilter.pending when pending > 0 => '${f.label} $pending',
      DrawerFilter.unread when unread > 0 => '${f.label} $unread',
      _ => f.label,
    };
    final theme = Theme.of(context);
    // On the drawer's glass the chips' opaque canvas would hide their faint
    // fill (the capsule clears it only in dark mode).
    return Theme(
      data: theme.copyWith(canvasColor: Colors.transparent),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
        child: Row(
          children: [
            for (final (i, f) in DrawerFilter.values.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Semantics(
                label: l10n.shellFilterLabel(label(f)),
                selected: f == filter,
                excludeSemantics: true,
                button: true,
                onTap: () => ref.read(drawerFilterProvider.notifier).set(f),
                child: CapsuleChoiceChip(
                  label: label(f),
                  selected: f == filter,
                  onSelected: () => ref.read(drawerFilterProvider.notifier).set(f),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「对话列表」 options: a round key at the end of the workspace row, its
/// visible circle ending on the 10 line.
class DrawerViewButton extends StatelessWidget {
  const DrawerViewButton({super.key, required this.onTap});

  final VoidCallback onTap;

  /// Visible circle and tap target (the workspace row's height).
  static const size = 36.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.shellChatList,
      child: Semantics(
        button: true,
        label: l10n.shellChatList,
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: Icon(AppIcons.more, size: 20, color: DshColors.of(context).textTertiary),
            ),
          ),
        ),
      ),
    );
  }
}
