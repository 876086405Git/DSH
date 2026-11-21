// 消息里的组件 (docs/design/roleplay-ui.md §5), drawn natively in the list: a
// letter on paper, an item that was given, a clue on a note, a message on the
// story's phone, a check's roll, a quiet line of notice. They take the app's
// look and the story's colours; the whole-page canvas draws them as Web
// Components that a card's CSS can restyle. A mini-game needs that canvas, so
// it only says one is there.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_components.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_arrive.dart';
import 'tavern_ink.dart' show tavernNameColor;

/// [component] as a card in the story.
class TavernComponentView extends StatelessWidget {
  const TavernComponentView({super.key, required this.component});

  final TavernComponent component;

  @override
  Widget build(BuildContext context) => switch (component.kind) {
    TavernComponentKind.letter => _Letter(component),
    TavernComponentKind.item => _Item(component),
    TavernComponentKind.clue => _Clue(component),
    TavernComponentKind.phone => _Phone(component),
    TavernComponentKind.roll => _Roll(component),
    TavernComponentKind.notice => _Line(icon: null, text: component.body),
    TavernComponentKind.game => _Line(icon: AppIcons.play, text: context.l10n.tavernGameHere),
  };
}

/// Text that may be long: [lines] lines, then 展开 / 收起 under it.
class _Folding extends StatefulWidget {
  const _Folding({required this.text, required this.style, this.lines = 4});

  final String text;
  final TextStyle? style;
  final int lines;

  @override
  State<_Folding> createState() => _FoldingState();
}

class _FoldingState extends State<_Folding> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
        maxLines: widget.lines,
      )..layout(maxWidth: box.maxWidth);
      final long = painter.didExceedMaxLines;
      painter.dispose();
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Text(
              widget.text,
              style: widget.style,
              maxLines: _open ? null : widget.lines,
              overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
          ),
          if (long)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('tavern-component-fold'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                  minimumSize: const Size(48, 40),
                ),
                onPressed: () => setState(() => _open = !_open),
                child: Text(
                  _open ? context.l10n.tavernComponentLess : context.l10n.tavernComponentMore,
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// A card's ground: [tint] over the page, a hairline round it.
class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.tint, this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 12)});

  final Widget child;
  final Color? tint;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tint ?? scheme.surfaceContainerLow,
        shape: AppShape.card.copyWith(side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A heading row: [icon], [title], and [trailing] at the end.
class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(trailing!, style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary)),
        ],
      ],
    );
  }
}

/// 信件: on paper, who it is from and when, the words folded past four lines.
class _Letter extends StatelessWidget {
  const _Letter(this.component);

  final TavernComponent component;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final from = component.attribute(const ['from', 'sender', 'author']);
    final paper = Color.alphaBlend(
      const Color(0xFFE8D3A6).withValues(alpha: dark ? 0.10 : 0.28),
      theme.colorScheme.surfaceContainerLow,
    );
    return _Card(
      key: const ValueKey('tavern-component-letter'),
      tint: paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Heading(
            icon: AppIcons.mail,
            title: from == null ? context.l10n.tavernLetter : context.l10n.tavernLetterFrom(from),
            trailing: component.attribute(const ['date', 'time']),
          ),
          const SizedBox(height: 10),
          _Folding(text: component.body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.75)),
        ],
      ),
    );
  }
}

/// 物品: what it is and a line about it; one that was handed over (`take`)
/// says 获得 and arrives with a little rise.
class _Item extends StatelessWidget {
  const _Item(this.component);

