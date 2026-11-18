// How the story reads (酒馆设置 › 阅读): its text size, line spacing and
// colours, laid over the app's theme for the transcript only; the composer,
// menus and sheets keep the app's look.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_st_theme.dart';
import '../chat/render/markdown_body.dart';
import 'tavern_ink.dart';

/// [theme] with the story's body text at [size] and [height], in [font]
/// (a card's) when there is one. The same object for the same inputs: text
/// caches keyed on the theme keep hitting.
ThemeData tavernReadingTheme(ThemeData theme, {required double size, required double height, String? font}) {
  final byTheme = _readingThemes[theme] ??= {};
  return byTheme[(size, height, font)] ??= theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      bodyLarge: theme.textTheme.bodyLarge?.copyWith(fontSize: size, height: height, fontFamily: font),
    ),
  );
}

final _readingThemes = Expando<Map<(double, double, String?), ThemeData>>('tavernReading');

/// [theme] with a card's [accent] as its primary colour; the same object for
/// the same inputs, like [tavernReadingTheme].
ThemeData tavernAccentTheme(ThemeData theme, Color accent) {
  final byTheme = _accentThemes[theme] ??= {};
  return byTheme[accent] ??= theme.copyWith(colorScheme: theme.colorScheme.copyWith(primary: accent));
}

final _accentThemes = Expando<Map<Color, ThemeData>>('tavernAccent');

/// The patterns a coloured story is drawn with: one list, so the text's parse
/// cache keeps hitting.
final _inkPatterns = [tavernInkPattern];

/// [child] (the transcript) under the reading settings, and under a card's
/// own [accent], [names] colours and fonts when it has them.
class TavernReading extends ConsumerWidget {
  const TavernReading({
    super.key,
    required this.child,
    this.accent,
    this.names = const {},
    this.bodyFont,
    this.nameFont,
  });

  final Widget child;
  final Color? accent;
  final Map<String, Color> names;

  /// Font families (loaded from the card) for the text and the names.
  final String? bodyFont;
  final String? nameFont;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (size, height, palette) = ref.watch(
      tavernSettingsProvider.select((s) => (s.textSize, s.lineHeight, s.palette)),
    );
    final st = palette == TavernPalette.st ? ref.watch(tavernStThemeProvider) : null;
    final accent = this.accent;
    final theme = accent == null ? Theme.of(context) : tavernAccentTheme(Theme.of(context), accent);
    final ink = st == null ? TavernInk.of(palette, theme.brightness) : TavernInk.st(st, theme.colorScheme.surface);
    final read = Theme(
      data: tavernReadingTheme(theme, size: size, height: height, font: bodyFont),
      // Always there: a story that changed shape would be built afresh.
      child: TavernNameColors(names: names, font: nameFont, child: child),
    );
    return TavernInkScope(
      ink: ink,
      child: MarkdownPatterns(
        patterns: _inkPatterns,
        // Drawn afresh in other colours: the text keeps the spans it made.
        child: KeyedSubtree(key: ValueKey((palette, st, theme.brightness, accent)), child: read),
      ),
    );
  }
}
