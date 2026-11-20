// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/app_sheet.dart';
import '../common/list_page_row.dart' show ListPageRow;
import '../common/overview_card.dart' show OverviewChevron;
import '../common/segmented_pill.dart';

export '../common/segmented_pill.dart' show PillSegment, SegmentedPill;
import '../../l10n/l10n.dart';
import '../theme/theme.dart';
import 'index/spot_anchor.dart';
import 'index/spots.dart';

export 'index/spot_anchor.dart' show SpotAnchor, SpotKey;
export 'index/spots.dart' show SettingSpot, SettingsIndex, SettingsPageId, Spots;

/// Page-level group spacing: groups sit 24 apart,
/// flush with the 16 page gutter.
const kSettingsGroupMargin = EdgeInsets.fromLTRB(16, 0, 16, 24);

/// The measured geometry every settings-style row shares. Change it here and in
/// `test/settings/settings_geometry_test.dart` together.
///
/// ```
/// |16| (32) |12| 标题 / 副标题 …… 值 |4| ›   |16 到字形|
/// |16| (32) |12| 标题 …………………………  [ 开关轨道 ] |16|
/// |16| 标签 ………………………………………………………… 值 |16|
/// ```
abstract final class SettingsMetrics {
  /// Card edge → icon disc / plain label on the left, and → switch track,
  /// chevron ink, segmented pill or a bare value on the right.
  static const inset = 16.0;

  /// Right padding of a row ending in a switch or chevron: the switch's track
  /// sits 4 inside its box, the chevron is nudged out by
  /// [OverviewChevron.nudge] — both end at [inset].
  static const trailingPad = ListPageRow.trailingPad;
  static const icon = 32.0;
  static const iconGlyph = 18.0;

  /// Line icon on secondary pages (no tinted disc), centred in the [icon] slot.
  static const lineGlyph = 20.0;
  static const iconGap = 12.0;

  /// Where titles start in rows with an icon.
  static const textStart = inset + icon + iconGap;
  static const rowHeight = 52.0;
  static const rowHeightTwoLine = 64.0;
}

/// Title style of every settings row (15 / 1.4).
TextStyle? settingsTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4);

/// Round tinted icon for a settings row. [tint] picks one of the 8 fixed identity
/// pairs (pastel container + deep glyph). On hub pages every row of a group uses
/// the group's one tint.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key, this.tint = 0, this.danger = false});

  final IconData icon;
  final int tint;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final bg = danger ? colors.dangerContainer : colors.identity[tint % colors.identity.length];
    final fg = danger ? colors.onDangerContainer : colors.onIdentity[tint % colors.onIdentity.length];
    return DecoratedBox(
      decoration: ShapeDecoration(color: bg, shape: const CircleBorder()),
      child: SizedBox.square(
        dimension: SettingsMetrics.icon,
        child: Icon(icon, size: SettingsMetrics.iconGlyph, color: fg),
      ),
    );
  }
}

/// A 20dp line icon in the secondary colour, centred in the 32dp icon slot:
/// how rows on secondary pages show an icon.
class SettingsLineIcon extends StatelessWidget {
  const SettingsLineIcon(this.icon, {super.key, this.danger = false});

  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return SizedBox.square(
      dimension: SettingsMetrics.icon,
      child: Icon(
        icon,
        size: SettingsMetrics.lineGlyph,
        color: danger ? colors.danger : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// One row: icon · title (+ subtitle) · value · chevron/trailing.
///
/// Single-line rows are 52 tall, rows with a subtitle 64; the whole row is the
/// tap target (a soft highlight, no ripple). A [Switch] passed as [trailing]
/// is drawn without its extra tap padding so switch rows are as tall as the rest.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.icon,
    this.title,
    this.spot,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.tint = 0,
    this.danger = false,
    this.chevron,
    this.tinted = true,
    this.titleMaxLines,
  }) : assert(title != null || spot != null);

  /// Null for a plain row that lines up with [InfoRow]s.
  final IconData? icon;

  /// Defaults to [spot]'s title.
  final String? title;

  /// The row in the settings index: its anchor (key, search landing) and,
  /// unless [title] says otherwise, its title.
  final SettingSpot? spot;
  final String? subtitle;

  /// Current value, right-aligned in the secondary colour.
  final Widget? value;

  /// Replaces the chevron (switches, spinners).
  final Widget? trailing;
  final VoidCallback? onTap;
  final int tint;
  final bool danger;

  /// Defaults to "has onTap and no trailing".
  final bool? chevron;