  final TavernComponent component;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final scheme = theme.colorScheme;
    final name = component.attribute(const ['name', 'title']) ?? component.body;
    final about = component.attribute(const ['name', 'title']) == null ? '' : component.body;
    final taken = component.has('take') || component.has('taken');
    final card = _Card(
      key: const ValueKey('tavern-component-item'),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), borderRadius: AppShape.radiusSm),
            child: Icon(AppIcons.badgeEarned, size: 20, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (taken) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: dsh.successContainer, borderRadius: AppShape.radiusXs),
                        child: Text(
                          context.l10n.tavernItemTaken,
                          style: theme.textTheme.labelSmall?.copyWith(color: dsh.onSuccessContainer),
                        ),
                      ),
                    ],
                  ],
                ),
                if (about.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _Folding(
                    text: about,
                    lines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return taken ? TavernArrive(child: card) : card;
  }
}

/// 线索: a note pinned to the page, a little askew.
class _Clue extends StatelessWidget {
  const _Clue(this.component);

  final TavernComponent component;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final note = Color.alphaBlend(
      const Color(0xFFF5D76E).withValues(alpha: dark ? 0.12 : 0.30),
      theme.colorScheme.surfaceContainerLow,
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Transform.rotate(
        angle: -0.012,
        child: _Card(
          key: const ValueKey('tavern-component-clue'),
          tint: note,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Heading(
                icon: AppIcons.pin,
                title: component.attribute(const ['title', 'name']) ?? context.l10n.tavernClue,
              ),
              if (component.body.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Folding(text: component.body, lines: 3, style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 剧中手机消息: who sent it, when, and the words in a bubble.
class _Phone extends StatelessWidget {
  const _Phone(this.component);

  final TavernComponent component;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final from = component.attribute(const ['from', 'sender', 'name']);
    final color = from == null ? scheme.primary : tavernNameColor(context, from, lead: '');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _Card(
        key: const ValueKey('tavern-component-phone'),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: color.withValues(alpha: 0.18),
                  child: Text(
                    from == null ? '·' : String.fromCharCode(from.runes.first),
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    from == null ? context.l10n.tavernPhoneMessage : context.l10n.tavernPhoneFrom(from),
                    style: theme.textTheme.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (component.attribute(const ['time', 'date']) case final time?)
                  Text(time, style: theme.textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(AppShape.md),
                  bottomLeft: Radius.circular(AppShape.md),
                  bottomRight: Radius.circular(AppShape.md),
                ),
              ),
              child: Text(component.body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 掷骰: the check, the roll against what it needed, and how it went.
class _Roll extends StatelessWidget {
  const _Roll(this.component);

  final TavernComponent component;

  /// success / failure from what the tag says, or null to show it as written.
  static bool? _went(String? result) => switch (result?.toLowerCase()) {
    null => null,
    'success' || 'pass' || 'passed' || 'succeeded' || '成功' || '大成功' || '通过' => true,
    'fail' || 'failure' || 'failed' || '失败' || '大失败' => false,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final l10n = context.l10n;
    final skill = component.attribute(const ['skill', 'check', 'name', 'title']);
    final value = component.attribute(const ['value', 'roll', 'result-value', 'score']);
    final target = component.attribute(const ['target', 'dc', 'difficulty', 'against']);
    final result = component.attribute(const ['result', 'outcome']);
    final went = _went(result);
    final label = went == null ? result : (went ? l10n.tavernRollSuccess : l10n.tavernRollFailure);
    final color = went == null ? null : (went ? dsh.success : dsh.danger);
    final score = [?value, ?target].join(' / ');
    return _Card(
      key: const ValueKey('tavern-component-roll'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.goal, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  skill == null ? l10n.tavernRoll : l10n.tavernRollCheck(skill),
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (score.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  score,
                  style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
              if (label != null) ...[
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
          if (component.body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(component.body, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
          ],
        ],
      ),
    );
  }
}

/// 提示 and the like: one quiet line, centred.
class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5);
    return Center(
      key: const ValueKey('tavern-component-line'),
      child: Text.rich(
        TextSpan(
          children: [
            if (icon != null) ...[
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(icon, size: 14, color: dsh.textTertiary),
              ),
              const TextSpan(text: ' '),
            ],
            TextSpan(text: text),
          ],
        ),
        style: style,
        textAlign: TextAlign.center,
      ),
    );
  }
}
