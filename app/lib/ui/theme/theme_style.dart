// Projects a declarative ThemePack onto Flutter's ThemeData, DshSurfaces,
// DshColors, Typography and per-component visual styles.

import 'package:flutter/material.dart';

import '../../themes/theme_pack.dart';
import 'accent.dart';
import 'palette.dart';
import 'semantic_colors.dart';
import 'shapes.dart';
import 'squircle.dart';
import 'surfaces.dart';
import 'typography.dart';

const List<String> _serifFallback = <String>[
  'Noto Serif CJK SC',
  'Noto Serif SC',
  'Source Han Serif SC',
  'Songti SC',
  'STSong',
  'SimSun',
  'serif',
];

@immutable
class DshThemeStyle extends ThemeExtension<DshThemeStyle> {
  const DshThemeStyle({
    this.pack,
    this.loadedFonts = const {},
    this.assistantBubble,
    this.onAssistantBubble,
  });

  final ThemePack? pack;
  final Map<String, String> loadedFonts;
  final Color? assistantBubble;
  final Color? onAssistantBubble;

  static DshThemeStyle of(BuildContext context) =>
      Theme.of(context).extension<DshThemeStyle>() ?? const DshThemeStyle();

  String? get packId => pack?.id;
  String? get folderPath => pack?.folderPath;
  int get assetRevision => pack?.assetRevision ?? 0;

  ThemeSurfaceSpec get surfaces => pack?.surfaces ?? const ThemeSurfaceSpec();
  ThemeTypographySpec get typography => pack?.typography ?? const ThemeTypographySpec();
  ThemeShapeSpec get shapes => pack?.shapes ?? const ThemeShapeSpec();
  ThemeComponentSpec get components => pack?.components ?? const ThemeComponentSpec();
  ThemeEmptyStateSpec get emptyState => pack?.emptyState ?? const ThemeEmptyStateSpec();

  double get cornerScale => shapes.cornerScale;
  double get borderWidth => shapes.borderWidth;

  double scaleRadius(double base) => (base * shapes.cornerScale).clamp(0.0, 44.0);

  BorderRadius scaledBorderRadius(double base) =>
      BorderRadius.all(Radius.circular(scaleRadius(base)));

  ShapeBorder cardShape([Color? borderColor, double? width]) {
    final r = scaleRadius(AppShape.md);
    if (borderColor == null) {
      return SquircleBorder(borderRadius: BorderRadius.all(Radius.circular(r)));
    }
    return SquircleBorder(
      borderRadius: BorderRadius.all(Radius.circular(r)),
      side: BorderSide(color: borderColor, width: width ?? borderWidth),
    );
  }

  ShapeBorder bubbleShape([Color? borderColor, double? width]) {
    final r = scaleRadius(AppShape.lg);
    if (borderColor == null || (width ?? 0) <= 0) {
      return SquircleBorder(borderRadius: BorderRadius.all(Radius.circular(r)));
    }
    return SquircleBorder(
      borderRadius: BorderRadius.all(Radius.circular(r)),
      side: BorderSide(color: borderColor, width: width!),
    );
  }

  TextStyle applyFontRole(TextStyle base, String role) {
    if (role == 'system') return base;
    if (role == 'serif') {
      return base.copyWith(
        fontFamily: 'serif',
        fontFamilyFallback: _serifFallback,
      );
    }
    if (role == 'mono' || role == 'JetBrainsMono' || role == 'monospace') {
      return base.copyWith(
        fontFamily: AppType.monoFamily,
        fontFeatures: AppType.monoFeatures,
        fontFamilyFallback: AppType.monoFallback,
      );
    }
    final customFamily = loadedFonts[role];
    if (customFamily != null) {
      return base.copyWith(
        fontFamily: customFamily,
        fontFamilyFallback: const ['Noto Sans CJK SC', ..._serifFallback],
      );
    }
    return base;
  }

  TextStyle readingTextStyle(TextStyle base) {
    final spec = typography;
    final withFont = applyFontRole(base, spec.readingFont);
    final baseSize = withFont.fontSize ?? 16.0;
    return withFont.copyWith(
      fontSize: baseSize * spec.readingScale,
      height: spec.readingLineHeight,
    );
  }

  TextStyle headingTextStyle(TextStyle base) {
    final spec = typography;
    final withFont = applyFontRole(base, spec.headingFont);
    final baseSize = withFont.fontSize ?? 28.0;
    return withFont.copyWith(
      fontSize: baseSize * spec.headingScale,
    );
  }