  /// False draws [icon] as a 20dp line icon ([SettingsLineIcon]) instead of a
  /// tinted disc: the default for rows on secondary pages.
  final bool tinted;

  /// Lines the title may take, cut with an ellipsis; null: as many as it needs.
  final int? titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final showChevron = chevron ?? (onTap != null && trailing == null);
    final endsInGlyph = showChevron || trailing != null;
    final icon = this.icon;
    final title = this.title ?? spot!.title(context.l10n);
    return anchorSpot(
      spot,
      InkWell(
        onTap: onTap,
        splashFactory: rowSplash(context),
        highlightColor: scheme.onSurface.withValues(alpha: 0.05),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: subtitle == null ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightTwoLine,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              SettingsMetrics.inset,
              6,
              endsInGlyph ? SettingsMetrics.trailingPad : SettingsMetrics.inset,
              6,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  tinted ? SettingsIcon(icon, tint: tint, danger: danger) : SettingsLineIcon(icon, danger: danger),
                  const SizedBox(width: SettingsMetrics.iconGap),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: titleMaxLines,
                        overflow: titleMaxLines == null ? null : TextOverflow.ellipsis,
                        style: settingsTitleStyle(context)?.copyWith(color: danger ? colors.danger : scheme.onSurface),
                      ),
                      if (subtitle case final sub?) ...[
                        const SizedBox(height: 1),
                        Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                      ],
                    ],
                  ),
                ),
                if (value case final value?) ...[
                  const SizedBox(width: 12),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    child: value,
                  ),
                ],
                if (trailing case final trailing?) ...[
                  const SizedBox(width: 8),
                  SwitchTheme(
                    data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: trailing,
                  ),
                ],
                if (showChevron) ...[const SizedBox(width: 4), const OverviewChevron()],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row with a switch; the whole row toggles.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.icon,
    this.title,
    this.spot,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.tint = 0,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  final IconData? icon;

  /// Defaults to [spot]'s title.
  final String? title;
  final SettingSpot? spot;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final int tint;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final fluid = AppMotion.fluid(context);
    void change(bool next) {
      if (fluid) HapticFeedback.selectionClick();
      onChanged!(next);
    }

    return MergeSemantics(
      child: SettingsTile(
        icon: icon,
        title: title,
        spot: spot,
        subtitle: subtitle,
        tint: tint,
        tinted: tinted,
        onTap: onChanged == null ? null : () => change(!value),
        trailing: Switch.adaptive(value: value, onChanged: onChanged == null ? null : change),
      ),
    );
  }
}

/// Plain label/value row for read-only facts (about, diagnostics): the label
/// where a plain row's title starts, the value ending 16 from the card edge.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(label, style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: mono
                      ? AppType.monoLabel(color: scheme.onSurfaceVariant).copyWith(height: 1.6)
                      : AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group of rows with a small, faint title above the card and an optional
/// one-line footnote under it (title → card 8, card → footnote 8, groups 24
/// apart). Titles and footnotes start 24 from the
/// screen edge, under the page's large title.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    this.title,
    required this.children,
    this.footer,
    this.margin = kSettingsGroupMargin,
    this.spot,
  });

  final String? title;
  final List<Widget> children;

  /// The card as one place in the settings index (界面's 网页版): its rows
  /// light together, inside the card's rounded edge.
  final SettingSpot? spot;

  /// A short note under the card (secondary colour). Keep it to a sentence.
  final Widget? footer;
  final EdgeInsetsGeometry margin;

  /// Style of section titles, for places that draw one without a card.
  static TextStyle? titleStyle(BuildContext context) => groupTitleStyle(context);

  /// Space between the card and its [footer].
  static const footerGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final title?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(header: true, child: Text(title, style: titleStyle(context))),
            ),
          SheetGroup(
            margin: EdgeInsets.zero,
            children: spot == null
                ? children
                : [
                    // One child keeps SheetGroup's 2dp between rows inside it.
                    SpotAnchor(
                      spot: spot!,
                      child: Column(mainAxisSize: MainAxisSize.min, spacing: 2, children: children),
                    ),
                  ],
          ),
          if (footer case final footer?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, footerGap, 8, 0),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.55),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }
}

