// 引用追问 in the composer and in the bubble it becomes. The passage itself
// travels as a Markdown blockquote (`state/composer_quote.dart`).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/composer_quote.dart';
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../secret_mask.dart';

/// 引用片:输入框上方的一行,引号 + 单行省略的引文 + ✕。
///
/// 全圆胶囊。引号和 ✕ 各占一端 [height] 见方的格子、居中,所以四周等距
/// ([glyphInset])、与胶囊两端的半圆同心,左右镜像;字号变大时胶囊跟着
/// 长高,两端仍同心。
class QuoteChip extends StatelessWidget {
  const QuoteChip({super.key, required this.quote, required this.onRemove});

  /// The passage (as quoted; shown on one line).
  final String quote;
  final VoidCallback onRemove;

  /// Height at the default text size.
  static const minHeight = 32.0;

  /// The quote mark and the ✕.
  static const glyph = 16.0;

  /// Glyph to the chip's edge on every side, at the default text size.
  static const glyphInset = (minHeight - glyph) / 2;

  static TextStyle? _style(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.3);

  /// The chip's height at the current text size.
  static double heightOf(BuildContext context) {
    final style = _style(context);
    final line = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14) * (style?.height ?? 1.3);
    return math.max(minHeight, line + 12);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = DshColors.of(context).textTertiary;
    final height = heightOf(context);
    // Display only, like the bubbles: the message sent keeps the original.
    final line = quoteLine(maskSecrets(quote, mark: '•'));
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.chatQuoteSemantics(line),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: colors.onSurface.withValues(alpha: 0.05), shape: const StadiumBorder()),
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: height,
                child: Center(
                  child: ExcludeSemantics(
                    child: Icon(AppIcons.quote, size: glyph, color: muted),
                  ),
                ),
              ),
              Flexible(
                child: ExcludeSemantics(
                  child: Text(
                    line,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: _style(context),
                  ),
                ),
              ),
              Semantics(
                container: true,
                button: true,
                label: l10n.chatRemoveQuote,
                child: GestureDetector(
                  onTap: onRemove,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox.square(
                    dimension: height,
                    child: Center(
                      child: Icon(AppIcons.close, size: glyph, color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What waits above the composer's text, for [Composer.tray]: the quote,
/// then the picked attachments.
///
/// The composer puts its tray 8 below the glass's top and 12 in from each
/// side. The quote chip gets [quoteTop] more on top, so it sits 12 from the
/// top and the sides alike — concentric with the glass's 28 corner (28 − 12
/// = the chip's 16 radius) — and its left edge is the attachment row's.
///
/// While one of the two stays, the other unfolds and folds on its own (the
/// composer unfolds the tray as a whole).
class ComposerTrayStack extends StatefulWidget {
  const ComposerTrayStack({super.key, this.quote, this.attachments});

  final Widget? quote;
  final Widget? attachments;

  /// Extra room above the quote chip (see the class doc).
  static const quoteTop = 4.0;

  /// Between the quote chip and the attachment row. The row's tiles start 8
  /// lower (their ✕ badges overhang), so the badges sit 8 below the chip.
  static const quoteGap = 4.0;

  /// The stack, or null when there is nothing to show (no tray).
  static Widget? maybe({Widget? quote, Widget? attachments}) =>
      quote == null && attachments == null ? null : ComposerTrayStack(quote: quote, attachments: attachments);

  @override
  State<ComposerTrayStack> createState() => _ComposerTrayStackState();
}

class _ComposerTrayStackState extends State<ComposerTrayStack> {
  // The last of each shown: it stays while it folds away.
  late Widget? _quote = widget.quote;
  late Widget? _attachments = widget.attachments;

  @override
  void didUpdateWidget(ComposerTrayStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _quote = widget.quote ?? _quote;
    _attachments = widget.attachments ?? _attachments;
  }

  @override
  Widget build(BuildContext context) {
    final both = widget.quote != null && widget.attachments != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpandReveal(
          open: widget.quote != null,
          child: Padding(
            padding: const EdgeInsets.only(top: ComposerTrayStack.quoteTop),
            child: Align(alignment: Alignment.centerLeft, child: _quote),
          ),
        ),
        AnimatedPadding(
          duration: AppMotion.of(context, AppMotion.collapse),
          curve: AppMotion.collapseCurve,
          padding: EdgeInsets.only(top: both ? ComposerTrayStack.quoteGap : 0),
          child: ExpandReveal(open: widget.attachments != null, child: _attachments ?? const SizedBox.shrink()),
        ),
      ],
    );
  }
}

/// The quote a sent message opens with, at the top of its bubble: a thin
/// bar and up to two quiet lines (secondary text: the only quiet colour that
/// passes AA on the bubble).
class BubbleQuote extends StatelessWidget {
  const BubbleQuote(this.quote, {super.key});

  final String quote;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    // One step under the message text, still on the chat text scale.
    final style = AppType.chatBody(context, scale: 14 / 16, color: theme.colorScheme.onSurfaceVariant);
    return Semantics(
      label: l10n.chatQuoteSemantics(quoteLine(quote)),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: surfaces.onUserBubble.withValues(alpha: 0.25), width: 2)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(quoteLine(quote), maxLines: 2, overflow: TextOverflow.ellipsis, style: style),
        ),
      ),
    );
  }
}
