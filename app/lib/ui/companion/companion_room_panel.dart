// The room's own panel (the ⋯ key in 伙伴小屋): who she is and how close you
// are at the top, the four places people go most as tiles, then the rest in
// named groups. Drawn on the room's water glass (companionWaterSurfaces).

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/pressable.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/ink_glow.dart';
import '../theme/motion.dart';
import '../theme/semantic_colors.dart';
import '../theme/surfaces.dart';

/// The pearl pink of how close you are, shared with her other bond marks.
const _pearl = Color(0xFFFF9DB5);

/// The panel's first lines: her name, then how close you are and how she talks.
class CompanionPanelHeader extends StatelessWidget {
  const CompanionPanelHeader({
    super.key,
    required this.name,
    required this.mode,
    this.bondTitle,
    this.bondLabel,
    this.bondStep = 0,
    this.bondSteps = 6,
  });

  final String name;

  /// How she talks: 轻量 or 完整.
  final String mode;

  /// 「你们的关系」 and the tier's name; both null while she has no bond yet.
  final String? bondTitle;
  final String? bondLabel;
  final int bondStep;
  final int bondSteps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final caption = theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter + 4, 4, kSheetGutter + 4, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
                  ),
                ),
                const SizedBox(height: 6),
                Text(mode, style: caption),
              ],
            ),
          ),
          if (bondLabel case final label?)
            Semantics(
              label: '${bondTitle ?? ''} $label',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (bondTitle case final title?) Text(title, style: caption),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        for (var i = 0; i < bondSteps; i++)
                          Padding(
                            padding: const EdgeInsets.only(left: 3),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i <= bondStep ? _pearl : colors.textTertiary.withValues(alpha: 0.28),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One page of the 伙伴小屋 section, as its bar shows it.
typedef CompanionSectionItem = ({IconData icon, String label});

/// The section's bar: a pill of water glass floating over the bottom edge, one
/// key per page; the page showing sits in a soft light of its own.
class CompanionSectionNav extends StatelessWidget {
  const CompanionSectionNav({super.key, required this.items, required this.selected, required this.onSelect});

  /// How tall the bar is; pages keep this much clear above the bottom edge.
  static const height = 60.0;

  final List<CompanionSectionItem> items;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    const lit = Color(0xFFCDEBFA);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassSurface(
          tier: GlassTier.chrome,
          stadium: true,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  for (final (index, item) in items.indexed)
                    Expanded(
                      child: Semantics(
                        selected: index == selected,
                        button: true,
                        label: item.label,
                        onTap: () => onSelect(index),
                        excludeSemantics: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSelect(index),
                          child: AnimatedContainer(
                            duration: AppMotion.of(context, AppMotion.standard),
                            curve: AppMotion.std,
                            decoration: ShapeDecoration(
                              shape: const StadiumBorder(),
                              color: index == selected ? const Color(0x1FCDEBFA) : const Color(0x00CDEBFA),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(item.icon, size: 20, color: index == selected ? lit : colors.textTertiary),
                                const SizedBox(height: 3),
                                Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: index == selected ? lit : colors.textTertiary,
                                    fontWeight: index == selected ? FontWeight.w600 : FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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

/// One of the panel's shortcut tiles.
typedef CompanionPanelTile = ({IconData icon, String label, VoidCallback onTap});

/// The places people go most, side by side: what she remembers, what you asked
/// her to do, what you talked about, her voice.
class CompanionPanelTiles extends StatelessWidget {
  const CompanionPanelTiles({super.key, required this.tiles});

  final List<CompanionPanelTile> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 10),
      child: Row(
        children: [
          for (final (index, tile) in tiles.indexed) ...[
            if (index > 0) const SizedBox(width: 8),
            Expanded(
              child: Pressable(
                onTap: tile.onTap,
                semanticLabel: tile.label,
                child: GlassSurface(
                  tier: GlassTier.card,
                  borderRadius: BorderRadius.circular(18),
                  padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
                  child: Column(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(color: Color(0x269FD8F2), shape: BoxShape.circle),
                        child: Icon(tile.icon, size: 20, color: const Color(0xFFBFE6F7)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tile.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A roster cover as its row decodes it. The one in the room keeps the same
/// path when another moves in, so her page drops it before a new roster shows.
ImageProvider companionRosterCover(File file) => ResizeImage(FileImage(file), width: 96);

/// One of the companions on this phone, in her page's 伙伴 group: her cover
/// (or her initial), her name, a check on the one in the room. A tap brings
/// her in; [onMore] holds what else can be done with her.
class CompanionRosterRow extends StatelessWidget {
  const CompanionRosterRow({
    super.key,
    required this.name,
    required this.active,
    this.cover,
    this.subtitle,
    this.onTap,
    this.onMore,
  });

  final String name;
  final bool active;
  final File? cover;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final initial = name.characters.firstOrNull ?? '';
    return InkWell(
      onTap: active ? null : onTap,
      onLongPress: onMore,
      splashFactory: rowSplash(context),
      highlightColor: scheme.onSurface.withValues(alpha: 0.05),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: subtitle == null ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightTwoLine,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 6, SettingsMetrics.trailingPad, 6),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox.square(
                  dimension: SettingsMetrics.icon,
                  child: switch (cover) {
                    final file? => Image(
                      image: companionRosterCover(file),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _Initial(initial),
                    ),
                    null => _Initial(initial),
                  },
                ),
              ),
              const SizedBox(width: SettingsMetrics.iconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface),
                    ),
                    if (subtitle case final sub?) ...[
                      const SizedBox(height: 1),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (active) ...[const SizedBox(width: 8), Icon(AppIcons.selected, size: 20, color: scheme.primary)],
              if (onMore case final more?)
                IconButton(
                  tooltip: context.l10n.companionMenu,
                  icon: Icon(AppIcons.more, size: 20, color: scheme.onSurfaceVariant),
                  onPressed: more,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial(this.letter);

  final String letter;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0x269FD8F2),
    child: Center(
      child: Text(letter, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
  );
}
