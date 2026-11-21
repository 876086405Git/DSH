// The star prompt's dialog (docs/design/star-prompt.md §3): the whale girl
// holding out her star, how long she has kept the person company, why a star
// helps, then 「去 GitHub 点 Star」 and, quieter under it, 「已经点过啦」 and
// 「下次再说」. Back or a tap outside is 「下次再说」.
//
// ```
// ╭──────────────────────────────────╮
// │            ( 鲸娘 )              │  192 at most, a soft glow of the palette behind
// │  本鱼已经在 DSH Go 里陪你半个小时啦~ │  titleLarge · centred
// │   这是一个免费开源的项目，如果它……   │  bodyMedium · onSurfaceVariant
// │      拜托你啦~ 这真的很重要！！      │  bodyMedium w600 · primary
// │ ┌──────────────────────────────┐ │
// │ │      ☆ 去 GitHub 点 Star      │ │  filled, full width
// │ └──────────────────────────────┘ │
// │            已经点过啦             │  text · primary
// │             下次再说              │  text · tertiary
// ╰──────────────────────────────────╯
// ```

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/star_prompt.dart';
import '../common/app_dialog.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// What the dialog was left with (null: back, or a tap outside).
enum StarPromptChoice {
  /// 「去 GitHub 点 Star」.
  star,

  /// 「已经点过啦」.
  done,

  /// 「下次再说」.
  later,
}

/// Shows the dialog, telling [hours] whole hours of use (0: half an hour) in
/// the words of the [ask]th ask (0: the first), and acts on the answer: the
/// star opens GitHub, it and 「已经点过啦」 end the prompt for good; anything
/// else waits (the record already says it came up).
Future<StarPromptChoice?> showStarPrompt(BuildContext context, {required int hours, int ask = 0}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showAppDialog<StarPromptChoice>(
    context: context,
    builder: (_) => StarPromptDialog(hours: hours, ask: ask),
  );
  switch (choice) {
    case StarPromptChoice.star:
      await openStarProject(container, messenger);
    case StarPromptChoice.done:
      await container.read(starPromptProvider.notifier).finish();
    case StarPromptChoice.later || null:
      break;
  }
  return choice;
}

/// Opens the project's page in the browser and ends the prompt (going there
/// is answer enough). With no browser, the address goes to the clipboard.
Future<void> openStarProject(ProviderContainer container, ScaffoldMessengerState? messenger) async {
  unawaited(container.read(starPromptProvider.notifier).finish());
  final page = starProjectPage;
  if (await container.read(starLinkOpenerProvider)(page)) return;
  try {
    await Clipboard.setData(ClipboardData(text: page.toString()));
  } catch (_) {
    // No clipboard either: the message still says where to go.
  }
  messenger?.showSnackBar(SnackBar(content: Text(appL10n.shellBrowserUrlCopied)));
}

/// The dialog; pops a [StarPromptChoice].
class StarPromptDialog extends StatelessWidget {
  const StarPromptDialog({super.key, required this.hours, this.ask = 0});

  /// Whole hours of use (0: half an hour).
  final int hours;

  /// Which ask this is (0: the first; [StarPromptRules.asks]): its words.
  final int ask;

  /// The ask's two lines under the title: why, and the plea. Past the last,
  /// the last's.
  static (String body, String plea) words(L10n l10n, int ask) => switch (ask) {
    <= 0 => (l10n.starPromptBody, l10n.starPromptPlea),
    1 => (l10n.starPromptBody2, l10n.starPromptPlea2),
    2 => (l10n.starPromptBody3, l10n.starPromptPlea3),
    3 => (l10n.starPromptBody4, l10n.starPromptPlea4),
    _ => (l10n.starPromptBody5, l10n.starPromptPlea5),
  };

  /// The picture: 576 px, the 192 dp it is drawn at most, at 3×.
  static const asset = 'assets/star/star_whale.webp';

  /// The picture's side: 30 % of the height the dialog may take, within these.
  static const pictureMax = 192.0;
  static const pictureMin = 112.0;