/// A title with its value at the right, the slider under it, the track running from the title's
/// edge to the value's (16 from the card on both sides, as a switch track ends). Neutral, like
/// every slider in settings: the page's accent stays with the switches.
///
/// ```
/// |16| 模糊 …………………………………………………… 30% |16|
/// |16| ━━━━━━━━━●──────────────────────── |16|
/// ```
///
/// [value] is 0–1 and lands on [steps] even steps (no tick marks: the track stays one quiet
/// line); [label] reads a value, a percent unless told otherwise. [onChanged] follows the
/// finger, [onChangeEnd] is the value let go on.
class SettingsSliderTile extends StatelessWidget {
  const SettingsSliderTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    this.steps = defaultSteps,
    this.label = percent,
  });

  final String title;

  /// 0–1.
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final int steps;
  final String Function(double value) label;

  /// 5% steps.
  static const defaultSteps = 20;

  /// `0.3` as `30%`.
  static String percent(double v) => '${(v * 100).round()}%';

  double _snap(double v) => (v * steps).round() / steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = value.clamp(0.0, 1.0);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Row(
                children: [
                  Expanded(child: Text(title, style: settingsTitleStyle(context))),
                  const SizedBox(width: 12),
                  Text(label(v), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Semantics(
              label: title,
              child: Slider(
                value: v,
                // No inset for the thumb's halo: the track ends where the text does.
                padding: EdgeInsets.zero,
                activeColor: scheme.onSurfaceVariant,
                inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
                // What the value is, not the step it would land on: a saved 37% reads 37%.
                semanticFormatterCallback: label,
                onChanged: (raw) {
                  final next = _snap(raw);
                  if (next == _snap(v)) return;
                  HapticFeedback.selectionClick();
                  onChanged(next);
                },
                onChangeEnd: (raw) => onChangeEnd(_snap(raw)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置里的分段选择行(主题、字号这类二到四选一):放得下就和标题排一行、
/// 控件靠右;放不下(窄屏、系统大字号)就把控件放到标题下面整行显示,
/// 选项不会被挤成竖排。左右内边距与 [SettingsTile] 相同,胶囊右缘与开关轨道对齐。
class SettingsSegmentTile<T> extends StatelessWidget {
  const SettingsSegmentTile({
    super.key,
    this.icon,
    this.tint = 0,
    this.title,
    this.spot,
    this.subtitle,
    this.subtitleAction,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.onReselect,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  final IconData? icon;
  final int tint;

  /// Defaults to [spot]'s title.
  final String? title;
  final SettingSpot? spot;

  /// A line under the control (so the control stays put when it comes and goes).
  final String? subtitle;

  /// Something to tap right after [subtitle]; on the next line when it doesn't fit.
  final Widget? subtitleAction;
  final List<PillSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;

  /// See [SegmentedPill.onReselect].
  final ValueChanged<T>? onReselect;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final titleStyle = settingsTitleStyle(context);
    final icon = this.icon;
    final title = this.title ?? spot!.title(context.l10n);
    const iconWidth = SettingsMetrics.icon + SettingsMetrics.iconGap;
    return anchorSpot(
      spot,
      Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pillWidth = SegmentedPill.naturalWidth(context, [for (final s in segments) s.label]);
            final titlePainter = TextPainter(
              text: TextSpan(text: title, style: titleStyle),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            final titleWidth = titlePainter.width;
            titlePainter.dispose();
            final lead = icon == null ? 0.0 : iconWidth;
            final inline = lead + titleWidth + 16 + pillWidth <= constraints.maxWidth;
            final heading = [
              if (icon != null) ...[
                tinted ? SettingsIcon(icon, tint: tint) : SettingsLineIcon(icon),
                const SizedBox(width: SettingsMetrics.iconGap),
              ],
            ];
            final pill = SegmentedPill<T>(
              segments: segments,
              selected: selected,
              onChanged: onChanged,
              onReselect: onReselect,
              expand: !inline,
            );
            final note = switch (subtitle) {
              final sub? => Padding(
                padding: EdgeInsets.only(left: lead, top: 6, bottom: 2),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      sub,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                    ),
                    ?subtitleAction,
                  ],
                ),
              ),
              null => null,
            };
            if (inline) {
              final row = ConstrainedBox(
                constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight - 16),
                child: Row(
                  children: [
                    ...heading,
                    Text(title, style: titleStyle),
                    const Spacer(),
                    pill,
                  ],
                ),
              );
              if (note == null) return row;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [row, note]);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: SettingsMetrics.icon),
                  child: Row(
                    children: [
                      ...heading,
                      Expanded(child: Text(title, style: titleStyle)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: EdgeInsets.only(left: lead),
                  child: pill,
                ),
                const SizedBox(height: 4),
                ?note,
              ],
            );
          },
        ),
      ),
    );
  }
}
