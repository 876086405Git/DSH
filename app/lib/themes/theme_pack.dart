// Declarative theme pack model (schema 1).
// Lives outside ui/ so state/, workshop/ and validators can import it without
// crossing the ui/ dependency boundary.

import 'package:flutter/foundation.dart';

const userThemePrefix = 'user-';

bool isUserThemeId(String id) => id.startsWith(userThemePrefix);

/// Maps a public theme ID to its local storage folder ID without collisions
/// (e.g. `ink` -> `user-ink`, `user-ink` -> `user-user-ink`).
String userThemeIdFor(String publicId) => '$userThemePrefix$publicId';

/// Inverse of [userThemeIdFor] for a local storage folder ID.
String publicThemeIdFor(String localId) =>
    isUserThemeId(localId) ? localId.substring(userThemePrefix.length) : localId;

final _themeIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final _hexColorPattern = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');
final _assetNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$');

bool isValidThemeId(Object? value) =>
    value is String && value.length <= 40 && _themeIdPattern.hasMatch(value);

bool isSafeThemeAssetName(Object? value, List<String> allowedExtensions) {
  if (value is! String || value.isEmpty || value.length > 80) return false;
  if (!_assetNamePattern.hasMatch(value) || value.contains('..')) return false;
  final lower = value.toLowerCase();
  return allowedExtensions.any((ext) => lower.endsWith(ext));
}

int? parseThemeHexColor(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (!_hexColorPattern.hasMatch(trimmed)) return null;
  final hex = trimmed.substring(1);
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return hex.length == 6 ? (0xFF000000 | parsed) : parsed;
}

