// Projects a declarative ThemePack onto Flutter's ThemeData, DshSurfaces,
// DshColors, Typography and per-component visual styles.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../themes/theme_pack.dart';
import 'accent.dart';
import 'highlight_theme.dart';
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
    this.link,
    this.heading,
    this.rule,
    this.userBubbleBorder,
    this.assistantBorder,
    this.composerFill,
    this.composerBorder,
    this.sendButton,
    this.onSendButton,
    this.inlineCodeBg,
    this.inlineCodeFg,
    this.syntax,
  });

  final ThemePack? pack;
  final Map<String, String> loadedFonts;
  final Color? assistantBubble;
  final Color? onAssistantBubble;

  /// Component tokens for the current brightness; null keeps the component's own colour.
  final Color? link;
  final Color? heading;
  final Color? rule;
  final Color? userBubbleBorder;
  final Color? assistantBorder;
  final Color? composerFill;
  final Color? composerBorder;
  final Color? sendButton;
  final Color? onSendButton;
  final Color? inlineCodeBg;
  final Color? inlineCodeFg;

  /// The pack's code highlighting colours; null when it sets none of them.
  final ThemeSyntaxColors? syntax;

  static DshThemeStyle of(BuildContext context) =>
      Theme.of(context).extension<DshThemeStyle>() ?? const DshThemeStyle();

  String? get packId => pack?.id;
  String? get folderPath => pack?.folderPath;
  int get assetRevision => pack?.assetRevision ?? 0;

  /// The pack's own copy in the app's language.
  String? localized(ThemeLocalizedText? text) => text?.resolve(AppLocale.isEnglish ? 'en' : 'zh');

  /// A bundled image, or null for a built-in pack (it has no folder).
  File? assetFile(String? name) {
    final folder = folderPath;
    return folder == null || name == null ? null : File('$folder/$name');
  }

  /// Changes with the file's content, so a replaced same-name image reloads.
  Key assetKey(String name) => ValueKey('$folderPath/$name#$assetRevision');

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

  /// Per-component radii: the pack's absolute value, else the scaled step.
  double get bubbleRadius => shapes.bubbleRadius ?? scaleRadius(AppShape.lg);
  double get cardRadius => shapes.cardRadius ?? scaleRadius(AppShape.md);
  double get codeRadius => shapes.codeRadius ?? scaleRadius(AppShape.md);
  double get composerRadius => shapes.composerRadius ?? scaleRadius(AppShape.xl);

  /// A cut of half the radius reads as a chamfer; a full-radius cut turns
  /// small boxes into diamonds.
  static Radius _cut(Radius r) => Radius.circular((r.x * 0.5).clamp(0.0, 10.0));

  /// The pack's corner style for a box with these radii.
  OutlinedBorder shapeFor(BorderRadius radius, [BorderSide side = BorderSide.none]) => switch (shapes.cornerStyle) {
    ThemeCornerStyle.squircle => SquircleBorder(borderRadius: radius, side: side),
    ThemeCornerStyle.round => RoundedRectangleBorder(borderRadius: radius, side: side),
    ThemeCornerStyle.bevel => BeveledRectangleBorder(
      borderRadius: BorderRadius.only(
        topLeft: _cut(radius.topLeft),
        topRight: _cut(radius.topRight),
        bottomLeft: _cut(radius.bottomLeft),
        bottomRight: _cut(radius.bottomRight),
      ),
      side: side,
    ),
  };

  /// Clips [child] to [shapeFor] of [radius].
  Widget clipFor(double radius, Widget child) => switch (shapes.cornerStyle) {
    ThemeCornerStyle.squircle => Squircle.clip(radius: radius, child: child),
    ThemeCornerStyle.round => ClipRRect(borderRadius: BorderRadius.all(Radius.circular(radius)), child: child),
    ThemeCornerStyle.bevel => ClipPath(
      clipper: ShapeBorderClipper(shape: shapeFor(BorderRadius.all(Radius.circular(radius)))),
      child: child,
    ),
  };

  ShapeBorder cardShape([Color? borderColor, double? width]) => shapeFor(
    BorderRadius.all(Radius.circular(cardRadius)),
    borderColor == null ? BorderSide.none : BorderSide(color: borderColor, width: width ?? borderWidth),
  );

  /// The user bubble's four corners.
  BorderRadius get bubbleBorderRadius {
    final r = Radius.circular(bubbleRadius);
    return switch (shapes.bubbleCorners) {
      ThemeBubbleCorners.uniform => BorderRadius.all(r),
      ThemeBubbleCorners.tail => BorderRadius.only(
        topLeft: r,
        topRight: r,
        bottomLeft: r,
        bottomRight: const Radius.circular(4),
      ),
      ThemeBubbleCorners.leaf => BorderRadius.only(
        topLeft: r,
        bottomRight: r,
        topRight: const Radius.circular(6),
        bottomLeft: const Radius.circular(6),
      ),
    };
  }

  ShapeBorder bubbleShape([Color? borderColor, double? width]) => shapeFor(
    bubbleBorderRadius,
    borderColor == null || (width ?? 0) <= 0 ? BorderSide.none : BorderSide(color: borderColor, width: width!),
  );

  /// The chat header's keys and capsules; null is the theme's own chrome glass.
  GlassStyle? headerGlass(ColorScheme colors) => switch (components.headerStyle) {
    ThemeHeaderStyle.glass => null,
    ThemeHeaderStyle.ghost => const GlassStyle(
      fill: Colors.transparent,
      fallbackFill: Colors.transparent,
      hairline: Colors.transparent,
      rim: Colors.transparent,
    ),
    ThemeHeaderStyle.outlined => GlassStyle(
      fill: Colors.transparent,
      fallbackFill: Colors.transparent,
      hairline: colors.outlineVariant,
      hairlineWidth: 1.0,
      rim: Colors.transparent,
    ),
    ThemeHeaderStyle.minimal => GlassStyle(
      fill: colors.surfaceContainerLow.withValues(alpha: 0.72),
      fallbackFill: colors.surfaceContainerLow,
      hairline: Colors.transparent,
      rim: Colors.transparent,
    ),
  };

  /// The composer's keys (send, attach); null is the default circle.
  OutlinedBorder? get keyShape => switch (components.sendButtonShape) {
    ThemeSendButtonShape.circle => null,
    ThemeSendButtonShape.squircle => const SquircleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
    ThemeSendButtonShape.square => const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
  };

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
      letterSpacing: spec.readingLetterSpacing == 0 ? null : spec.readingLetterSpacing,
    );
  }

  /// The heading role's weight and tracking; unset fields keep [base]'s.
  TextStyle _headingTraits(TextStyle base) {
    final spec = typography;
    final weight = spec.headingWeight;
    if (weight == null && spec.headingLetterSpacing == 0) return base;
    return base.copyWith(
      fontWeight: weight == null ? null : FontWeight.values[weight ~/ 100 - 1],
      letterSpacing: spec.headingLetterSpacing == 0 ? null : spec.headingLetterSpacing,
    );
  }

  TextStyle headingTextStyle(TextStyle base) {
    final spec = typography;
    final withFont = applyFontRole(base, spec.headingFont);
    final baseSize = withFont.fontSize ?? 28.0;
    return _headingTraits(withFont.copyWith(fontSize: baseSize * spec.headingScale));
  }

  /// The chat header's title in the role the pack picked for it.
  TextStyle headerTitleTextStyle(TextStyle base) => switch (components.headerTitleFont) {
    ThemeHeaderTitleFont.ui => base,
    ThemeHeaderTitleFont.heading => applyFontRole(base, typography.headingFont),
    ThemeHeaderTitleFont.code => codeTextStyle(applyFontRole(base, 'mono'), scale: false),
  };

  TextStyle codeTextStyle(TextStyle input, {bool scale = true}) {
    final codeScale = typography.codeScale;
    final base = scale && codeScale != 1.0 ? input.copyWith(fontSize: (input.fontSize ?? 13.0) * codeScale) : input;
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
    Color? link,
    Color? heading,
    Color? rule,
    Color? userBubbleBorder,
    Color? assistantBorder,
    Color? composerFill,
    Color? composerBorder,
    Color? sendButton,
    Color? onSendButton,
    Color? inlineCodeBg,
    Color? inlineCodeFg,
    ThemeSyntaxColors? syntax,
  }) => DshThemeStyle(
    pack: pack ?? this.pack,
    loadedFonts: loadedFonts ?? this.loadedFonts,
    assistantBubble: assistantBubble ?? this.assistantBubble,
    onAssistantBubble: onAssistantBubble ?? this.onAssistantBubble,
    link: link ?? this.link,
    heading: heading ?? this.heading,
    rule: rule ?? this.rule,
    userBubbleBorder: userBubbleBorder ?? this.userBubbleBorder,
    assistantBorder: assistantBorder ?? this.assistantBorder,
    composerFill: composerFill ?? this.composerFill,
    composerBorder: composerBorder ?? this.composerBorder,
    sendButton: sendButton ?? this.sendButton,
    onSendButton: onSendButton ?? this.onSendButton,
    inlineCodeBg: inlineCodeBg ?? this.inlineCodeBg,
    inlineCodeFg: inlineCodeFg ?? this.inlineCodeFg,
    syntax: syntax ?? this.syntax,
  );

  @override
  DshThemeStyle lerp(DshThemeStyle? other, double t) {
    if (other is! DshThemeStyle) return this;
    // An unset colour means "the component's own default", not transparent: with one end unset
    // it switches with the pack instead of fading through see-through.
    Color? blend(Color? a, Color? b) => a == null || b == null ? (t < 0.5 ? a : b) : Color.lerp(a, b, t);
    return DshThemeStyle(
      pack: t < 0.5 ? pack : other.pack,
      loadedFonts: t < 0.5 ? loadedFonts : other.loadedFonts,
      assistantBubble: blend(assistantBubble, other.assistantBubble),
      onAssistantBubble: blend(onAssistantBubble, other.onAssistantBubble),
      link: blend(link, other.link),
      heading: blend(heading, other.heading),
      rule: blend(rule, other.rule),
      userBubbleBorder: blend(userBubbleBorder, other.userBubbleBorder),
      assistantBorder: blend(assistantBorder, other.assistantBorder),
      composerFill: blend(composerFill, other.composerFill),
      composerBorder: blend(composerBorder, other.composerBorder),
      sendButton: blend(sendButton, other.sendButton),
      onSendButton: blend(onSendButton, other.onSendButton),
      inlineCodeBg: blend(inlineCodeBg, other.inlineCodeBg),
      inlineCodeFg: blend(inlineCodeFg, other.inlineCodeFg),
      // Switched, not blended: every in-between value would highlight all the code on screen again.
      syntax: t < 0.5 ? syntax : other.syntax,
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
  if (o.isEmpty) return base;
  return base.copyWith(
    codeWellBg: o.codeWellBg != null ? Color(o.codeWellBg!) : null,
    codeWellHeader: o.codeWellHeader != null ? Color(o.codeWellHeader!) : null,
    codeWellFg: o.codeWellFg != null ? Color(o.codeWellFg!) : null,
    codeWellBorder: o.codeWellBorder != null ? Color(o.codeWellBorder!) : null,
    textTertiary: o.textTertiary != null ? Color(o.textTertiary!) : null,
    success: o.success != null ? Color(o.success!) : null,
    warning: o.warning != null ? Color(o.warning!) : null,
    danger: o.danger != null ? Color(o.danger!) : null,
    info: o.info != null ? Color(o.info!) : null,
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

  // Explicit tokens win over the preset and its tuning. The no-blur fill has
  // to stay opaque, so a translucent token is flattened onto the page.
  GlassStyle tokens(GlassStyle style, int? fill) {
    if (fill == null && o.hairline == null) return style;
    return style.copyWith(
      fill: fill != null ? Color(fill) : null,
      fallbackFill: fill != null ? Color.alphaBlend(Color(fill), top.withValues(alpha: 1.0)) : null,
      hairline: o.hairline != null ? Color(o.hairline!) : null,
    );
  }

  chrome = tokens(chrome, o.chromeFill);
  sheet = tokens(sheet, o.sheetFill);
  card = tokens(card, o.cardFill);
  pill = tokens(pill, null);

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
      s == null ? null : style._headingTraits(style.applyFontRole(mapUi(s)!, headingRole));

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
  Color? color(int? argb) => argb == null ? null : Color(argb);
  final syntax = ThemeSyntaxColors(
    keyword: color(o.syntaxKeyword),
    string: color(o.syntaxString),
    number: color(o.syntaxNumber),
    comment: color(o.syntaxComment),
    function: color(o.syntaxFunction),
    type: color(o.syntaxType),
  );
  return DshThemeStyle(
    pack: pack,
    loadedFonts: loadedFonts,
    assistantBubble: color(o.assistantBubble),
    onAssistantBubble: color(o.onAssistantBubble),
    link: color(o.link),
    heading: color(o.heading),
    rule: color(o.rule),
    userBubbleBorder: color(o.userBubbleBorder),
    assistantBorder: color(o.assistantBorder),
    composerFill: color(o.composerFill),
    composerBorder: color(o.composerBorder),
    sendButton: color(o.sendButton),
    onSendButton: color(o.onSendButton),
    inlineCodeBg: color(o.inlineCodeBg),
    inlineCodeFg: color(o.inlineCodeFg),
    syntax: syntax == const ThemeSyntaxColors() ? null : syntax,
  );
}