  TextStyle codeTextStyle(TextStyle base) {
    final role = typography.codeFont;
    if (role == 'JetBrainsMono') return base;
    if (role == 'monospace' || role == 'mono') {
      return base.copyWith(fontFamily: 'monospace', fontFamilyFallback: AppType.monoFallback);
    }
    final customFamily = loadedFonts[role];
    if (customFamily != null) {
      return base.copyWith(
        fontFamily: customFamily,
        fontFamilyFallback: const [AppType.monoFamily, ...AppType.monoFallback],
      );
    }
    return base;
  }

  @override
  DshThemeStyle copyWith({
    ThemePack? pack,
    Map<String, String>? loadedFonts,
    Color? assistantBubble,
    Color? onAssistantBubble,
  }) => DshThemeStyle(
    pack: pack ?? this.pack,
    loadedFonts: loadedFonts ?? this.loadedFonts,
    assistantBubble: assistantBubble ?? this.assistantBubble,
    onAssistantBubble: onAssistantBubble ?? this.onAssistantBubble,
  );

  @override
  DshThemeStyle lerp(DshThemeStyle? other, double t) {
    if (other is! DshThemeStyle) return this;
    return DshThemeStyle(
      pack: t < 0.5 ? pack : other.pack,
      loadedFonts: t < 0.5 ? loadedFonts : other.loadedFonts,
      assistantBubble: Color.lerp(assistantBubble, other.assistantBubble, t),
      onAssistantBubble: Color.lerp(onAssistantBubble, other.onAssistantBubble, t),
    );
  }
}

AppAccent accentFromThemePack(ThemePack pack, {String? label}) =>
    AppAccent.fromThemePack(pack, label: label);

ColorScheme applyThemePackScheme(ColorScheme base, ThemePack? pack) {
  if (pack == null) return base;
  final isDark = base.brightness == Brightness.dark;
  final o = isDark ? pack.palette.dark : pack.palette.light;
  if (o.isEmpty) return base;
  return base.copyWith(
    primary: o.primary != null ? Color(o.primary!) : null,
    onPrimary: o.onPrimary != null ? Color(o.onPrimary!) : null,
    primaryContainer: o.primaryContainer != null ? Color(o.primaryContainer!) : null,
    onPrimaryContainer: o.onPrimaryContainer != null ? Color(o.onPrimaryContainer!) : null,
    surface: o.surface != null ? Color(o.surface!) : null,
    onSurface: o.onSurface != null ? Color(o.onSurface!) : null,
    onSurfaceVariant: o.onSurfaceVariant != null ? Color(o.onSurfaceVariant!) : null,
    outline: o.outline != null ? Color(o.outline!) : null,
    outlineVariant: o.outlineVariant != null ? Color(o.outlineVariant!) : null,
  );
}

DshColors applyThemePackColors(DshColors base, ThemePack? pack, Brightness brightness) {
  if (pack == null) return base;
  final isDark = brightness == Brightness.dark;
  final o = isDark ? pack.palette.dark : pack.palette.light;
  if (o.codeWellBg == null &&
      o.codeWellHeader == null &&
      o.codeWellFg == null &&
      o.codeWellBorder == null) {
    return base;
  }
  return base.copyWith(
    codeWellBg: o.codeWellBg != null ? Color(o.codeWellBg!) : null,
    codeWellHeader: o.codeWellHeader != null ? Color(o.codeWellHeader!) : null,
    codeWellFg: o.codeWellFg != null ? Color(o.codeWellFg!) : null,
    codeWellBorder: o.codeWellBorder != null ? Color(o.codeWellBorder!) : null,
  );
}

