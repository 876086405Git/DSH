// The drawer's chrome while choosing conversations: a
// header (全选 · 已选 N 个 · 完成) in place of the brand row, and an action bar
// (移到文件夹 · 置顶 · 归档 · 删除) in place of the identity bar, at the same heights
// so nothing below or above moves.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/workspaces_state.dart';
import '../../../state/session_deletion_state.dart';
import 'session_deletion.dart';
import '../../common/pressable.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Replaces the brand row: 全选 on the 20 line, the count centred on the
/// drawer, 完成 where 新对话 was (same 36 pill, same 10 edge: the drawer's
/// one primary element stays in its place).
class DrawerSelectionHeader extends ConsumerWidget {
  const DrawerSelectionHeader({super.key, this.now});

  /// Clock override for the list's day groups (tests).
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // What 全选 picks: the conversations on screen.
    final selectable = drawerSelectableIds(watchDrawerBlocks(ref, now: now) ?? const []);
    // Ticking a row rebuilds only the bar, not the sorted, grouped list above.
    return Consumer(builder: (context, ref, _) => _bar(context, ref, selectable));
  }

  Widget _bar(BuildContext context, WidgetRef ref, List<String> selectable) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final selected = ref.watch(drawerSelectionProvider) ?? const {};
    final notifier = ref.read(drawerSelectionProvider.notifier);
    final all = selectable.isNotEmpty && selectable.every(selected.contains);
    final count = selected.length;
    return Padding(
      // Same box as the brand row: 14 above, 10 below, a 36 line.
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
      child: SizedBox(
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Semantics(
              liveRegion: true,
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.quick),
                child: Text(
                  count == 0 ? l10n.shellSelectChats : l10n.shellSelectedCount(count),
                  key: ValueKey(count),
                  style: AppType.tabular(theme.textTheme.titleSmall!),
                ),
              ),
            ),
            Row(
              children: [
                _TextKey(
                  label: all ? l10n.shellDeselectAll : l10n.shellSelectAll,
                  onTap: selectable.isEmpty ? null : () => notifier.setAll(all ? const [] : selectable),
                ),
                const Spacer(),
                DoneButton(onTap: notifier.end),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A text key whose label sits on the 20 line (10 of ink on either side).
class _TextKey extends StatelessWidget {
  const _TextKey({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: onTap == null ? DshColors.of(context).textTertiary : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「完成」: the 36 primary pill in 新对话's place, even padding on both sides.
class DoneButton extends StatelessWidget {
  const DoneButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: l10n.commonDone,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: scheme.primary,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  widthFactor: 1,
                  child: Text(l10n.commonDone, style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the identity bar: four equal keys, icon over label. Off until
/// something is chosen.
class SelectionActionBar extends ConsumerWidget {
  const SelectionActionBar({
    super.key,
    required this.onMove,
    required this.onPin,
    required this.onArchive,
    required this.onDelete,
  });

  final VoidCallback onMove;
  final VoidCallback onPin;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  /// Least key height; the drawer lays the bar over the identity bar, so the
  /// keys fill that height.
  static const keyHeight = 48.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final selected = ref.watch(drawerSelectionProvider) ?? const {};
    final pinned = ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)).toSet();
    final canPin = ref.watch(workspacesProvider.select((s) => s.ready));
    final none = selected.isEmpty;
    final allPinned = !none && selected.every(pinned.contains);
    final busy = ref.watch(sessionDeletionBusyProvider);
    final scope = ref.watch(drawerScopeProvider);
    final deleteReason = sessionDeletionDisabledReason(
      context,
      available: ref.watch(sessionDeletionAvailableProvider),
      busy: busy,
      sessions: scope?.sessions ?? const [],
      ids: selected,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _ActionKey(
              icon: AppIcons.moveToFolder,
              label: l10n.shellMoveToFolder,
              onTap: none || busy ? null : onMove,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionKey(
              icon: allPinned ? AppIcons.pinActive : AppIcons.pin,
              label: allPinned ? l10n.shellUnpin : l10n.commonPin,
              onTap: none || !canPin || busy ? null : onPin,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionKey(icon: AppIcons.archive, label: l10n.shellArchive, onTap: none || busy ? null : onArchive),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: deleteReason ?? l10n.shellDeleteNoUndo,
              child: _ActionKey(
                icon: AppIcons.delete,
                label: busy ? l10n.shellDeletingChats : l10n.commonDelete,
                onTap: none || deleteReason != null || scope?.readOnly != false ? null : onDelete,
                destructive: true,
                busy: busy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionKey extends StatelessWidget {
  const _ActionKey({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = onTap != null;
    final color = destructive ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      enabled: on,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: on ? 1 : 0.38,
        duration: AppMotion.of(context, AppMotion.quick),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: Squircle.border(AppShape.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: SelectionActionBar.keyHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                  else
                    Icon(icon, size: 22, color: color),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(color: color, fontSize: 11, height: 1.2),
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
