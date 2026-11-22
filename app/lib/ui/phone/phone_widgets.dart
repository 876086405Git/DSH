import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/list_page_row.dart';
import '../common/expand_reveal.dart';
import '../common/row_marks.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

enum NoteTone { info, warn, danger }

/// Low-frequency settings stay discoverable without crowding the main page.
class PhoneOptionsFold extends StatefulWidget {
  const PhoneOptionsFold({
    super.key,
    required this.title,
    required this.children,
    this.initiallyOpen = false,
    this.card = true,
  });

  final String title;
  final List<Widget> children;
  final bool initiallyOpen;

  /// The header row in a card of its own; false for a fold that ends a card
  /// around it (its row and what it reveals are that card's last rows).
  final bool card;

  @override
  State<PhoneOptionsFold> createState() => _PhoneOptionsFoldState();
}

class _PhoneOptionsFoldState extends State<PhoneOptionsFold> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final header = Semantics(
      expanded: _open,
      child: ListPageRow(
        title: widget.title,
        titleMaxLines: 3,
        trailing: RowExpandArrow(open: _open),
        onTap: () => setState(() => _open = !_open),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.card) ListPageCard(children: [header]) else header,
        ExpandReveal(
          open: _open,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
        ),
      ],
    );
  }
}

/// A tinted callout: why something can't work, or what to know first.
class PhoneNote extends StatelessWidget {
  const PhoneNote({
    super.key,
    required this.text,
    this.title,
    this.tone = NoteTone.info,
    this.icon,
    this.action,
    this.margin = const EdgeInsets.fromLTRB(16, 6, 16, 6),
  });

  final String? title;
  final String text;
  final NoteTone tone;
  final IconData? icon;

  /// Optional button under the text.
  final Widget? action;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final (bg, fg, glyph) = switch (tone) {
      NoteTone.info => (colors.infoContainer, colors.onInfoContainer, AppIcons.info),
      NoteTone.warn => (colors.warningContainer, colors.onWarningContainer, AppIcons.warning),
      NoteTone.danger => (colors.dangerContainer, colors.onDangerContainer, AppIcons.blocked),
    };
    return Padding(
      padding: margin,
      child: Semantics(
        container: true,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: bg,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusMd),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon ?? glyph, size: 20, color: fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title case final title?) ...[
                        Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                        const SizedBox(height: 2),
                      ],
                      Text(text, style: theme.textTheme.bodySmall?.copyWith(color: fg, height: 1.5)),
                      if (action case final action?) ...[const SizedBox(height: 6), action],
                    ],
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

/// Trailing "done" word for a status row: never colour alone, always a word.
/// In a [PhoneStepRow] the leading check already says it, so this stays a
/// quiet word.
class DoneMark extends StatelessWidget {
  const DoneMark({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final theme = Theme.of(context);
    return Text(label ?? l10n.phoneEnabled, style: theme.textTheme.labelMedium?.copyWith(color: colors.success));
  }
}

/// Compact tonal capsule for "fix it" actions at the end of a row.
class FixButton extends StatelessWidget {
  const FixButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonal(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(64, 32),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      shape: const StadiumBorder(),
    ),
    child: Text(label),
  );
}

/// One step of a setup checklist: a check (done) or the step number
/// (to do) in the glyph slot, the title, one line, and the fix at the end.
/// A finished step fades back so what is left stands out.
class PhoneStepRow extends StatelessWidget {
  const PhoneStepRow({
    super.key,
    required this.step,
    required this.done,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  /// 1-based number shown while the step is open.
  final int step;
  final bool done;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    return AnimatedOpacity(
      opacity: done ? 0.55 : 1,
      duration: duration,
      curve: AppMotion.std,
      child: ListPageRow(
        leading: AnimatedSwitcher(
          duration: duration,
          switchInCurve: AppMotion.std,
          switchOutCurve: AppMotion.std,
          child: _StepMark(key: ValueKey(done), step: step, done: done),
        ),
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
        trailing: trailing,
        chevron: onTap != null && trailing == null,
        onTap: onTap,
      ),
    );
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark({super.key, required this.step, required this.done});

  final int step;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    if (done) {
      return Icon(AppIcons.success, size: 22, color: colors.success);
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: CircleBorder(side: BorderSide(color: theme.colorScheme.outline, width: 1.5)),
      ),
      child: SizedBox.square(
        dimension: 22,
        child: Center(
          child: Text(
            '$step',
            style: AppType.tabular(
              theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// Numbered steps inside a card.
class NumberedSteps extends StatelessWidget {
  const NumberedSteps(this.steps, {super.key});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(color: scheme.primaryContainer, shape: const CircleBorder()),
                  child: SizedBox.square(
                    dimension: 22,
                    child: Center(
                      child: Text(
                        '${i + 1}',
                        style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: scheme.onPrimaryContainer)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(step, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Plain bullet lines inside a card (short facts, not steps).
class BulletLines extends StatelessWidget {
  const BulletLines(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(color: muted, shape: const CircleBorder()),
                      child: const SizedBox.square(dimension: 4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(line, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One fact row with a state word: "已安装 Shizuku · 是".
class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.label, required this.done, this.unknown = false});

  final String label;
  final bool done;

  /// The system won't say.
  final bool unknown;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final (icon, color, word) = unknown
        ? (AppIcons.question, colors.textTertiary, l10n.phoneCheckUnknown)
        : done
        ? (AppIcons.success, colors.success, l10n.phoneCheckYes)
        : (AppIcons.pending, colors.textTertiary, l10n.phoneCheckNotYet);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(word, style: theme.textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// Footer line under the last group of a page.
class PageFootnote extends StatelessWidget {
  const PageFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
      ),
    );
  }
}

/// 闲置时不透明度: the row with its percent, the slider under the title (from
/// the title's left edge to the value's right one). Neutral, like every slider
/// in settings: the page's accent stays with the switches.
class OverlayOpacityRow extends StatelessWidget {
  const OverlayOpacityRow({
    super.key,
    required this.percent,
    required this.onChanged,
    this.min = 30,
    this.max = 100,
    this.step = 5,
  });

  final int percent;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final int step;

  static String label(int percent) => '$percent%';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = context.l10n.phoneIdleOpacity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: ListPageRow(icon: AppIcons.overlayOpacity, title: title, value: label(percent)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ListPageRow.horizontal + ListPageRow.glyphSlot + ListPageRow.gap,
            0,
            ListPageRow.horizontal,
            12,
          ),
          // One node: "闲置时不透明度, 70%".
          child: MergeSemantics(
            child: Semantics(
              label: title,
              child: Slider(
                value: percent.clamp(min, max).toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: (max - min) ~/ step,
                padding: EdgeInsets.zero,
                activeColor: scheme.onSurfaceVariant,
                inactiveColor: scheme.onSurface.withValues(alpha: 0.1),
                semanticFormatterCallback: (v) => label(v.round()),
                onChanged: (v) {
                  final next = v.round();
                  if (next == percent) return;
                  HapticFeedback.selectionClick();
                  onChanged(next);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