DshSurfaces applyThemePackSurfaces(
  DshSurfaces base,
  ThemePack? pack,
  Brightness brightness, {
  required bool blurEnabled,
}) {
  if (pack == null) return base;
  final isDark = brightness == Brightness.dark;
  final n = NeutralTones.forAccent(base.accent);
  final o = isDark ? pack.palette.dark : pack.palette.light;
  final s = pack.surfaces;
  final glowMul = pack.palette.glowOpacity.clamp(0.0, 1.0);

  var top = o.backdropTop != null ? Color(o.backdropTop!) : base.backdropTop;
  var bottom = o.backdropBottom != null ? Color(o.backdropBottom!) : base.backdropBottom;
  var chrome = base.chrome;
  var sheet = base.sheet;
  var card = base.card;
  var pill = base.pill;

  switch (s.preset) {
    case ThemeSurfacePreset.glass:
      break;
    case ThemeSurfacePreset.paper:
      if (o.backdropTop == null) top = isDark ? n.night : n.mist;
      if (o.backdropBottom == null) bottom = isDark ? n.night : n.mist;
      final chromeFill = isDark ? n.nightContainer : n.mistLowest;
      final sheetFill = isDark ? n.sheetDark : n.mistLow;
      final rule = isDark ? n.ruleDark : n.ruleLight;
      chrome = GlassStyle(
        fill: chromeFill,
        fallbackFill: chromeFill,
        hairline: rule,
        hairlineWidth: s.hairlineWidth ?? 1.0,
        rim: Colors.transparent,
      );
      sheet = GlassStyle(
        fill: sheetFill,
        fallbackFill: sheetFill,
        hairline: rule,
        hairlineWidth: s.hairlineWidth ?? 1.0,
        rim: Colors.transparent,
      );
      card = card.copyWith(
        hairline: rule,
        hairlineWidth: s.hairlineWidth ?? 1.0,
        rim: Colors.transparent,
        shadows: const [],
      );
      pill = pill.copyWith(
        hairline: rule,
        hairlineWidth: s.hairlineWidth ?? 1.0,
        rim: Colors.transparent,
      );
    case ThemeSurfacePreset.flat:
      final chromeFill = isDark ? n.nightLow : n.mistLowest;
      final sheetFill = isDark ? n.sheetDark : n.mistLow;
      final cardFill = isDark ? n.nightContainer : n.mistLow;
      final rule = isDark ? n.ruleDark : n.ruleLight;
      chrome = GlassStyle(
        fill: chromeFill,
        fallbackFill: chromeFill,
        hairline: rule.withValues(alpha: 0.4),
        hairlineWidth: s.hairlineWidth ?? 0.5,
        rim: Colors.transparent,
      );
      sheet = GlassStyle(
        fill: sheetFill,
        fallbackFill: sheetFill,
        hairline: rule.withValues(alpha: 0.4),
        hairlineWidth: s.hairlineWidth ?? 0.5,
        rim: Colors.transparent,
      );
      card = GlassStyle(
        fill: cardFill,
        fallbackFill: cardFill,
        hairline: rule.withValues(alpha: 0.4),
        hairlineWidth: s.hairlineWidth ?? 0.5,
        rim: Colors.transparent,
      );
      pill = GlassStyle(
        fill: cardFill,
        fallbackFill: cardFill,
        hairline: rule.withValues(alpha: 0.4),
        hairlineWidth: s.hairlineWidth ?? 0.5,
        rim: Colors.transparent,
      );
    case ThemeSurfacePreset.outlined:
      final baseFill = isDark ? n.night : n.mist;
      final rule = isDark ? n.outlineDark.withValues(alpha: 0.55) : n.outlineLight.withValues(alpha: 0.45);
      final hw = s.hairlineWidth ?? 1.0;
      chrome = GlassStyle(
        fill: baseFill.withValues(alpha: 0.94),
        fallbackFill: baseFill,
        hairline: rule,
        hairlineWidth: hw,
        rim: Colors.transparent,
      );
      sheet = GlassStyle(
        fill: (isDark ? n.sheetDark : n.mistLow),
        fallbackFill: (isDark ? n.sheetDark : n.mistLow),
        hairline: rule,
        hairlineWidth: hw,
        rim: Colors.transparent,
      );
      card = GlassStyle(
        fill: baseFill.withValues(alpha: 0.4),
        fallbackFill: baseFill,
        hairline: rule,
        hairlineWidth: hw,
        rim: Colors.transparent,
      );
      pill = GlassStyle(
        fill: baseFill.withValues(alpha: 0.4),
        fallbackFill: baseFill,
        hairline: rule,
        hairlineWidth: hw,
        rim: Colors.transparent,
      );
  }

  GlassStyle tuneTier(
    GlassStyle style, {
    double? blur,
    double? fillOpacity,
  }) {
    var next = style;
    if (blur != null) next = next.copyWith(blurSigma: blur);
    if (fillOpacity != null) {
      next = next.copyWith(fill: next.fill.withValues(alpha: fillOpacity.clamp(0.0, 1.0)));
    }
    if (s.hairlineWidth != null) {
      next = next.copyWith(hairlineWidth: s.hairlineWidth);
    }
    if (s.rimOpacity != null) {
      next = next.copyWith(
        rim: next.rim == Colors.transparent
            ? Colors.transparent
            : next.rim.withValues(alpha: (next.rim.a * s.rimOpacity!).clamp(0.0, 1.0)),
      );
    }
    if (s.shadowOpacity != null) {
      if (s.shadowOpacity! <= 0) {
        next = next.copyWith(shadows: const []);
      } else {
        next = next.copyWith(
          shadows: [
            for (final sh in next.shadows)
              BoxShadow(
                color: sh.color.withValues(alpha: (sh.color.a * s.shadowOpacity!).clamp(0.0, 1.0)),
                blurRadius: sh.blurRadius,
                spreadRadius: sh.spreadRadius,
                offset: sh.offset,
              ),
          ],
        );
      }
    }
    return next;
  }

  chrome = tuneTier(chrome, blur: s.chromeBlur);
  sheet = tuneTier(sheet, blur: s.sheetBlur);
  card = tuneTier(card, fillOpacity: s.cardOpacity);
  pill = tuneTier(pill, fillOpacity: s.pillOpacity);

  final rawGlow1 = o.glowPrimary != null
      ? Color(o.glowPrimary!).withValues(alpha: isDark ? 0.28 : 0.42)
      : base.glowPrimary;
  final rawGlow2 = o.glowSecondary != null
      ? Color(o.glowSecondary!).withValues(alpha: isDark ? 0.24 : 0.38)
      : base.glowSecondary;

  final glow1 = glowMul <= 0
      ? Colors.transparent
      : rawGlow1.withValues(alpha: (rawGlow1.a * glowMul).clamp(0.0, 1.0));
  final glow2 = glowMul <= 0
      ? Colors.transparent
      : rawGlow2.withValues(alpha: (rawGlow2.a * glowMul).clamp(0.0, 1.0));

  return base.copyWith(
    backdropTop: top,
    backdropBottom: bottom,
    glowPrimary: glow1,
    glowSecondary: glow2,
    userBubble: o.userBubble != null ? Color(o.userBubble!) : base.userBubble,
    onUserBubble: o.onUserBubble != null ? Color(o.onUserBubble!) : base.onUserBubble,
    chrome: chrome,
    sheet: sheet,
    card: card,
    pill: pill,
    blurEnabled: blurEnabled,
  );
}