String formatThemeHexColor(int argb, {bool includeAlpha = false}) {
  final masked = argb & 0xFFFFFFFF;
  if (!includeAlpha && (masked >> 24) == 0xFF) {
    return '#${(masked & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
  return '#${masked.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

enum ThemeSurfacePreset { glass, paper, flat, outlined }

enum ThemeHeaderStyle { glass, ghost, outlined, minimal }

enum ThemeComposerStyle { floatingGlass, solidPaper, outlined }

enum ThemeSendButtonStyle { primary, ink, tonal }

enum ThemeUserBubbleStyle { soft, outlined, accent, minimal }

enum ThemeAssistantStyle { plain, card, leftRule }

enum ThemeSuggestionCardStyle { glass, paper, outlined, minimal }

enum ThemeCodeBlockStyle { well, outlined, card }

enum ThemeEmptyLayout { centered, editorial, compact }

enum ThemeHeroStyle { whale, badge, customImage, hidden }

enum ThemeSuggestionsDisplay { expanded, collapsible, grid }

@immutable
class ThemeColorOverrides {
  const ThemeColorOverrides({
    this.backdropTop,
    this.backdropBottom,
    this.glowPrimary,
    this.glowSecondary,
    this.surface,
    this.onSurface,
    this.onSurfaceVariant,
    this.outline,
    this.outlineVariant,
    this.primary,
    this.onPrimary,
    this.primaryContainer,
    this.onPrimaryContainer,
    this.userBubble,
    this.onUserBubble,
    this.assistantBubble,
    this.onAssistantBubble,
    this.codeWellBg,
    this.codeWellHeader,
    this.codeWellFg,
    this.codeWellBorder,
  });

  final int? backdropTop;
  final int? backdropBottom;
  final int? glowPrimary;
  final int? glowSecondary;
  final int? surface;
  final int? onSurface;
  final int? onSurfaceVariant;
  final int? outline;
  final int? outlineVariant;
  final int? primary;
  final int? onPrimary;
  final int? primaryContainer;
  final int? onPrimaryContainer;
  final int? userBubble;
  final int? onUserBubble;
  final int? assistantBubble;
  final int? onAssistantBubble;
  final int? codeWellBg;
  final int? codeWellHeader;
  final int? codeWellFg;
  final int? codeWellBorder;

  bool get isEmpty =>
      backdropTop == null &&
      backdropBottom == null &&
      glowPrimary == null &&
      glowSecondary == null &&
      surface == null &&
      onSurface == null &&
      onSurfaceVariant == null &&
      outline == null &&
      outlineVariant == null &&
      primary == null &&
      onPrimary == null &&
      primaryContainer == null &&
      onPrimaryContainer == null &&
      userBubble == null &&
      onUserBubble == null &&
      assistantBubble == null &&
      onAssistantBubble == null &&
      codeWellBg == null &&
      codeWellHeader == null &&
      codeWellFg == null &&
      codeWellBorder == null;

  static const _keys = {
    'backdropTop',
    'backdropBottom',
    'glowPrimary',
    'glowSecondary',
    'surface',
    'onSurface',
    'onSurfaceVariant',
    'outline',
    'outlineVariant',
    'primary',
    'onPrimary',
    'primaryContainer',
    'onPrimaryContainer',
    'userBubble',
    'onUserBubble',
    'assistantBubble',
    'onAssistantBubble',
    'codeWellBg',
    'codeWellHeader',
    'codeWellFg',
    'codeWellBorder',
  };

  factory ThemeColorOverrides.parse(Object? raw, String path) {
    if (raw == null) return const ThemeColorOverrides();
    if (raw is! Map) throw FormatException('$path must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('$path.$key is not a supported color token');
      }
    }
    int? color(String key) {
      final value = raw[key];
      if (value == null) return null;
      final parsed = parseThemeHexColor(value);
      if (parsed == null) throw FormatException('$path.$key must be #RRGGBB or #AARRGGBB');
      return parsed;
    }

    return ThemeColorOverrides(
      backdropTop: color('backdropTop'),
      backdropBottom: color('backdropBottom'),
      glowPrimary: color('glowPrimary'),
      glowSecondary: color('glowSecondary'),
      surface: color('surface'),
      onSurface: color('onSurface'),
      onSurfaceVariant: color('onSurfaceVariant'),
      outline: color('outline'),
      outlineVariant: color('outlineVariant'),
      primary: color('primary'),
      onPrimary: color('onPrimary'),
      primaryContainer: color('primaryContainer'),
      onPrimaryContainer: color('onPrimaryContainer'),
      userBubble: color('userBubble'),
      onUserBubble: color('onUserBubble'),
      assistantBubble: color('assistantBubble'),
      onAssistantBubble: color('onAssistantBubble'),
      codeWellBg: color('codeWellBg'),
      codeWellHeader: color('codeWellHeader'),
      codeWellFg: color('codeWellFg'),
      codeWellBorder: color('codeWellBorder'),
    );
  }

  Map<String, Object?> toJson() => {
    if (backdropTop != null) 'backdropTop': formatThemeHexColor(backdropTop!),
    if (backdropBottom != null) 'backdropBottom': formatThemeHexColor(backdropBottom!),
    if (glowPrimary != null) 'glowPrimary': formatThemeHexColor(glowPrimary!),
    if (glowSecondary != null) 'glowSecondary': formatThemeHexColor(glowSecondary!),
    if (surface != null) 'surface': formatThemeHexColor(surface!),
    if (onSurface != null) 'onSurface': formatThemeHexColor(onSurface!),
    if (onSurfaceVariant != null) 'onSurfaceVariant': formatThemeHexColor(onSurfaceVariant!),
    if (outline != null) 'outline': formatThemeHexColor(outline!),
    if (outlineVariant != null) 'outlineVariant': formatThemeHexColor(outlineVariant!),
    if (primary != null) 'primary': formatThemeHexColor(primary!),
    if (onPrimary != null) 'onPrimary': formatThemeHexColor(onPrimary!),
    if (primaryContainer != null) 'primaryContainer': formatThemeHexColor(primaryContainer!),
    if (onPrimaryContainer != null) 'onPrimaryContainer': formatThemeHexColor(onPrimaryContainer!),
    if (userBubble != null) 'userBubble': formatThemeHexColor(userBubble!),
    if (onUserBubble != null) 'onUserBubble': formatThemeHexColor(onUserBubble!),
    if (assistantBubble != null) 'assistantBubble': formatThemeHexColor(assistantBubble!),
    if (onAssistantBubble != null) 'onAssistantBubble': formatThemeHexColor(onAssistantBubble!),
    if (codeWellBg != null) 'codeWellBg': formatThemeHexColor(codeWellBg!),
    if (codeWellHeader != null) 'codeWellHeader': formatThemeHexColor(codeWellHeader!),
    if (codeWellFg != null) 'codeWellFg': formatThemeHexColor(codeWellFg!),
    if (codeWellBorder != null) 'codeWellBorder': formatThemeHexColor(codeWellBorder!),
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeColorOverrides &&
      other.backdropTop == backdropTop &&
      other.backdropBottom == backdropBottom &&
      other.glowPrimary == glowPrimary &&
      other.glowSecondary == glowSecondary &&
      other.surface == surface &&
      other.onSurface == onSurface &&
      other.onSurfaceVariant == onSurfaceVariant &&
      other.outline == outline &&
      other.outlineVariant == outlineVariant &&
      other.primary == primary &&
      other.onPrimary == onPrimary &&
      other.primaryContainer == primaryContainer &&
      other.onPrimaryContainer == onPrimaryContainer &&
      other.userBubble == userBubble &&
      other.onUserBubble == onUserBubble &&
      other.assistantBubble == assistantBubble &&
      other.onAssistantBubble == onAssistantBubble &&
      other.codeWellBg == codeWellBg &&
      other.codeWellHeader == codeWellHeader &&
      other.codeWellFg == codeWellFg &&
      other.codeWellBorder == codeWellBorder;

  @override
  int get hashCode => Object.hashAll([
    backdropTop,
    backdropBottom,
    glowPrimary,
    glowSecondary,
    surface,
    onSurface,
    onSurfaceVariant,
    outline,
    outlineVariant,
    primary,
    onPrimary,
    primaryContainer,
    onPrimaryContainer,
    userBubble,
    onUserBubble,
    assistantBubble,
    onAssistantBubble,
    codeWellBg,
    codeWellHeader,
    codeWellFg,
    codeWellBorder,
  ]);
}

@immutable
class ThemePaletteSpec {
  const ThemePaletteSpec({
    this.seed = 0xFF4B67B4,
    this.seedDark,
    this.tintHue,
    this.tintChroma = 1.0,
    this.glowOpacity = 1.0,
    this.light = const ThemeColorOverrides(),
    this.dark = const ThemeColorOverrides(),
  });

  final int seed;
  final int? seedDark;
  final double? tintHue;
  final double tintChroma;
  final double glowOpacity;
  final ThemeColorOverrides light;
  final ThemeColorOverrides dark;

  static const _keys = {'seed', 'seedDark', 'tintHue', 'tintChroma', 'glowOpacity', 'light', 'dark'};

  factory ThemePaletteSpec.parse(Object? raw) {
    if (raw == null) return const ThemePaletteSpec();
    if (raw is! Map) throw const FormatException('palette must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('palette.$key is not supported');
      }
    }
    final seed = raw['seed'] == null ? 0xFF4B67B4 : parseThemeHexColor(raw['seed']);
    if (seed == null) throw const FormatException('palette.seed must be #RRGGBB');
    int? seedDark;
    if (raw['seedDark'] != null) {
      seedDark = parseThemeHexColor(raw['seedDark']);
      if (seedDark == null) throw const FormatException('palette.seedDark must be #RRGGBB');
    }
    double? tintHue;
    if (raw['tintHue'] != null) {
      final v = raw['tintHue'];
      if (v is! num || !v.isFinite || v < 0 || v > 360) {
        throw const FormatException('palette.tintHue must be between 0 and 360');
      }
      tintHue = v.toDouble();
    }
    var tintChroma = 1.0;
    if (raw['tintChroma'] != null) {
      final v = raw['tintChroma'];
      if (v is! num || !v.isFinite || v < 0 || v > 2) {
        throw const FormatException('palette.tintChroma must be between 0 and 2');
      }
      tintChroma = v.toDouble();
    }
    var glowOpacity = 1.0;
    if (raw['glowOpacity'] != null) {
      final v = raw['glowOpacity'];
      if (v is! num || !v.isFinite || v < 0 || v > 1) {
        throw const FormatException('palette.glowOpacity must be between 0 and 1');
      }
      glowOpacity = v.toDouble();
    }
    return ThemePaletteSpec(
      seed: seed,
      seedDark: seedDark,
      tintHue: tintHue,
      tintChroma: tintChroma,
      glowOpacity: glowOpacity,
      light: ThemeColorOverrides.parse(raw['light'], 'palette.light'),
      dark: ThemeColorOverrides.parse(raw['dark'], 'palette.dark'),
    );
  }

  Map<String, Object?> toJson() => {
    'seed': formatThemeHexColor(seed),
    if (seedDark != null) 'seedDark': formatThemeHexColor(seedDark!),
    if (tintHue != null) 'tintHue': tintHue,
    if (tintChroma != 1.0) 'tintChroma': tintChroma,
    if (glowOpacity != 1.0) 'glowOpacity': glowOpacity,
    if (!light.isEmpty) 'light': light.toJson(),
    if (!dark.isEmpty) 'dark': dark.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ThemePaletteSpec &&
      other.seed == seed &&
      other.seedDark == seedDark &&
      other.tintHue == tintHue &&
      other.tintChroma == tintChroma &&
      other.glowOpacity == glowOpacity &&
      other.light == light &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(seed, seedDark, tintHue, tintChroma, glowOpacity, light, dark);
}

@immutable
class ThemeSurfaceSpec {
  const ThemeSurfaceSpec({
    this.preset = ThemeSurfacePreset.glass,
    this.chromeBlur,
    this.sheetBlur,
    this.cardOpacity,
    this.pillOpacity,
    this.hairlineWidth,
    this.rimOpacity,
    this.shadowOpacity,
    this.backdropImage,
    this.backdropOpacity = 0.18,
    this.backdropRepeat = false,
  });

  final ThemeSurfacePreset preset;
  final double? chromeBlur;
  final double? sheetBlur;
  final double? cardOpacity;
  final double? pillOpacity;
  final double? hairlineWidth;
  final double? rimOpacity;
  final double? shadowOpacity;
  final String? backdropImage;
  final double backdropOpacity;
  final bool backdropRepeat;

  static const _keys = {
    'preset',
    'chromeBlur',
    'sheetBlur',
    'cardOpacity',
    'pillOpacity',
    'hairlineWidth',
    'rimOpacity',
    'shadowOpacity',
    'backdropImage',
    'backdropOpacity',
    'backdropRepeat',
  };

  factory ThemeSurfaceSpec.parse(Object? raw) {
    if (raw == null) return const ThemeSurfaceSpec();
    if (raw is! Map) throw const FormatException('surfaces must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('surfaces.$key is not supported');
      }
    }
    var preset = ThemeSurfacePreset.glass;
    if (raw['preset'] != null) {
      final p = raw['preset'];
      if (p is! String || !ThemeSurfacePreset.values.asNameMap().containsKey(p)) {
        throw const FormatException('surfaces.preset is invalid');
      }
      preset = ThemeSurfacePreset.values.byName(p);
    }
    double? bounded(String key, double min, double max) {
      final v = raw[key];
      if (v == null) return null;
      if (v is! num || !v.isFinite || v < min || v > max) {
        throw FormatException('surfaces.$key must be between $min and $max');
      }
      return v.toDouble();
    }

    String? backdropImage;
    if (raw['backdropImage'] != null) {
      final img = raw['backdropImage'];
      if (!isSafeThemeAssetName(img, const ['.png'])) {
        throw const FormatException('surfaces.backdropImage must be a local .png filename');
      }
      backdropImage = img as String;
    }

    final repeatRaw = raw['backdropRepeat'];
    if (repeatRaw != null && repeatRaw is! bool) {
      throw const FormatException('surfaces.backdropRepeat must be a boolean');
    }

    return ThemeSurfaceSpec(
      preset: preset,
      chromeBlur: bounded('chromeBlur', 0, 40),
      sheetBlur: bounded('sheetBlur', 0, 40),
      cardOpacity: bounded('cardOpacity', 0, 1),
      pillOpacity: bounded('pillOpacity', 0, 1),
      hairlineWidth: bounded('hairlineWidth', 0, 3),
      rimOpacity: bounded('rimOpacity', 0, 1),
      shadowOpacity: bounded('shadowOpacity', 0, 1),
      backdropImage: backdropImage,
      backdropOpacity: bounded('backdropOpacity', 0, 1) ?? 0.18,
      backdropRepeat: (repeatRaw as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() => {
    'preset': preset.name,
    if (chromeBlur != null) 'chromeBlur': chromeBlur,
    if (sheetBlur != null) 'sheetBlur': sheetBlur,
    if (cardOpacity != null) 'cardOpacity': cardOpacity,
    if (pillOpacity != null) 'pillOpacity': pillOpacity,
    if (hairlineWidth != null) 'hairlineWidth': hairlineWidth,
    if (rimOpacity != null) 'rimOpacity': rimOpacity,
    if (shadowOpacity != null) 'shadowOpacity': shadowOpacity,
    if (backdropImage != null) 'backdropImage': backdropImage,
    if (backdropImage != null && backdropOpacity != 0.18) 'backdropOpacity': backdropOpacity,
    if (backdropImage != null && backdropRepeat) 'backdropRepeat': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeSurfaceSpec &&
      other.preset == preset &&
      other.chromeBlur == chromeBlur &&
      other.sheetBlur == sheetBlur &&
      other.cardOpacity == cardOpacity &&
      other.pillOpacity == pillOpacity &&
      other.hairlineWidth == hairlineWidth &&
      other.rimOpacity == rimOpacity &&
      other.shadowOpacity == shadowOpacity &&
      other.backdropImage == backdropImage &&
      other.backdropOpacity == backdropOpacity &&
      other.backdropRepeat == backdropRepeat;

  @override
  int get hashCode => Object.hash(
    preset,
    chromeBlur,
    sheetBlur,
    cardOpacity,
    pillOpacity,
    hairlineWidth,
    rimOpacity,
    shadowOpacity,
    backdropImage,
    backdropOpacity,
    backdropRepeat,
  );
}

@immutable
class ThemeTypographySpec {
  const ThemeTypographySpec({
    this.uiFont = 'system',
    this.readingFont = 'system',
    this.headingFont = 'system',
    this.codeFont = 'JetBrainsMono',
    this.readingScale = 1.0,
    this.readingLineHeight = 1.55,
    this.headingScale = 1.0,
  });

  final String uiFont;
  final String readingFont;
  final String headingFont;
  final String codeFont;
  final double readingScale;
  final double readingLineHeight;
  final double headingScale;

  static const _keys = {
    'uiFont',
    'readingFont',
    'headingFont',
    'codeFont',
    'readingScale',
    'readingLineHeight',
    'headingScale',
  };

  static const _builtInRoles = {'system', 'serif', 'mono', 'JetBrainsMono', 'monospace'};

  static bool isCustomFontAsset(String value) => !_builtInRoles.contains(value);

  Set<String> get referencedFontFiles => {
    if (isCustomFontAsset(uiFont)) uiFont,
    if (isCustomFontAsset(readingFont)) readingFont,
    if (isCustomFontAsset(headingFont)) headingFont,
    if (isCustomFontAsset(codeFont)) codeFont,
  };

  factory ThemeTypographySpec.parse(Object? raw) {
    if (raw == null) return const ThemeTypographySpec();
    if (raw is! Map) throw const FormatException('typography must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('typography.$key is not supported');
      }
    }
    String fontRole(String key, String fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      if (v is! String) throw FormatException('typography.$key must be a string');
      if (_builtInRoles.contains(v)) return v;
      if (isSafeThemeAssetName(v, const ['.ttf', '.otf'])) return v;
      throw FormatException('typography.$key must be system, serif, mono, or a local .ttf/.otf filename');
    }

    double bounded(String key, double min, double max, double fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      if (v is! num || !v.isFinite || v < min || v > max) {
        throw FormatException('typography.$key must be between $min and $max');
      }
      return v.toDouble();
    }

    final spec = ThemeTypographySpec(
      uiFont: fontRole('uiFont', 'system'),
      readingFont: fontRole('readingFont', 'system'),
      headingFont: fontRole('headingFont', 'system'),
      codeFont: fontRole('codeFont', 'JetBrainsMono'),
      readingScale: bounded('readingScale', 0.85, 1.25, 1.0),
      readingLineHeight: bounded('readingLineHeight', 1.2, 2.0, 1.55),
      headingScale: bounded('headingScale', 0.85, 1.35, 1.0),
    );
    if (spec.referencedFontFiles.length > 2) {
      throw const FormatException('typography may reference at most 2 bundled font files');
    }
    return spec;
  }

  Map<String, Object?> toJson() => {
    if (uiFont != 'system') 'uiFont': uiFont,
    if (readingFont != 'system') 'readingFont': readingFont,
    if (headingFont != 'system') 'headingFont': headingFont,
    if (codeFont != 'JetBrainsMono') 'codeFont': codeFont,
    if (readingScale != 1.0) 'readingScale': readingScale,
    if (readingLineHeight != 1.55) 'readingLineHeight': readingLineHeight,
    if (headingScale != 1.0) 'headingScale': headingScale,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeTypographySpec &&
      other.uiFont == uiFont &&
      other.readingFont == readingFont &&
      other.headingFont == headingFont &&
      other.codeFont == codeFont &&
      other.readingScale == readingScale &&
      other.readingLineHeight == readingLineHeight &&
      other.headingScale == headingScale;

  @override
  int get hashCode =>
      Object.hash(uiFont, readingFont, headingFont, codeFont, readingScale, readingLineHeight, headingScale);
}

@immutable
class ThemeShapeSpec {
  const ThemeShapeSpec({
    this.cornerScale = 1.0,
    this.borderWidth = 0.5,
    this.turnGap = 24.0,
    this.inTurnGap = 8.0,
    this.gutter = 16.0,
  });

  final double cornerScale;
  final double borderWidth;
  final double turnGap;
  final double inTurnGap;
  final double gutter;

  static const _keys = {'cornerScale', 'borderWidth', 'turnGap', 'inTurnGap', 'gutter'};

  factory ThemeShapeSpec.parse(Object? raw) {
    if (raw == null) return const ThemeShapeSpec();
    if (raw is! Map) throw const FormatException('shapes must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('shapes.$key is not supported');
      }
    }
    double bounded(String key, double min, double max, double fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      if (v is! num || !v.isFinite || v < min || v > max) {
        throw FormatException('shapes.$key must be between $min and $max');
      }
      return v.toDouble();
    }

    return ThemeShapeSpec(
      cornerScale: bounded('cornerScale', 0.0, 1.6, 1.0),
      borderWidth: bounded('borderWidth', 0.0, 2.5, 0.5),
      turnGap: bounded('turnGap', 12.0, 40.0, 24.0),
      inTurnGap: bounded('inTurnGap', 4.0, 20.0, 8.0),
      gutter: bounded('gutter', 10.0, 28.0, 16.0),
    );
  }

  Map<String, Object?> toJson() => {
    if (cornerScale != 1.0) 'cornerScale': cornerScale,
    if (borderWidth != 0.5) 'borderWidth': borderWidth,
    if (turnGap != 24.0) 'turnGap': turnGap,
    if (inTurnGap != 8.0) 'inTurnGap': inTurnGap,
    if (gutter != 16.0) 'gutter': gutter,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeShapeSpec &&
      other.cornerScale == cornerScale &&
      other.borderWidth == borderWidth &&
      other.turnGap == turnGap &&
      other.inTurnGap == inTurnGap &&
      other.gutter == gutter;

  @override
  int get hashCode => Object.hash(cornerScale, borderWidth, turnGap, inTurnGap, gutter);
}

@immutable
class ThemeComponentSpec {
  const ThemeComponentSpec({
    this.headerStyle = ThemeHeaderStyle.glass,
    this.composerStyle = ThemeComposerStyle.floatingGlass,
    this.sendButtonStyle = ThemeSendButtonStyle.primary,
    this.userBubbleStyle = ThemeUserBubbleStyle.soft,
    this.assistantStyle = ThemeAssistantStyle.plain,
    this.useReadingFontForReply = false,
    this.suggestionCardStyle = ThemeSuggestionCardStyle.glass,
    this.codeBlockStyle = ThemeCodeBlockStyle.well,
  });

  final ThemeHeaderStyle headerStyle;
  final ThemeComposerStyle composerStyle;
  final ThemeSendButtonStyle sendButtonStyle;
  final ThemeUserBubbleStyle userBubbleStyle;
  final ThemeAssistantStyle assistantStyle;
  final bool useReadingFontForReply;
  final ThemeSuggestionCardStyle suggestionCardStyle;
  final ThemeCodeBlockStyle codeBlockStyle;

  static const _keys = {
    'headerStyle',
    'composerStyle',
    'sendButtonStyle',
    'userBubbleStyle',
    'assistantStyle',
    'useReadingFontForReply',
    'suggestionCardStyle',
    'codeBlockStyle',
  };

  factory ThemeComponentSpec.parse(Object? raw) {
    if (raw == null) return const ThemeComponentSpec();
    if (raw is! Map) throw const FormatException('components must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('components.$key is not supported');
      }
    }
    T pick<T extends Enum>(String key, List<T> values, T fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      final hit = values.asNameMap()[v];
      if (hit == null) throw FormatException('components.$key is invalid');
      return hit;
    }

    final useReading = raw['useReadingFontForReply'];
    if (useReading != null && useReading is! bool) {
      throw const FormatException('components.useReadingFontForReply must be a boolean');
    }

    return ThemeComponentSpec(
      headerStyle: pick('headerStyle', ThemeHeaderStyle.values, ThemeHeaderStyle.glass),
      composerStyle: pick('composerStyle', ThemeComposerStyle.values, ThemeComposerStyle.floatingGlass),
      sendButtonStyle: pick('sendButtonStyle', ThemeSendButtonStyle.values, ThemeSendButtonStyle.primary),
      userBubbleStyle: pick('userBubbleStyle', ThemeUserBubbleStyle.values, ThemeUserBubbleStyle.soft),
      assistantStyle: pick('assistantStyle', ThemeAssistantStyle.values, ThemeAssistantStyle.plain),
      useReadingFontForReply: (useReading as bool?) ?? false,
      suggestionCardStyle: pick('suggestionCardStyle', ThemeSuggestionCardStyle.values, ThemeSuggestionCardStyle.glass),
      codeBlockStyle: pick('codeBlockStyle', ThemeCodeBlockStyle.values, ThemeCodeBlockStyle.well),
    );
  }

  Map<String, Object?> toJson() => {
    if (headerStyle != ThemeHeaderStyle.glass) 'headerStyle': headerStyle.name,
    if (composerStyle != ThemeComposerStyle.floatingGlass) 'composerStyle': composerStyle.name,
    if (sendButtonStyle != ThemeSendButtonStyle.primary) 'sendButtonStyle': sendButtonStyle.name,
    if (userBubbleStyle != ThemeUserBubbleStyle.soft) 'userBubbleStyle': userBubbleStyle.name,
    if (assistantStyle != ThemeAssistantStyle.plain) 'assistantStyle': assistantStyle.name,
    if (useReadingFontForReply) 'useReadingFontForReply': true,
    if (suggestionCardStyle != ThemeSuggestionCardStyle.glass) 'suggestionCardStyle': suggestionCardStyle.name,
    if (codeBlockStyle != ThemeCodeBlockStyle.well) 'codeBlockStyle': codeBlockStyle.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeComponentSpec &&
      other.headerStyle == headerStyle &&
      other.composerStyle == composerStyle &&
      other.sendButtonStyle == sendButtonStyle &&
      other.userBubbleStyle == userBubbleStyle &&
      other.assistantStyle == assistantStyle &&
      other.useReadingFontForReply == useReadingFontForReply &&
      other.suggestionCardStyle == suggestionCardStyle &&
      other.codeBlockStyle == codeBlockStyle;

  @override
  int get hashCode => Object.hash(
    headerStyle,
    composerStyle,
    sendButtonStyle,
    userBubbleStyle,
    assistantStyle,
    useReadingFontForReply,
    suggestionCardStyle,
    codeBlockStyle,
  );
}

@immutable
class ThemeEmptyStateSpec {
  const ThemeEmptyStateSpec({
    this.layout = ThemeEmptyLayout.centered,
    this.heroStyle = ThemeHeroStyle.whale,
    this.heroImage,
    this.useReadingFontForGreeting = false,
    this.showConnectedSubtitle = true,
    this.suggestionsDisplay = ThemeSuggestionsDisplay.expanded,
  });

  final ThemeEmptyLayout layout;
  final ThemeHeroStyle heroStyle;
  final String? heroImage;
  final bool useReadingFontForGreeting;
  final bool showConnectedSubtitle;
  final ThemeSuggestionsDisplay suggestionsDisplay;

  static const _keys = {
    'layout',
    'heroStyle',
    'heroImage',
    'useReadingFontForGreeting',
    'showConnectedSubtitle',
    'suggestionsDisplay',
  };

  factory ThemeEmptyStateSpec.parse(Object? raw) {
    if (raw == null) return const ThemeEmptyStateSpec();
    if (raw is! Map) throw const FormatException('emptyState must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('emptyState.$key is not supported');
      }
    }
    T pick<T extends Enum>(String key, List<T> values, T fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      final hit = values.asNameMap()[v];
      if (hit == null) throw FormatException('emptyState.$key is invalid');
      return hit;
    }

    String? heroImage;
    if (raw['heroImage'] != null) {
      final img = raw['heroImage'];
      if (!isSafeThemeAssetName(img, const ['.png'])) {
        throw const FormatException('emptyState.heroImage must be a local .png filename');
      }
      heroImage = img as String;
    }
    final useReading = raw['useReadingFontForGreeting'];
    if (useReading != null && useReading is! bool) {
      throw const FormatException('emptyState.useReadingFontForGreeting must be a boolean');
    }
    final showSubtitle = raw['showConnectedSubtitle'];
    if (showSubtitle != null && showSubtitle is! bool) {
      throw const FormatException('emptyState.showConnectedSubtitle must be a boolean');
    }

    final heroStyle = pick('heroStyle', ThemeHeroStyle.values, ThemeHeroStyle.whale);
    if (heroStyle == ThemeHeroStyle.customImage && heroImage == null) {
      throw const FormatException('emptyState.heroImage is required when heroStyle is customImage');
    }

    return ThemeEmptyStateSpec(
      layout: pick('layout', ThemeEmptyLayout.values, ThemeEmptyLayout.centered),
      heroStyle: heroStyle,
      heroImage: heroImage,
      useReadingFontForGreeting: (useReading as bool?) ?? false,
      showConnectedSubtitle: (showSubtitle as bool?) ?? true,
      suggestionsDisplay: pick(
        'suggestionsDisplay',
        ThemeSuggestionsDisplay.values,
        ThemeSuggestionsDisplay.expanded,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    if (layout != ThemeEmptyLayout.centered) 'layout': layout.name,
    if (heroStyle != ThemeHeroStyle.whale) 'heroStyle': heroStyle.name,
    if (heroImage != null) 'heroImage': heroImage,
    if (useReadingFontForGreeting) 'useReadingFontForGreeting': true,
    if (!showConnectedSubtitle) 'showConnectedSubtitle': false,
    if (suggestionsDisplay != ThemeSuggestionsDisplay.expanded) 'suggestionsDisplay': suggestionsDisplay.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeEmptyStateSpec &&
      other.layout == layout &&
      other.heroStyle == heroStyle &&
      other.heroImage == heroImage &&
      other.useReadingFontForGreeting == useReadingFontForGreeting &&
      other.showConnectedSubtitle == showConnectedSubtitle &&
      other.suggestionsDisplay == suggestionsDisplay;

  @override
  int get hashCode => Object.hash(
    layout,
    heroStyle,
    heroImage,
    useReadingFontForGreeting,
    showConnectedSubtitle,
    suggestionsDisplay,
  );
}

@immutable
class ThemePack {
  const ThemePack({
    required this.id,
    required this.name,
    this.titleZh,
    this.titleEn,
    this.description = '',
    this.tags = const [],
    this.author,
    this.license,
    this.source,
    this.palette = const ThemePaletteSpec(),
    this.surfaces = const ThemeSurfaceSpec(),
    this.typography = const ThemeTypographySpec(),
    this.shapes = const ThemeShapeSpec(),
    this.components = const ThemeComponentSpec(),
    this.emptyState = const ThemeEmptyStateSpec(),
    this.folderPath,
    this.assetRevision = 0,
  });

  final String id;
  final String name;
  final String? titleZh;
  final String? titleEn;
  final String description;
  final List<String> tags;
  final String? author;
  final String? license;
  final String? source;
  final ThemePaletteSpec palette;
  final ThemeSurfaceSpec surfaces;
  final ThemeTypographySpec typography;
  final ThemeShapeSpec shapes;
  final ThemeComponentSpec components;
  final ThemeEmptyStateSpec emptyState;

  /// Local folder path when loaded from disk. Never serialized into theme.json.
  final String? folderPath;

  /// Monotonic disk revision so replaced same-name images reload instead of
  /// hitting stale FileImage cache entries. Never serialized into theme.json.
  final int assetRevision;

  String get publicId => folderPath != null ? publicThemeIdFor(id) : id;

  String displayName([String? languageCode]) {
    if (languageCode == 'en' && titleEn != null && titleEn!.trim().isNotEmpty) {
      return titleEn!.trim();
    }
    if (languageCode == 'zh' && titleZh != null && titleZh!.trim().isNotEmpty) {
      return titleZh!.trim();
    }
    return name;
  }

  Set<String> get referencedImages => {
    if (surfaces.backdropImage != null) surfaces.backdropImage!,
    if (emptyState.heroImage != null) emptyState.heroImage!,
  };

  Set<String> get referencedFonts => typography.referencedFontFiles;

  static const _topKeys = {
    'schema',
    'id',
    'name',
    'title',
    'description',
    'tags',
    'author',
    'license',
    'source',
    'palette',
    'surfaces',
    'typography',
    'shapes',
    'components',
    'emptyState',
  };

  static bool _nonBlankText(Object? value, int maxRunes) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.runes.length <= maxRunes &&
      !value.runes.any((r) => r < 32 || (r >= 0xD800 && r <= 0xDFFF));

  factory ThemePack.parse(Map<String, Object?> raw, {String? folderPath}) {
    for (final key in raw.keys) {
      if (!_topKeys.contains(key)) {
        throw FormatException('Unknown theme.json field: $key');
      }
    }
    if (raw['schema'] != 1) {
      throw const FormatException('theme.json schema must be 1');
    }
    final rawId = raw['id'];
    if (!isValidThemeId(rawId)) {
      throw const FormatException('theme.json id must be lower-case kebab-case up to 40 chars');
    }
    final name = raw['name'];
    if (!_nonBlankText(name, 120)) {
      throw const FormatException('theme.json name must be non-empty up to 120 chars');
    }

    String? titleZh;
    String? titleEn;
    if (raw['title'] != null) {
      final t = raw['title'];
      if (t is! Map) throw const FormatException('theme.json title must be an object');
      for (final k in t.keys) {
        if (k != 'zh' && k != 'en') throw FormatException('theme.json title.$k is not supported');
      }
      if (t['zh'] != null) {
        if (!_nonBlankText(t['zh'], 120)) throw const FormatException('theme.json title.zh is invalid');
        titleZh = t['zh'] as String;
      }
      if (t['en'] != null) {
        if (!_nonBlankText(t['en'], 120)) throw const FormatException('theme.json title.en is invalid');
        titleEn = t['en'] as String;
      }
    }

    var description = '';
    if (raw['description'] != null && raw['description'] != '') {
      if (!_nonBlankText(raw['description'], 512)) {
        throw const FormatException('theme.json description is invalid');
      }
      description = raw['description'] as String;
    }

    var tags = const <String>[];
    if (raw['tags'] != null) {
      final list = raw['tags'];
      if (list is! List || list.length > 8) {
        throw const FormatException('theme.json tags must be a list of up to 8 strings');
      }
      final checked = <String>[];
      for (final item in list) {
        if (!_nonBlankText(item, 32)) throw const FormatException('theme.json tag is invalid');
        checked.add(item as String);
      }
      if (checked.toSet().length != checked.length) {
        throw const FormatException('theme.json tags must be unique');
      }
      tags = List.unmodifiable(checked);
    }

    String? optionalMeta(String key, int cap) {
      final v = raw[key];
      if (v == null) return null;
      if (!_nonBlankText(v, cap)) throw FormatException('theme.json $key is invalid');
      return v as String;
    }

    final author = optionalMeta('author', 256);
    final license = optionalMeta('license', 100);
    final source = optionalMeta('source', 2048);
    if (source != null) {
      final uri = Uri.tryParse(source);
      if (RegExp(r'\s').hasMatch(source) ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('theme.json source must be a valid https URL');
      }
    }

    return ThemePack(
      id: rawId as String,
      name: name as String,
      titleZh: titleZh,
      titleEn: titleEn,
      description: description,
      tags: tags,
      author: author,
      license: license,
      source: source,
      palette: ThemePaletteSpec.parse(raw['palette']),
      surfaces: ThemeSurfaceSpec.parse(raw['surfaces']),
      typography: ThemeTypographySpec.parse(raw['typography']),
      shapes: ThemeShapeSpec.parse(raw['shapes']),
      components: ThemeComponentSpec.parse(raw['components']),
      emptyState: ThemeEmptyStateSpec.parse(raw['emptyState']),
      folderPath: folderPath,
    );
  }

  ThemePack copyWith({
    String? id,
    String? name,
    String? titleZh,
    String? titleEn,
    String? description,
    List<String>? tags,
    String? author,
    String? license,
    String? source,
    ThemePaletteSpec? palette,
    ThemeSurfaceSpec? surfaces,
    ThemeTypographySpec? typography,
    ThemeShapeSpec? shapes,
    ThemeComponentSpec? components,
    ThemeEmptyStateSpec? emptyState,
    String? folderPath,
    int? assetRevision,
  }) => ThemePack(
    id: id ?? this.id,
    name: name ?? this.name,
    titleZh: titleZh ?? this.titleZh,
    titleEn: titleEn ?? this.titleEn,
    description: description ?? this.description,
    tags: tags ?? this.tags,
    author: author ?? this.author,
    license: license ?? this.license,
    source: source ?? this.source,
    palette: palette ?? this.palette,
    surfaces: surfaces ?? this.surfaces,
    typography: typography ?? this.typography,
    shapes: shapes ?? this.shapes,
    components: components ?? this.components,
    emptyState: emptyState ?? this.emptyState,
    folderPath: folderPath ?? this.folderPath,
    assetRevision: assetRevision ?? this.assetRevision,
  );

  Map<String, Object?> toJson() => {
    'schema': 1,
    'id': id,
    'name': name,
    if (titleZh != null || titleEn != null)
      'title': {
        if (titleZh != null) 'zh': titleZh,
        if (titleEn != null) 'en': titleEn,
      },
    if (description.isNotEmpty) 'description': description,
    if (tags.isNotEmpty) 'tags': tags,
    if (author != null) 'author': author,
    if (license != null) 'license': license,
    if (source != null) 'source': source,
    'palette': palette.toJson(),
    'surfaces': surfaces.toJson(),
    if (typography.toJson().isNotEmpty) 'typography': typography.toJson(),
    if (shapes.toJson().isNotEmpty) 'shapes': shapes.toJson(),
    if (components.toJson().isNotEmpty) 'components': components.toJson(),
    if (emptyState.toJson().isNotEmpty) 'emptyState': emptyState.toJson(),
  };

  /// Built-in showcase theme packs that demonstrate the declarative engine's
  /// range without scattering `accent == paper` checks across widgets.
  static const paper = ThemePack(
    id: 'paper',
    name: '纸墨书卷',
    titleZh: '纸墨书卷',
    titleEn: 'Paper & Ink',
    description: '温润宣纸底色、赤陶印泥主色、无光晕实心表面与书卷衬线排印。',
    tags: ['纸墨', '阅读', '衬线'],
    palette: ThemePaletteSpec(
      seed: 0xFFA14732,
      seedDark: 0xFFE4A58C,
      tintHue: 74,
      tintChroma: 0.30,
      glowOpacity: 0.0,
      light: ThemeColorOverrides(
        backdropTop: 0xFFF7F4EC,
        backdropBottom: 0xFFF5F1E7,
        surface: 0xFFF7F4EC,
        onSurface: 0xFF1F1D19,
        onSurfaceVariant: 0xFF5A544B,
        outlineVariant: 0xFFDDD6C8,
        userBubble: 0xFFECE8E2,
        onUserBubble: 0xFF1F1E1B,
        codeWellBg: 0xFFEFEBE1,
        codeWellHeader: 0xFFE7E1D4,
        codeWellFg: 0xFF24211C,
        codeWellBorder: 0xFFD9D1C2,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF181614,
        backdropBottom: 0xFF161412,
        surface: 0xFF181614,
        onSurface: 0xFFECE7DE,
        onSurfaceVariant: 0xFFB4ACA0,
        outlineVariant: 0xFF332E29,
        userBubble: 0xFF2F2A25,
        onUserBubble: 0xFFECE9E2,
        codeWellBg: 0xFF211E1B,
        codeWellHeader: 0xFF282420,
        codeWellFg: 0xFFEAE4DA,
        codeWellBorder: 0xFF3A342E,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.paper,
      hairlineWidth: 1.0,
    ),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      headingFont: 'serif',
      readingLineHeight: 1.68,
      headingScale: 1.14,
    ),
    shapes: ThemeShapeSpec(
      cornerScale: 0.85,
      borderWidth: 1.0,
      turnGap: 26.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.ghost,
      composerStyle: ThemeComposerStyle.solidPaper,
      sendButtonStyle: ThemeSendButtonStyle.ink,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.plain,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.outlined,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.badge,
      useReadingFontForGreeting: true,
      showConnectedSubtitle: false,
      suggestionsDisplay: ThemeSuggestionsDisplay.collapsible,
    ),
  );

  static const bambooCeladon = ThemePack(
    id: 'bamboo-celadon',
    name: '竹韵青瓷',
    titleZh: '竹韵青瓷',
    titleEn: 'Bamboo Celadon',
    description: '月白天青渐变、松竹青瓷强调色、轻透柔光玻璃与左侧引线阅读。',
    tags: ['国风', '青瓷', '雅致'],
    palette: ThemePaletteSpec(
      seed: 0xFF2B6A58,
      seedDark: 0xFF7FC7B0,
      tintHue: 162,
      tintChroma: 0.42,
      glowOpacity: 0.48,
      light: ThemeColorOverrides(
        backdropTop: 0xFFF0F5F2,
        backdropBottom: 0xFFF7F9F6,
        glowPrimary: 0xFFA5D6C5,
        glowSecondary: 0xFFCDE3E8,
        userBubble: 0xFFDFECE6,
        onUserBubble: 0xFF14322A,
        codeWellBg: 0xFFE9F0EC,
        codeWellHeader: 0xFFDFEAE4,
        codeWellBorder: 0xFFC9DBD2,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF131B18,
        backdropBottom: 0xFF17201C,
        glowPrimary: 0xFF2E6B58,
        glowSecondary: 0xFF2A4E59,
        userBubble: 0xFF21332C,
        onUserBubble: 0xFFE4EFEA,
        codeWellBg: 0xFF1A2521,
        codeWellHeader: 0xFF202E29,
        codeWellBorder: 0xFF2E423B,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.glass,
      chromeBlur: 14.0,
      cardOpacity: 0.72,
      hairlineWidth: 0.8,
    ),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      headingFont: 'serif',
      readingLineHeight: 1.64,
      headingScale: 1.08,
    ),
    shapes: ThemeShapeSpec(
      cornerScale: 1.05,
      borderWidth: 0.8,
      turnGap: 24.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.glass,
      composerStyle: ThemeComposerStyle.floatingGlass,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      userBubbleStyle: ThemeUserBubbleStyle.outlined,
      assistantStyle: ThemeAssistantStyle.leftRule,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.well,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.editorial,
      heroStyle: ThemeHeroStyle.badge,
      useReadingFontForGreeting: true,
      showConnectedSubtitle: true,
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const terminalNoir = ThemePack(
    id: 'terminal-noir',
    name: '极夜终端',
    titleZh: '极夜终端',
    titleEn: 'Terminal Noir',
    description: '低圆角线框材质、青绿矩阵主色、全等宽排版与紧凑控制台节奏。',
    tags: ['终端', '等宽', '极简'],
    palette: ThemePaletteSpec(
      seed: 0xFF0D736A,
      seedDark: 0xFF2DD4BF,
      tintHue: 192,
      tintChroma: 0.16,
      glowOpacity: 0.14,
      light: ThemeColorOverrides(
        backdropTop: 0xFFF2F5F4,
        backdropBottom: 0xFFEDF1F0,
        userBubble: 0xFFE3ECEA,
        onUserBubble: 0xFF102422,
        codeWellBg: 0xFFE7ECEB,
        codeWellHeader: 0xFFDBE3E1,
        codeWellBorder: 0xFFC2CFCC,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF0E1315,
        backdropBottom: 0xFF11171A,
        surface: 0xFF0E1315,
        onSurface: 0xFFE2ECEB,
        outlineVariant: 0xFF253338,
        userBubble: 0xFF172629,
        onUserBubble: 0xFFD9F3EE,
        codeWellBg: 0xFF131A1D,
        codeWellHeader: 0xFF1A2327,
        codeWellFg: 0xFFDCEBE9,
        codeWellBorder: 0xFF27373D,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.outlined,
      hairlineWidth: 1.0,
    ),
    typography: ThemeTypographySpec(
      uiFont: 'mono',
      readingFont: 'mono',
      headingFont: 'mono',
      readingLineHeight: 1.5,
    ),
    shapes: ThemeShapeSpec(
      cornerScale: 0.28,
      borderWidth: 1.0,
      turnGap: 16.0,
      inTurnGap: 6.0,
      gutter: 14.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.outlined,
      composerStyle: ThemeComposerStyle.outlined,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      userBubbleStyle: ThemeUserBubbleStyle.outlined,
      assistantStyle: ThemeAssistantStyle.leftRule,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.outlined,
      codeBlockStyle: ThemeCodeBlockStyle.outlined,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.editorial,
      heroStyle: ThemeHeroStyle.badge,
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const sakuraCard = ThemePack(
    id: 'sakura-card',
    name: '落樱手账',
    titleZh: '落樱手账',
    titleEn: 'Sakura Journal',
    description: '柔粉雾光玻璃、云朵大圆角、独立书页卡片式助手回复与双列建议网格。',
    tags: ['手账', '卡片', '柔和'],
    palette: ThemePaletteSpec(
      seed: 0xFFB85A7C,
      seedDark: 0xFFF2A7C3,
      tintHue: 342,
      tintChroma: 0.65,
      glowOpacity: 0.85,
      light: ThemeColorOverrides(
        backdropTop: 0xFFFDF5F8,
        backdropBottom: 0xFFFAF0F4,
        glowPrimary: 0xFFF5BFD3,
        glowSecondary: 0xFFE3D2F6,
        userBubble: 0xFFF6E2EA,
        onUserBubble: 0xFF361A26,
        assistantBubble: 0xFFFFFAFC,
        onAssistantBubble: 0xFF2A1D23,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF1C1519,
        backdropBottom: 0xFF22191E,
        glowPrimary: 0xFF7D3E56,
        glowSecondary: 0xFF56426B,
        userBubble: 0xFF392630,
        onUserBubble: 0xFFF6E6ED,
        assistantBubble: 0xFF261D22,
        onAssistantBubble: 0xFFF0E4E9,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.glass,
      cardOpacity: 0.78,
    ),
    shapes: ThemeShapeSpec(
      cornerScale: 1.32,
      borderWidth: 0.6,
      turnGap: 24.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.glass,
      composerStyle: ThemeComposerStyle.floatingGlass,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.card,
      suggestionCardStyle: ThemeSuggestionCardStyle.glass,
      codeBlockStyle: ThemeCodeBlockStyle.card,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.whale,
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const amberCafe = ThemePack(
    id: 'amber-cafe',
    name: '琥珀咖啡馆',
    titleZh: '琥珀咖啡馆',
    titleEn: 'Amber Café',
    description: '燕麦拿铁暖调实面、焦糖琥珀点缀、柔和按键与温暖卡片阅读体验。',
    tags: ['暖调', '舒适', '卡片'],
    palette: ThemePaletteSpec(
      seed: 0xFF9A5B1F,
      seedDark: 0xFFE8B272,
      tintHue: 52,
      tintChroma: 0.45,
      glowOpacity: 0.45,
      light: ThemeColorOverrides(
        backdropTop: 0xFFFBF6EE,
        backdropBottom: 0xFFF4EBDC,
        glowPrimary: 0xFFF0CFA6,
        glowSecondary: 0xFFEADBC4,
        userBubble: 0xFFF0E2CC,
        onUserBubble: 0xFF2C1E12,
        assistantBubble: 0xFFFFFBF4,
        onAssistantBubble: 0xFF271D15,
        codeWellBg: 0xFFF2E9DA,
        codeWellHeader: 0xFFE9DEC9,
        codeWellBorder: 0xFFDDD0B8,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF1A1511,
        backdropBottom: 0xFF1F1914,
        glowPrimary: 0xFF704922,
        glowSecondary: 0xFF4F3D2D,
        userBubble: 0xFF33271D,
        onUserBubble: 0xFFF3E9DE,
        assistantBubble: 0xFF241D17,
        onAssistantBubble: 0xFFEDE4D9,
        codeWellBg: 0xFF221B15,
        codeWellHeader: 0xFF2B221A,
        codeWellBorder: 0xFF3E3227,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.flat,
      hairlineWidth: 0.8,
    ),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      readingLineHeight: 1.62,
    ),
    shapes: ThemeShapeSpec(
      cornerScale: 1.1,
      borderWidth: 0.8,
      turnGap: 22.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.minimal,
      composerStyle: ThemeComposerStyle.solidPaper,
      sendButtonStyle: ThemeSendButtonStyle.tonal,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.card,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.card,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.compact,
      heroStyle: ThemeHeroStyle.badge,
      useReadingFontForGreeting: true,
      showConnectedSubtitle: true,
      suggestionsDisplay: ThemeSuggestionsDisplay.expanded,
    ),
  );

  static const builtIns = <ThemePack>[paper, bambooCeladon, terminalNoir, sakuraCard, amberCafe];

  static ThemePack? builtInById(String? id) {
    if (id == null) return null;
    for (final pack in builtIns) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ThemePack &&
      other.id == id &&
      other.name == name &&
      other.titleZh == titleZh &&
      other.titleEn == titleEn &&
      other.description == description &&
      listEquals(other.tags, tags) &&
      other.author == author &&
      other.license == license &&
      other.source == source &&
      other.palette == palette &&
      other.surfaces == surfaces &&
      other.typography == typography &&
      other.shapes == shapes &&
      other.components == components &&
      other.emptyState == emptyState &&
      other.folderPath == folderPath &&
      other.assetRevision == assetRevision;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    titleZh,
    titleEn,
    description,
    Object.hashAll(tags),
    author,
    license,
    source,
    palette,
    surfaces,
    typography,
    shapes,
    components,
    emptyState,
    folderPath,
    assetRevision,
  );
}