  /// The card's width at most (a tablet keeps a phone's dialog).
  static const maxWidth = 360.0;

  /// From the card's edges to the words and the keys.
  static const gutter = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final l10n = context.l10n;
    final scale = MediaQuery.textScalerOf(context);
    final (body, plea) = words(l10n, ask);
    const quietSize = Size.fromHeight(44);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: maxWidth),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = (constraints.maxHeight * 0.3).clamp(pictureMin, pictureMax);
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(gutter, 20, gutter, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: StarPicture(side: side)),
                const SizedBox(height: 14),
                Semantics(
                  header: true,
                  child: BalancedText(
                    l10n.starPromptTitle(hours),
                    key: const ValueKey('star-title'),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  key: const ValueKey('star-body'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Text(
                  plea,
                  key: const ValueKey('star-plea'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  key: const ValueKey('star-go'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  onPressed: () => Navigator.pop(context, StarPromptChoice.star),
                  icon: Icon(AppIcons.starProject, size: scale.scale(18)),
                  label: Text(l10n.starPromptStar, textAlign: TextAlign.center),
                ),
                const SizedBox(height: 6),
                TextButton(
                  key: const ValueKey('star-done'),
                  style: TextButton.styleFrom(minimumSize: quietSize),
                  onPressed: () => Navigator.pop(context, StarPromptChoice.done),
                  child: Text(l10n.starPromptDone, textAlign: TextAlign.center),
                ),
                TextButton(
                  key: const ValueKey('star-later'),
                  style: TextButton.styleFrom(
                    minimumSize: quietSize,
                    foregroundColor: colors.textTertiary,
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  onPressed: () => Navigator.pop(context, StarPromptChoice.later),
                  child: Text(l10n.starPromptLater, textAlign: TextAlign.center),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// [text] centred, its lines as even as the width allows (CSS's `text-wrap:
/// balance`): laid out in the narrowest width that keeps its number of lines,
/// so a title never leaves 「啦~」 alone on its second line.
class BalancedText extends StatelessWidget {
  const BalancedText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
          textAlign: TextAlign.center,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
        );
        int lines(double width) {
          painter.layout(maxWidth: width);
          return painter.computeLineMetrics().length;
        }

        var width = constraints.maxWidth;
        final count = lines(width);
        if (count > 1) {
          // Narrower than this would take more lines; search within a pixel.
          var low = width / count;
          while (width - low > 1) {
            final mid = (low + width) / 2;
            if (lines(mid) > count) {
              low = mid;
            } else {
              width = mid;
            }
          }
        }
        painter.dispose();
        return Center(
          child: SizedBox(
            width: width,
            child: Text(text, textAlign: TextAlign.center, style: style),
          ),
        );
      },
    );
  }
}

/// The whale girl and her star on a soft glow of the palette, [side] square,
/// never cropped. She rises in with a little bob; with animations off she is
/// simply there.
class StarPicture extends StatelessWidget {
  const StarPicture({super.key, required this.side});

  final double side;

  /// The bob's length.
  static const entrance = Duration(milliseconds: 560);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glow = scheme.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.12);
    final picture = SizedBox.square(
      key: const ValueKey('star-picture'),
      dimension: side,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [glow, glow.withValues(alpha: 0)], stops: const [0.3, 1]),
            ),
          ),
          Image.asset(StarPromptDialog.asset, fit: BoxFit.contain, excludeFromSemantics: true),
        ],
      ),
    );
    if (AppMotion.reduced(context)) return picture;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: entrance,
      builder: (context, t, child) {
        // A little past full size and back (the bob); visible in the first 40 %.
        final rise = Curves.easeOutBack.transform(t);
        return Opacity(
          opacity: Curves.easeOut.transform((t / 0.4).clamp(0.0, 1.0)),
          child: Transform.translate(
            offset: Offset(0, (1 - rise) * 14),
            child: Transform.scale(scale: 0.86 + 0.14 * rise, child: child),
          ),
        );
      },
      child: picture,
    );
  }
}