TextTheme applyThemePackTypography(
  TextTheme base,
  ThemePack? pack,
  Map<String, String> loadedFonts,
) {
  if (pack == null) return base;
  final style = DshThemeStyle(pack: pack, loadedFonts: loadedFonts);
  final uiRole = pack.typography.uiFont;
  final headingRole = pack.typography.headingFont;
  TextStyle? mapUi(TextStyle? s) => s == null ? null : style.applyFontRole(s, uiRole);
  TextStyle? mapHeading(TextStyle? s) =>
      s == null ? null : style.applyFontRole(mapUi(s)!, headingRole);

  return base.copyWith(
    displayLarge: mapHeading(base.displayLarge),
    displayMedium: mapHeading(base.displayMedium),
    displaySmall: mapHeading(base.displaySmall),
    headlineLarge: mapHeading(base.headlineLarge),
    headlineMedium: mapHeading(base.headlineMedium),
    headlineSmall: mapHeading(base.headlineSmall),
    titleLarge: mapUi(base.titleLarge),
    titleMedium: mapUi(base.titleMedium),
    titleSmall: mapUi(base.titleSmall),
    bodyLarge: mapUi(base.bodyLarge),
    bodyMedium: mapUi(base.bodyMedium),
    bodySmall: mapUi(base.bodySmall),
    labelLarge: mapUi(base.labelLarge),
    labelMedium: mapUi(base.labelMedium),
    labelSmall: mapUi(base.labelSmall),
  );
}

DshThemeStyle buildDshThemeStyle(
  ThemePack? pack,
  Brightness brightness,
  Map<String, String> loadedFonts,
) {
  if (pack == null) return const DshThemeStyle();
  final o = brightness == Brightness.dark ? pack.palette.dark : pack.palette.light;
  return DshThemeStyle(
    pack: pack,
    loadedFonts: loadedFonts,
    assistantBubble: o.assistantBubble != null ? Color(o.assistantBubble!) : null,
    onAssistantBubble: o.onAssistantBubble != null ? Color(o.onAssistantBubble!) : null,
  );
}
