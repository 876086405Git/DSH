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
String publicThemeIdFor(String localId) => isUserThemeId(localId) ? localId.substring(userThemePrefix.length) : localId;

final _themeIdPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final _hexColorPattern = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');
final _assetNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$');

bool isValidThemeId(Object? value) => value is String && value.length <= 40 && _themeIdPattern.hasMatch(value);

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

enum ThemeBackdropPattern { none, dots, grid, lines, diagonal, grain }

enum ThemeGlowLayout { corners, top, bottom, center }

enum ThemeBackdropAlign { center, top, bottom }

enum ThemeCornerStyle { squircle, round, bevel }

enum ThemeBubbleCorners { uniform, tail, leaf }

enum ThemeHeaderStyle { glass, ghost, outlined, minimal }

enum ThemeHeaderTitleFont { ui, heading, code }

enum ThemeComposerStyle { floatingGlass, solidPaper, outlined }

enum ThemeSendButtonStyle { primary, ink, tonal, outlined }

enum ThemeSendButtonShape { circle, squircle, square }

enum ThemeUserBubbleStyle { soft, outlined, accent, minimal }

enum ThemeAssistantStyle { plain, card, leftRule, quote }

enum ThemeSuggestionCardStyle { glass, paper, outlined, minimal }

enum ThemeCodeBlockStyle { well, outlined, card }

enum ThemeCodeHeaderStyle { bar, plain }

enum ThemeTurnDivider { none, hairline, dashed, dots }

enum ThemeHeadingStyle { plain, accent, underline, marker }

enum ThemeBulletStyle { dot, dash, diamond, arrow, square }

enum ThemeEmptyLayout { centered, editorial, compact }

enum ThemeHeroStyle { whale, badge, customImage, hidden, glyph, seal }

enum ThemeSuggestionsDisplay { expanded, collapsible, grid }

bool _nonBlankText(Object? value, int maxRunes) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.runes.length <= maxRunes &&
    !value.runes.any((r) => r < 32 || (r >= 0xD800 && r <= 0xDFFF));

/// Image formats a pack may bundle. The archive validator also requires each
/// file's header to match its extension.
const themeImageExtensions = ['.png', '.webp', '.gif'];

String? _imageAsset(Object? value, String path) {
  if (value == null) return null;
  if (!isSafeThemeAssetName(value, themeImageExtensions)) {
    throw FormatException('$path must be a local .png, .webp or .gif filename');
  }
  return value as String;
}

/// Short copy a pack supplies itself. Packs only carry zh and en, so every
/// other locale reads zh first.
@immutable
class ThemeLocalizedText {
  const ThemeLocalizedText({this.zh, this.en});

  final String? zh;
  final String? en;

  String? resolve(String? languageCode) => languageCode == 'en' ? (en ?? zh) : (zh ?? en);

  static ThemeLocalizedText? parse(Object? raw, String path, int maxRunes) {
    if (raw == null) return null;
    if (raw is! Map) throw FormatException('$path must be an object');
    for (final key in raw.keys) {
      if (key != 'zh' && key != 'en') throw FormatException('$path.$key is not supported');
    }
    String? text(String key) {
      final v = raw[key];
      if (v == null) return null;
      if (!_nonBlankText(v, maxRunes)) throw FormatException('$path.$key must be non-empty up to $maxRunes chars');
      return v as String;
    }

    final parsed = ThemeLocalizedText(zh: text('zh'), en: text('en'));
    if (parsed.zh == null && parsed.en == null) throw FormatException('$path needs zh or en');
    return parsed;
  }

  Map<String, Object?> toJson() => {if (zh != null) 'zh': zh, if (en != null) 'en': en};

  @override
  bool operator ==(Object other) => other is ThemeLocalizedText && other.zh == zh && other.en == en;

  @override
  int get hashCode => Object.hash(zh, en);
}

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
    this.patternInk,
    this.cardFill,
    this.chromeFill,
    this.sheetFill,
    this.hairline,
    this.textTertiary,
    this.success,
    this.warning,
    this.danger,
    this.info,
    this.syntaxKeyword,
    this.syntaxString,
    this.syntaxNumber,
    this.syntaxComment,
    this.syntaxFunction,
    this.syntaxType,
  });

  ThemeColorOverrides._of(Map<String, int?> t)
    : this(
        backdropTop: t['backdropTop'],
        backdropBottom: t['backdropBottom'],
        glowPrimary: t['glowPrimary'],
        glowSecondary: t['glowSecondary'],
        surface: t['surface'],
        onSurface: t['onSurface'],
        onSurfaceVariant: t['onSurfaceVariant'],
        outline: t['outline'],
        outlineVariant: t['outlineVariant'],
        primary: t['primary'],
        onPrimary: t['onPrimary'],
        primaryContainer: t['primaryContainer'],
        onPrimaryContainer: t['onPrimaryContainer'],
        userBubble: t['userBubble'],
        onUserBubble: t['onUserBubble'],
        assistantBubble: t['assistantBubble'],
        onAssistantBubble: t['onAssistantBubble'],
        codeWellBg: t['codeWellBg'],
        codeWellHeader: t['codeWellHeader'],
        codeWellFg: t['codeWellFg'],
        codeWellBorder: t['codeWellBorder'],
        link: t['link'],
        heading: t['heading'],
        rule: t['rule'],
        userBubbleBorder: t['userBubbleBorder'],
        assistantBorder: t['assistantBorder'],
        composerFill: t['composerFill'],
        composerBorder: t['composerBorder'],
        sendButton: t['sendButton'],
        onSendButton: t['onSendButton'],
        inlineCodeBg: t['inlineCodeBg'],
        inlineCodeFg: t['inlineCodeFg'],
        patternInk: t['patternInk'],
        cardFill: t['cardFill'],
        chromeFill: t['chromeFill'],
        sheetFill: t['sheetFill'],
        hairline: t['hairline'],
        textTertiary: t['textTertiary'],
        success: t['success'],
        warning: t['warning'],
        danger: t['danger'],
        info: t['info'],
        syntaxKeyword: t['syntaxKeyword'],
        syntaxString: t['syntaxString'],
        syntaxNumber: t['syntaxNumber'],
        syntaxComment: t['syntaxComment'],
        syntaxFunction: t['syntaxFunction'],
        syntaxType: t['syntaxType'],
      );

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
  final int? link;
  final int? heading;
  final int? rule;
  final int? userBubbleBorder;
  final int? assistantBorder;
  final int? composerFill;
  final int? composerBorder;
  final int? sendButton;
  final int? onSendButton;
  final int? inlineCodeBg;
  final int? inlineCodeFg;
  final int? patternInk;
  final int? cardFill;
  final int? chromeFill;
  final int? sheetFill;
  final int? hairline;
  final int? textTertiary;
  final int? success;
  final int? warning;
  final int? danger;
  final int? info;
  final int? syntaxKeyword;
  final int? syntaxString;
  final int? syntaxNumber;
  final int? syntaxComment;
  final int? syntaxFunction;
  final int? syntaxType;

  /// Every token's JSON key. [_values] lists the fields in this same order.
  static const List<String> tokenKeys = [
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
    'link',
    'heading',
    'rule',
    'userBubbleBorder',
    'assistantBorder',
    'composerFill',
    'composerBorder',
    'sendButton',
    'onSendButton',
    'inlineCodeBg',
    'inlineCodeFg',
    'patternInk',
    'cardFill',
    'chromeFill',
    'sheetFill',
    'hairline',
    'textTertiary',
    'success',
    'warning',
    'danger',
    'info',
    'syntaxKeyword',
    'syntaxString',
    'syntaxNumber',
    'syntaxComment',
    'syntaxFunction',
    'syntaxType',
  ];

  List<int?> get _values => [
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
    link,
    heading,
    rule,
    userBubbleBorder,
    assistantBorder,
    composerFill,
    composerBorder,
    sendButton,
    onSendButton,
    inlineCodeBg,
    inlineCodeFg,
    patternInk,
    cardFill,
    chromeFill,
    sheetFill,
    hairline,
    textTertiary,
    success,
    warning,
    danger,
    info,
    syntaxKeyword,
    syntaxString,
    syntaxNumber,
    syntaxComment,
    syntaxFunction,
    syntaxType,
  ];

  bool get isEmpty => _values.every((v) => v == null);

  /// The ARGB value of the token with this JSON key, or null when it is unset.
  int? operator [](String key) {
    final index = tokenKeys.indexOf(key);
    return index < 0 ? null : _values[index];
  }

  /// A copy with one token replaced; a null [argb] clears it.
  ThemeColorOverrides withToken(String key, int? argb) {
    assert(tokenKeys.contains(key), '$key is not a color token');
    final values = _values;
    return ThemeColorOverrides._of({for (var i = 0; i < tokenKeys.length; i++) tokenKeys[i]: values[i], key: argb});
  }

  factory ThemeColorOverrides.parse(Object? raw, String path) {
    if (raw == null) return const ThemeColorOverrides();
    if (raw is! Map) throw FormatException('$path must be an object');
    for (final key in raw.keys) {
      if (key is! String || !tokenKeys.contains(key)) {
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

    return ThemeColorOverrides._of({for (final key in tokenKeys) key: color(key)});
  }

  Map<String, Object?> toJson() {
    final values = _values;
    return {
      for (var i = 0; i < tokenKeys.length; i++)
        if (values[i] != null) tokenKeys[i]: formatThemeHexColor(values[i]!),
    };
  }

  @override
  bool operator ==(Object other) => other is ThemeColorOverrides && listEquals(other._values, _values);

  @override
  int get hashCode => Object.hashAll(_values);
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

  /// Nullable fields take a getter so they can be set back to null.
  ThemePaletteSpec copyWith({
    int? seed,
    ValueGetter<int?>? seedDark,
    ValueGetter<double?>? tintHue,
    double? tintChroma,
    double? glowOpacity,
    ThemeColorOverrides? light,
    ThemeColorOverrides? dark,
  }) => ThemePaletteSpec(
    seed: seed ?? this.seed,
    seedDark: seedDark != null ? seedDark() : this.seedDark,
    tintHue: tintHue != null ? tintHue() : this.tintHue,
    tintChroma: tintChroma ?? this.tintChroma,
    glowOpacity: glowOpacity ?? this.glowOpacity,
    light: light ?? this.light,
    dark: dark ?? this.dark,
  );

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
    this.backdropAnimate = true,
    this.backdropBlur = 0.0,
    this.backdropAlign = ThemeBackdropAlign.center,
    this.pattern = ThemeBackdropPattern.none,
    this.patternOpacity = 0.06,
    this.patternScale = 1.0,
    this.glowLayout = ThemeGlowLayout.corners,
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
  final bool backdropAnimate;
  final double backdropBlur;
  final ThemeBackdropAlign backdropAlign;
  final ThemeBackdropPattern pattern;
  final double patternOpacity;
  final double patternScale;
  final ThemeGlowLayout glowLayout;

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
    'backdropAnimate',
    'backdropBlur',
    'backdropAlign',
    'pattern',
    'patternOpacity',
    'patternScale',
    'glowLayout',
  };

  factory ThemeSurfaceSpec.parse(Object? raw) {
    if (raw == null) return const ThemeSurfaceSpec();
    if (raw is! Map) throw const FormatException('surfaces must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('surfaces.$key is not supported');
      }
    }
    T pick<T extends Enum>(String key, List<T> values, T fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      final hit = values.asNameMap()[v];
      if (hit == null) throw FormatException('surfaces.$key is invalid');
      return hit;
    }

    double? bounded(String key, double min, double max) {
      final v = raw[key];
      if (v == null) return null;
      if (v is! num || !v.isFinite || v < min || v > max) {
        throw FormatException('surfaces.$key must be between $min and $max');
      }
      return v.toDouble();
    }

    bool flag(String key, bool fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      if (v is! bool) throw FormatException('surfaces.$key must be a boolean');
      return v;
    }

    return ThemeSurfaceSpec(
      preset: pick('preset', ThemeSurfacePreset.values, ThemeSurfacePreset.glass),
      chromeBlur: bounded('chromeBlur', 0, 40),
      sheetBlur: bounded('sheetBlur', 0, 40),
      cardOpacity: bounded('cardOpacity', 0, 1),
      pillOpacity: bounded('pillOpacity', 0, 1),
      hairlineWidth: bounded('hairlineWidth', 0, 3),
      rimOpacity: bounded('rimOpacity', 0, 1),
      shadowOpacity: bounded('shadowOpacity', 0, 1),
      backdropImage: _imageAsset(raw['backdropImage'], 'surfaces.backdropImage'),
      backdropOpacity: bounded('backdropOpacity', 0, 1) ?? 0.18,
      backdropRepeat: flag('backdropRepeat', false),
      backdropAnimate: flag('backdropAnimate', true),
      backdropBlur: bounded('backdropBlur', 0, 40) ?? 0.0,
      backdropAlign: pick('backdropAlign', ThemeBackdropAlign.values, ThemeBackdropAlign.center),
      pattern: pick('pattern', ThemeBackdropPattern.values, ThemeBackdropPattern.none),
      patternOpacity: bounded('patternOpacity', 0, 1) ?? 0.06,
      patternScale: bounded('patternScale', 0.5, 3) ?? 1.0,
      glowLayout: pick('glowLayout', ThemeGlowLayout.values, ThemeGlowLayout.corners),
    );
  }

  /// Nullable fields take a getter so they can be set back to null.
  ThemeSurfaceSpec copyWith({
    ThemeSurfacePreset? preset,
    ValueGetter<double?>? chromeBlur,
    ValueGetter<double?>? sheetBlur,
    ValueGetter<double?>? cardOpacity,
    ValueGetter<double?>? pillOpacity,
    ValueGetter<double?>? hairlineWidth,
    ValueGetter<double?>? rimOpacity,
    ValueGetter<double?>? shadowOpacity,
    ValueGetter<String?>? backdropImage,
    double? backdropOpacity,
    bool? backdropRepeat,
    bool? backdropAnimate,
    double? backdropBlur,
    ThemeBackdropAlign? backdropAlign,
    ThemeBackdropPattern? pattern,
    double? patternOpacity,
    double? patternScale,
    ThemeGlowLayout? glowLayout,
  }) => ThemeSurfaceSpec(
    preset: preset ?? this.preset,
    chromeBlur: chromeBlur != null ? chromeBlur() : this.chromeBlur,
    sheetBlur: sheetBlur != null ? sheetBlur() : this.sheetBlur,
    cardOpacity: cardOpacity != null ? cardOpacity() : this.cardOpacity,
    pillOpacity: pillOpacity != null ? pillOpacity() : this.pillOpacity,
    hairlineWidth: hairlineWidth != null ? hairlineWidth() : this.hairlineWidth,
    rimOpacity: rimOpacity != null ? rimOpacity() : this.rimOpacity,
    shadowOpacity: shadowOpacity != null ? shadowOpacity() : this.shadowOpacity,
    backdropImage: backdropImage != null ? backdropImage() : this.backdropImage,
    backdropOpacity: backdropOpacity ?? this.backdropOpacity,
    backdropRepeat: backdropRepeat ?? this.backdropRepeat,
    backdropAnimate: backdropAnimate ?? this.backdropAnimate,
    backdropBlur: backdropBlur ?? this.backdropBlur,
    backdropAlign: backdropAlign ?? this.backdropAlign,
    pattern: pattern ?? this.pattern,
    patternOpacity: patternOpacity ?? this.patternOpacity,
    patternScale: patternScale ?? this.patternScale,
    glowLayout: glowLayout ?? this.glowLayout,
  );

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
    if (backdropOpacity != 0.18) 'backdropOpacity': backdropOpacity,
    if (backdropRepeat) 'backdropRepeat': true,
    if (!backdropAnimate) 'backdropAnimate': false,
    if (backdropBlur != 0.0) 'backdropBlur': backdropBlur,
    if (backdropAlign != ThemeBackdropAlign.center) 'backdropAlign': backdropAlign.name,
    if (pattern != ThemeBackdropPattern.none) 'pattern': pattern.name,
    if (patternOpacity != 0.06) 'patternOpacity': patternOpacity,
    if (patternScale != 1.0) 'patternScale': patternScale,
    if (glowLayout != ThemeGlowLayout.corners) 'glowLayout': glowLayout.name,
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
      other.backdropRepeat == backdropRepeat &&
      other.backdropAnimate == backdropAnimate &&
      other.backdropBlur == backdropBlur &&
      other.backdropAlign == backdropAlign &&
      other.pattern == pattern &&
      other.patternOpacity == patternOpacity &&
      other.patternScale == patternScale &&
      other.glowLayout == glowLayout;

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
    backdropAnimate,
    backdropBlur,
    backdropAlign,
    pattern,
    patternOpacity,
    patternScale,
    glowLayout,
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
    this.readingLetterSpacing = 0.0,
    this.headingLetterSpacing = 0.0,
    this.headingWeight,
    this.codeScale = 1.0,
  });

  final String uiFont;
  final String readingFont;
  final String headingFont;
  final String codeFont;
  final double readingScale;
  final double readingLineHeight;
  final double headingScale;
  final double readingLetterSpacing;
  final double headingLetterSpacing;

  /// A FontWeight value (300..900); null keeps each heading's own weight.
  final int? headingWeight;
  final double codeScale;

  static const _keys = {
    'uiFont',
    'readingFont',
    'headingFont',
    'codeFont',
    'readingScale',
    'readingLineHeight',
    'headingScale',
    'readingLetterSpacing',
    'headingLetterSpacing',
    'headingWeight',
    'codeScale',
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

    int? headingWeight;
    final weight = raw['headingWeight'];
    if (weight != null) {
      if (weight is! num || !weight.isFinite || weight < 300 || weight > 900 || weight % 100 != 0) {
        throw const FormatException('typography.headingWeight must be a multiple of 100 between 300 and 900');
      }
      headingWeight = weight.toInt();
    }

    return ThemeTypographySpec(
      uiFont: fontRole('uiFont', 'system'),
      readingFont: fontRole('readingFont', 'system'),
      headingFont: fontRole('headingFont', 'system'),
      codeFont: fontRole('codeFont', 'JetBrainsMono'),
      readingScale: bounded('readingScale', 0.85, 1.25, 1.0),
      readingLineHeight: bounded('readingLineHeight', 1.2, 2.0, 1.55),
      headingScale: bounded('headingScale', 0.85, 1.35, 1.0),
      readingLetterSpacing: bounded('readingLetterSpacing', -0.5, 2.0, 0.0),
      headingLetterSpacing: bounded('headingLetterSpacing', -1.0, 4.0, 0.0),
      headingWeight: headingWeight,
      codeScale: bounded('codeScale', 0.85, 1.2, 1.0),
    );
  }

  /// Nullable fields take a getter so they can be set back to null.
  ThemeTypographySpec copyWith({
    String? uiFont,
    String? readingFont,
    String? headingFont,
    String? codeFont,
    double? readingScale,
    double? readingLineHeight,
    double? headingScale,
    double? readingLetterSpacing,
    double? headingLetterSpacing,
    ValueGetter<int?>? headingWeight,
    double? codeScale,
  }) => ThemeTypographySpec(
    uiFont: uiFont ?? this.uiFont,
    readingFont: readingFont ?? this.readingFont,
    headingFont: headingFont ?? this.headingFont,
    codeFont: codeFont ?? this.codeFont,
    readingScale: readingScale ?? this.readingScale,
    readingLineHeight: readingLineHeight ?? this.readingLineHeight,
    headingScale: headingScale ?? this.headingScale,
    readingLetterSpacing: readingLetterSpacing ?? this.readingLetterSpacing,
    headingLetterSpacing: headingLetterSpacing ?? this.headingLetterSpacing,
    headingWeight: headingWeight != null ? headingWeight() : this.headingWeight,
    codeScale: codeScale ?? this.codeScale,
  );

  Map<String, Object?> toJson() => {
    if (uiFont != 'system') 'uiFont': uiFont,
    if (readingFont != 'system') 'readingFont': readingFont,
    if (headingFont != 'system') 'headingFont': headingFont,
    if (codeFont != 'JetBrainsMono') 'codeFont': codeFont,
    if (readingScale != 1.0) 'readingScale': readingScale,
    if (readingLineHeight != 1.55) 'readingLineHeight': readingLineHeight,
    if (headingScale != 1.0) 'headingScale': headingScale,
    if (readingLetterSpacing != 0.0) 'readingLetterSpacing': readingLetterSpacing,
    if (headingLetterSpacing != 0.0) 'headingLetterSpacing': headingLetterSpacing,
    if (headingWeight != null) 'headingWeight': headingWeight,
    if (codeScale != 1.0) 'codeScale': codeScale,
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
      other.headingScale == headingScale &&
      other.readingLetterSpacing == readingLetterSpacing &&
      other.headingLetterSpacing == headingLetterSpacing &&
      other.headingWeight == headingWeight &&
      other.codeScale == codeScale;

  @override
  int get hashCode => Object.hash(
    uiFont,
    readingFont,
    headingFont,
    codeFont,
    readingScale,
    readingLineHeight,
    headingScale,
    readingLetterSpacing,
    headingLetterSpacing,
    headingWeight,
    codeScale,
  );
}

@immutable
class ThemeShapeSpec {
  const ThemeShapeSpec({
    this.cornerScale = 1.0,
    this.borderWidth = 0.5,
    this.turnGap = 24.0,
    this.inTurnGap = 8.0,
    this.gutter = 16.0,
    this.cornerStyle = ThemeCornerStyle.squircle,
    this.bubbleCorners = ThemeBubbleCorners.uniform,
    this.bubbleRadius,
    this.cardRadius,
    this.codeRadius,
    this.composerRadius,
    this.bubblePadH = 16.0,
    this.bubblePadV = 8.0,
  });

  final double cornerScale;
  final double borderWidth;
  final double turnGap;
  final double inTurnGap;
  final double gutter;
  final ThemeCornerStyle cornerStyle;
  final ThemeBubbleCorners bubbleCorners;

  /// Absolute radii in dp; null derives the radius from [cornerScale].
  final double? bubbleRadius;
  final double? cardRadius;
  final double? codeRadius;
  final double? composerRadius;
  final double bubblePadH;
  final double bubblePadV;

  static const _keys = {
    'cornerScale',
    'borderWidth',
    'turnGap',
    'inTurnGap',
    'gutter',
    'cornerStyle',
    'bubbleCorners',
    'bubbleRadius',
    'cardRadius',
    'codeRadius',
    'composerRadius',
    'bubblePadH',
    'bubblePadV',
  };

  factory ThemeShapeSpec.parse(Object? raw) {
    if (raw == null) return const ThemeShapeSpec();
    if (raw is! Map) throw const FormatException('shapes must be an object');
    for (final key in raw.keys) {
      if (key is! String || !_keys.contains(key)) {
        throw FormatException('shapes.$key is not supported');
      }
    }
    T pick<T extends Enum>(String key, List<T> values, T fallback) {
      final v = raw[key];
      if (v == null) return fallback;
      final hit = values.asNameMap()[v];
      if (hit == null) throw FormatException('shapes.$key is invalid');
      return hit;
    }

    double? bounded(String key, double min, double max) {
      final v = raw[key];
      if (v == null) return null;
      if (v is! num || !v.isFinite || v < min || v > max) {
        throw FormatException('shapes.$key must be between $min and $max');
      }
      return v.toDouble();
    }

    return ThemeShapeSpec(
      cornerScale: bounded('cornerScale', 0.0, 1.6) ?? 1.0,
      borderWidth: bounded('borderWidth', 0.0, 2.5) ?? 0.5,
      turnGap: bounded('turnGap', 12.0, 40.0) ?? 24.0,
      inTurnGap: bounded('inTurnGap', 4.0, 20.0) ?? 8.0,
      gutter: bounded('gutter', 10.0, 28.0) ?? 16.0,
      cornerStyle: pick('cornerStyle', ThemeCornerStyle.values, ThemeCornerStyle.squircle),
      bubbleCorners: pick('bubbleCorners', ThemeBubbleCorners.values, ThemeBubbleCorners.uniform),
      bubbleRadius: bounded('bubbleRadius', 0.0, 36.0),
      cardRadius: bounded('cardRadius', 0.0, 36.0),
      codeRadius: bounded('codeRadius', 0.0, 36.0),
      composerRadius: bounded('composerRadius', 0.0, 36.0),
      bubblePadH: bounded('bubblePadH', 10.0, 24.0) ?? 16.0,
      bubblePadV: bounded('bubblePadV', 6.0, 16.0) ?? 8.0,
    );
  }

  /// Nullable fields take a getter so they can be set back to null.
  ThemeShapeSpec copyWith({
    double? cornerScale,
    double? borderWidth,
    double? turnGap,
    double? inTurnGap,
    double? gutter,
    ThemeCornerStyle? cornerStyle,
    ThemeBubbleCorners? bubbleCorners,
    ValueGetter<double?>? bubbleRadius,
    ValueGetter<double?>? cardRadius,
    ValueGetter<double?>? codeRadius,
    ValueGetter<double?>? composerRadius,
    double? bubblePadH,
    double? bubblePadV,
  }) => ThemeShapeSpec(
    cornerScale: cornerScale ?? this.cornerScale,
    borderWidth: borderWidth ?? this.borderWidth,
    turnGap: turnGap ?? this.turnGap,
    inTurnGap: inTurnGap ?? this.inTurnGap,
    gutter: gutter ?? this.gutter,
    cornerStyle: cornerStyle ?? this.cornerStyle,
    bubbleCorners: bubbleCorners ?? this.bubbleCorners,
    bubbleRadius: bubbleRadius != null ? bubbleRadius() : this.bubbleRadius,
    cardRadius: cardRadius != null ? cardRadius() : this.cardRadius,
    codeRadius: codeRadius != null ? codeRadius() : this.codeRadius,
    composerRadius: composerRadius != null ? composerRadius() : this.composerRadius,
    bubblePadH: bubblePadH ?? this.bubblePadH,
    bubblePadV: bubblePadV ?? this.bubblePadV,
  );

  Map<String, Object?> toJson() => {
    if (cornerScale != 1.0) 'cornerScale': cornerScale,
    if (borderWidth != 0.5) 'borderWidth': borderWidth,
    if (turnGap != 24.0) 'turnGap': turnGap,
    if (inTurnGap != 8.0) 'inTurnGap': inTurnGap,
    if (gutter != 16.0) 'gutter': gutter,
    if (cornerStyle != ThemeCornerStyle.squircle) 'cornerStyle': cornerStyle.name,
    if (bubbleCorners != ThemeBubbleCorners.uniform) 'bubbleCorners': bubbleCorners.name,
    if (bubbleRadius != null) 'bubbleRadius': bubbleRadius,
    if (cardRadius != null) 'cardRadius': cardRadius,
    if (codeRadius != null) 'codeRadius': codeRadius,
    if (composerRadius != null) 'composerRadius': composerRadius,
    if (bubblePadH != 16.0) 'bubblePadH': bubblePadH,
    if (bubblePadV != 8.0) 'bubblePadV': bubblePadV,
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeShapeSpec &&
      other.cornerScale == cornerScale &&
      other.borderWidth == borderWidth &&
      other.turnGap == turnGap &&
      other.inTurnGap == inTurnGap &&
      other.gutter == gutter &&
      other.cornerStyle == cornerStyle &&
      other.bubbleCorners == bubbleCorners &&
      other.bubbleRadius == bubbleRadius &&
      other.cardRadius == cardRadius &&
      other.codeRadius == codeRadius &&
      other.composerRadius == composerRadius &&
      other.bubblePadH == bubblePadH &&
      other.bubblePadV == bubblePadV;

  @override
  int get hashCode => Object.hash(
    cornerScale,
    borderWidth,
    turnGap,
    inTurnGap,
    gutter,
    cornerStyle,
    bubbleCorners,
    bubbleRadius,
    cardRadius,
    codeRadius,
    composerRadius,
    bubblePadH,
    bubblePadV,
  );
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
    this.sendButtonShape = ThemeSendButtonShape.circle,
    this.codeHeaderStyle = ThemeCodeHeaderStyle.bar,
    this.turnDivider = ThemeTurnDivider.none,
    this.headingStyle = ThemeHeadingStyle.plain,
    this.bulletStyle = ThemeBulletStyle.dot,
    this.headerTitleFont = ThemeHeaderTitleFont.ui,
    this.userLabel,
    this.assistantLabel,
    this.assistantAvatar,
    this.userAvatar,
    this.composerHint,
  });

  final ThemeHeaderStyle headerStyle;
  final ThemeComposerStyle composerStyle;
  final ThemeSendButtonStyle sendButtonStyle;
  final ThemeUserBubbleStyle userBubbleStyle;
  final ThemeAssistantStyle assistantStyle;
  final bool useReadingFontForReply;
  final ThemeSuggestionCardStyle suggestionCardStyle;
  final ThemeCodeBlockStyle codeBlockStyle;
  final ThemeSendButtonShape sendButtonShape;
  final ThemeCodeHeaderStyle codeHeaderStyle;
  final ThemeTurnDivider turnDivider;
  final ThemeHeadingStyle headingStyle;
  final ThemeBulletStyle bulletStyle;
  final ThemeHeaderTitleFont headerTitleFont;
  final ThemeLocalizedText? userLabel;
  final ThemeLocalizedText? assistantLabel;
  final String? assistantAvatar;
  final String? userAvatar;
  final ThemeLocalizedText? composerHint;

  static const _keys = {
    'headerStyle',
    'composerStyle',
    'sendButtonStyle',
    'userBubbleStyle',
    'assistantStyle',
    'useReadingFontForReply',
    'suggestionCardStyle',
    'codeBlockStyle',
    'sendButtonShape',
    'codeHeaderStyle',
    'turnDivider',
    'headingStyle',
    'bulletStyle',
    'headerTitleFont',
    'userLabel',
    'assistantLabel',
    'assistantAvatar',
    'userAvatar',
    'composerHint',
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
      sendButtonShape: pick('sendButtonShape', ThemeSendButtonShape.values, ThemeSendButtonShape.circle),
      codeHeaderStyle: pick('codeHeaderStyle', ThemeCodeHeaderStyle.values, ThemeCodeHeaderStyle.bar),
      turnDivider: pick('turnDivider', ThemeTurnDivider.values, ThemeTurnDivider.none),
      headingStyle: pick('headingStyle', ThemeHeadingStyle.values, ThemeHeadingStyle.plain),
      bulletStyle: pick('bulletStyle', ThemeBulletStyle.values, ThemeBulletStyle.dot),
      headerTitleFont: pick('headerTitleFont', ThemeHeaderTitleFont.values, ThemeHeaderTitleFont.ui),
      userLabel: ThemeLocalizedText.parse(raw['userLabel'], 'components.userLabel', 16),
      assistantLabel: ThemeLocalizedText.parse(raw['assistantLabel'], 'components.assistantLabel', 16),
      assistantAvatar: _imageAsset(raw['assistantAvatar'], 'components.assistantAvatar'),
      userAvatar: _imageAsset(raw['userAvatar'], 'components.userAvatar'),
      composerHint: ThemeLocalizedText.parse(raw['composerHint'], 'components.composerHint', 30),
    );
  }

  /// Nullable fields take a getter so they can be set back to null.
  ThemeComponentSpec copyWith({
    ThemeHeaderStyle? headerStyle,
    ThemeComposerStyle? composerStyle,
    ThemeSendButtonStyle? sendButtonStyle,
    ThemeUserBubbleStyle? userBubbleStyle,
    ThemeAssistantStyle? assistantStyle,
    bool? useReadingFontForReply,
    ThemeSuggestionCardStyle? suggestionCardStyle,
    ThemeCodeBlockStyle? codeBlockStyle,
    ThemeSendButtonShape? sendButtonShape,
    ThemeCodeHeaderStyle? codeHeaderStyle,
    ThemeTurnDivider? turnDivider,
    ThemeHeadingStyle? headingStyle,
    ThemeBulletStyle? bulletStyle,
    ThemeHeaderTitleFont? headerTitleFont,
    ValueGetter<ThemeLocalizedText?>? userLabel,
    ValueGetter<ThemeLocalizedText?>? assistantLabel,
    ValueGetter<String?>? assistantAvatar,
    ValueGetter<String?>? userAvatar,
    ValueGetter<ThemeLocalizedText?>? composerHint,
  }) => ThemeComponentSpec(
    headerStyle: headerStyle ?? this.headerStyle,
    composerStyle: composerStyle ?? this.composerStyle,
    sendButtonStyle: sendButtonStyle ?? this.sendButtonStyle,
    userBubbleStyle: userBubbleStyle ?? this.userBubbleStyle,
    assistantStyle: assistantStyle ?? this.assistantStyle,
    useReadingFontForReply: useReadingFontForReply ?? this.useReadingFontForReply,
    suggestionCardStyle: suggestionCardStyle ?? this.suggestionCardStyle,
    codeBlockStyle: codeBlockStyle ?? this.codeBlockStyle,
    sendButtonShape: sendButtonShape ?? this.sendButtonShape,
    codeHeaderStyle: codeHeaderStyle ?? this.codeHeaderStyle,
    turnDivider: turnDivider ?? this.turnDivider,
    headingStyle: headingStyle ?? this.headingStyle,
    bulletStyle: bulletStyle ?? this.bulletStyle,
    headerTitleFont: headerTitleFont ?? this.headerTitleFont,
    userLabel: userLabel != null ? userLabel() : this.userLabel,
    assistantLabel: assistantLabel != null ? assistantLabel() : this.assistantLabel,
    assistantAvatar: assistantAvatar != null ? assistantAvatar() : this.assistantAvatar,
    userAvatar: userAvatar != null ? userAvatar() : this.userAvatar,
    composerHint: composerHint != null ? composerHint() : this.composerHint,
  );

  Map<String, Object?> toJson() => {
    if (headerStyle != ThemeHeaderStyle.glass) 'headerStyle': headerStyle.name,
    if (composerStyle != ThemeComposerStyle.floatingGlass) 'composerStyle': composerStyle.name,
    if (sendButtonStyle != ThemeSendButtonStyle.primary) 'sendButtonStyle': sendButtonStyle.name,
    if (userBubbleStyle != ThemeUserBubbleStyle.soft) 'userBubbleStyle': userBubbleStyle.name,
    if (assistantStyle != ThemeAssistantStyle.plain) 'assistantStyle': assistantStyle.name,
    if (useReadingFontForReply) 'useReadingFontForReply': true,
    if (suggestionCardStyle != ThemeSuggestionCardStyle.glass) 'suggestionCardStyle': suggestionCardStyle.name,
    if (codeBlockStyle != ThemeCodeBlockStyle.well) 'codeBlockStyle': codeBlockStyle.name,
    if (sendButtonShape != ThemeSendButtonShape.circle) 'sendButtonShape': sendButtonShape.name,
    if (codeHeaderStyle != ThemeCodeHeaderStyle.bar) 'codeHeaderStyle': codeHeaderStyle.name,
    if (turnDivider != ThemeTurnDivider.none) 'turnDivider': turnDivider.name,
    if (headingStyle != ThemeHeadingStyle.plain) 'headingStyle': headingStyle.name,
    if (bulletStyle != ThemeBulletStyle.dot) 'bulletStyle': bulletStyle.name,
    if (headerTitleFont != ThemeHeaderTitleFont.ui) 'headerTitleFont': headerTitleFont.name,
    if (userLabel != null) 'userLabel': userLabel!.toJson(),
    if (assistantLabel != null) 'assistantLabel': assistantLabel!.toJson(),
    if (assistantAvatar != null) 'assistantAvatar': assistantAvatar,
    if (userAvatar != null) 'userAvatar': userAvatar,
    if (composerHint != null) 'composerHint': composerHint!.toJson(),
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
      other.codeBlockStyle == codeBlockStyle &&
      other.sendButtonShape == sendButtonShape &&
      other.codeHeaderStyle == codeHeaderStyle &&
      other.turnDivider == turnDivider &&
      other.headingStyle == headingStyle &&
      other.bulletStyle == bulletStyle &&
      other.headerTitleFont == headerTitleFont &&
      other.userLabel == userLabel &&
      other.assistantLabel == assistantLabel &&
      other.assistantAvatar == assistantAvatar &&
      other.userAvatar == userAvatar &&
      other.composerHint == composerHint;

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
    sendButtonShape,
    codeHeaderStyle,
    turnDivider,
    headingStyle,
    bulletStyle,
    headerTitleFont,
    userLabel,
    assistantLabel,
    assistantAvatar,
    userAvatar,
    composerHint,
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
    this.heroGlyph,
    this.heroScale = 1.0,
    this.greeting,
    this.subtitle,
  });

  final ThemeEmptyLayout layout;
  final ThemeHeroStyle heroStyle;
  final String? heroImage;
  final bool useReadingFontForGreeting;
  final bool showConnectedSubtitle;
  final ThemeSuggestionsDisplay suggestionsDisplay;

  /// The 1 to 4 characters drawn by the glyph and seal hero styles.
  final String? heroGlyph;
  final double heroScale;
  final ThemeLocalizedText? greeting;
  final ThemeLocalizedText? subtitle;

  static const _keys = {
    'layout',
    'heroStyle',
    'heroImage',
    'useReadingFontForGreeting',
    'showConnectedSubtitle',
    'suggestionsDisplay',
    'heroGlyph',
    'heroScale',
    'greeting',
    'subtitle',
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

    final heroImage = _imageAsset(raw['heroImage'], 'emptyState.heroImage');
    final useReading = raw['useReadingFontForGreeting'];
    if (useReading != null && useReading is! bool) {
      throw const FormatException('emptyState.useReadingFontForGreeting must be a boolean');
    }
    final showSubtitle = raw['showConnectedSubtitle'];
    if (showSubtitle != null && showSubtitle is! bool) {
      throw const FormatException('emptyState.showConnectedSubtitle must be a boolean');
    }
    String? heroGlyph;
    if (raw['heroGlyph'] != null) {
      if (!_nonBlankText(raw['heroGlyph'], 4)) {
        throw const FormatException('emptyState.heroGlyph must be 1 to 4 characters');
      }
      heroGlyph = raw['heroGlyph'] as String;
    }
    var heroScale = 1.0;
    if (raw['heroScale'] != null) {
      final v = raw['heroScale'];
      if (v is! num || !v.isFinite || v < 0.6 || v > 2.0) {
        throw const FormatException('emptyState.heroScale must be between 0.6 and 2.0');
      }
      heroScale = v.toDouble();
    }

    final heroStyle = pick('heroStyle', ThemeHeroStyle.values, ThemeHeroStyle.whale);
    if (heroStyle == ThemeHeroStyle.customImage && heroImage == null) {
      throw const FormatException('emptyState.heroImage is required when heroStyle is customImage');
    }
    if ((heroStyle == ThemeHeroStyle.glyph || heroStyle == ThemeHeroStyle.seal) && heroGlyph == null) {
      throw const FormatException('emptyState.heroGlyph is required when heroStyle is glyph or seal');
    }

    return ThemeEmptyStateSpec(
      layout: pick('layout', ThemeEmptyLayout.values, ThemeEmptyLayout.centered),
      heroStyle: heroStyle,
      heroImage: heroImage,
      useReadingFontForGreeting: (useReading as bool?) ?? false,
      showConnectedSubtitle: (showSubtitle as bool?) ?? true,
      suggestionsDisplay: pick('suggestionsDisplay', ThemeSuggestionsDisplay.values, ThemeSuggestionsDisplay.expanded),
      heroGlyph: heroGlyph,
      heroScale: heroScale,
      greeting: ThemeLocalizedText.parse(raw['greeting'], 'emptyState.greeting', 40),
      subtitle: ThemeLocalizedText.parse(raw['subtitle'], 'emptyState.subtitle', 60),
    );
  }

  /// Nullable fields take a getter so they can be set back to null.
  ThemeEmptyStateSpec copyWith({
    ThemeEmptyLayout? layout,
    ThemeHeroStyle? heroStyle,
    ValueGetter<String?>? heroImage,
    bool? useReadingFontForGreeting,
    bool? showConnectedSubtitle,
    ThemeSuggestionsDisplay? suggestionsDisplay,
    ValueGetter<String?>? heroGlyph,
    double? heroScale,
    ValueGetter<ThemeLocalizedText?>? greeting,
    ValueGetter<ThemeLocalizedText?>? subtitle,
  }) => ThemeEmptyStateSpec(
    layout: layout ?? this.layout,
    heroStyle: heroStyle ?? this.heroStyle,
    heroImage: heroImage != null ? heroImage() : this.heroImage,
    useReadingFontForGreeting: useReadingFontForGreeting ?? this.useReadingFontForGreeting,
    showConnectedSubtitle: showConnectedSubtitle ?? this.showConnectedSubtitle,
    suggestionsDisplay: suggestionsDisplay ?? this.suggestionsDisplay,
    heroGlyph: heroGlyph != null ? heroGlyph() : this.heroGlyph,
    heroScale: heroScale ?? this.heroScale,
    greeting: greeting != null ? greeting() : this.greeting,
    subtitle: subtitle != null ? subtitle() : this.subtitle,
  );

  Map<String, Object?> toJson() => {
    if (layout != ThemeEmptyLayout.centered) 'layout': layout.name,
    if (heroStyle != ThemeHeroStyle.whale) 'heroStyle': heroStyle.name,
    if (heroImage != null) 'heroImage': heroImage,
    if (useReadingFontForGreeting) 'useReadingFontForGreeting': true,
    if (!showConnectedSubtitle) 'showConnectedSubtitle': false,
    if (suggestionsDisplay != ThemeSuggestionsDisplay.expanded) 'suggestionsDisplay': suggestionsDisplay.name,
    if (heroGlyph != null) 'heroGlyph': heroGlyph,
    if (heroScale != 1.0) 'heroScale': heroScale,
    if (greeting != null) 'greeting': greeting!.toJson(),
    if (subtitle != null) 'subtitle': subtitle!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ThemeEmptyStateSpec &&
      other.layout == layout &&
      other.heroStyle == heroStyle &&
      other.heroImage == heroImage &&
      other.useReadingFontForGreeting == useReadingFontForGreeting &&
      other.showConnectedSubtitle == showConnectedSubtitle &&
      other.suggestionsDisplay == suggestionsDisplay &&
      other.heroGlyph == heroGlyph &&
      other.heroScale == heroScale &&
      other.greeting == greeting &&
      other.subtitle == subtitle;

  @override
  int get hashCode => Object.hash(
    layout,
    heroStyle,
    heroImage,
    useReadingFontForGreeting,
    showConnectedSubtitle,
    suggestionsDisplay,
    heroGlyph,
    heroScale,
    greeting,
    subtitle,
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
    if (components.assistantAvatar != null) components.assistantAvatar!,
    if (components.userAvatar != null) components.userAvatar!,
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
    'extends',
  };

  static const _sectionKeys = ['palette', 'surfaces', 'typography', 'shapes', 'components', 'emptyState'];

  /// Lays [over] on top of [base]: maps merge key by key, anything else
  /// replaces, and a null value drops the key so it falls back to its default.
  /// A two-language text replaces as a whole: a theme that writes only its
  /// Chinese label should not keep the parent's English one.
  static Object? _mergeJson(Object? base, Object? over) {
    if (base is! Map || over is! Map) return over;
    if (over.isNotEmpty && over.keys.every((key) => key == 'zh' || key == 'en')) return over;
    final merged = <Object?, Object?>{...base};
    for (final entry in over.entries) {
      if (entry.value == null) {
        merged.remove(entry.key);
      } else {
        merged[entry.key] = _mergeJson(merged[entry.key], entry.value);
      }
    }
    return merged;
  }

  /// Flattens `extends` so a parsed pack never depends on which built-ins the
  /// reading app (or the Workshop) ships. Only the look is inherited, never
  /// the built-in's id, name or other metadata.
  static Map<String, Object?> _resolveExtends(Map<String, Object?> raw) {
    final parent = raw['extends'];
    final base = parent is String ? builtInById(parent)?.toJson() : null;
    if (base == null) throw const FormatException('theme.json extends must name a built-in theme');
    final sections = _mergeJson(
      {
        for (final key in _sectionKeys)
          if (base[key] != null) key: base[key],
      },
      {
        for (final key in _sectionKeys)
          if (raw.containsKey(key)) key: raw[key],
      },
    ) as Map;
    return {
      for (final entry in raw.entries)
        if (entry.key != 'extends' && !_sectionKeys.contains(entry.key)) entry.key: entry.value,
      for (final entry in sections.entries) entry.key as String: entry.value,
    };
  }

  factory ThemePack.parse(Map<String, Object?> input, {String? folderPath}) {
    for (final key in input.keys) {
      if (!_topKeys.contains(key)) {
        throw FormatException('Unknown theme.json field: $key');
      }
    }
    final raw = input['extends'] == null ? input : _resolveExtends(input);
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
      'title': {if (titleZh != null) 'zh': titleZh, if (titleEn != null) 'en': titleEn},
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
    description: '宣纸的细颗粒、朱砂印章、宋体长文和书页间的三点分隔。',
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
        userBubble: 0xFFEAE3D4,
        onUserBubble: 0xFF1F1E1B,
        codeWellBg: 0xFFEFEBE1,
        codeWellHeader: 0xFFE7E1D4,
        codeWellFg: 0xFF24211C,
        codeWellBorder: 0xFFD9D1C2,
        inlineCodeBg: 0xFFEDE6D8,
        inlineCodeFg: 0xFF873927,
        syntaxKeyword: 0xFFA14732,
        syntaxString: 0xFF5F6F32,
        syntaxNumber: 0xFF96611A,
        syntaxComment: 0xFF968D7C,
        syntaxFunction: 0xFF2F4F6F,
        syntaxType: 0xFF7A4A63,
        patternInk: 0xFF5A4A3A,
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
        inlineCodeBg: 0xFF2A2521,
        inlineCodeFg: 0xFFE4A58C,
        syntaxKeyword: 0xFFE4A58C,
        syntaxString: 0xFFB5C28A,
        syntaxNumber: 0xFFE0B872,
        syntaxComment: 0xFF7F776B,
        syntaxFunction: 0xFF9DB8D2,
        syntaxType: 0xFFCFA6C0,
        patternInk: 0xFFE8DCC8,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.paper,
      hairlineWidth: 1.0,
      pattern: ThemeBackdropPattern.grain,
      patternOpacity: 0.05,
    ),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      headingFont: 'serif',
      readingLineHeight: 1.72,
      readingLetterSpacing: 0.2,
      headingScale: 1.12,
      headingLetterSpacing: 0.6,
      headingWeight: 600,
    ),
    shapes: ThemeShapeSpec(cornerScale: 0.7, borderWidth: 1.0, turnGap: 30.0),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.ghost,
      composerStyle: ThemeComposerStyle.solidPaper,
      sendButtonStyle: ThemeSendButtonStyle.ink,
      sendButtonShape: ThemeSendButtonShape.squircle,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.plain,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.outlined,
      codeHeaderStyle: ThemeCodeHeaderStyle.plain,
      turnDivider: ThemeTurnDivider.dots,
      headingStyle: ThemeHeadingStyle.underline,
      headerTitleFont: ThemeHeaderTitleFont.heading,
      composerHint: ThemeLocalizedText(zh: '落笔…', en: 'Write…'),
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.seal,
      heroGlyph: '墨',
      useReadingFontForGreeting: true,
      showConnectedSubtitle: false,
      greeting: ThemeLocalizedText(zh: '见字如面', en: 'Pen to paper'),
      suggestionsDisplay: ThemeSuggestionsDisplay.expanded,
    ),
  );

  static const bambooCeladon = ThemePack(
    id: 'bamboo-celadon',
    name: '竹韵青瓷',
    titleZh: '竹韵青瓷',
    titleEn: 'Bamboo Celadon',
    description: '一汪釉色从页面上方晕开，竹叶形的气泡，回复沿着一根青色的竹节往下写。',
    tags: ['国风', '青瓷', '雅致'],
    palette: ThemePaletteSpec(
      seed: 0xFF2B6A58,
      seedDark: 0xFF7FC7B0,
      tintHue: 162,
      tintChroma: 0.42,
      glowOpacity: 0.6,
      light: ThemeColorOverrides(
        backdropTop: 0xFFEEF5F1,
        backdropBottom: 0xFFF8FAF7,
        glowPrimary: 0xFFA5D6C5,
        glowSecondary: 0xFFCDE3E8,
        userBubble: 0xFFD9EAE2,
        onUserBubble: 0xFF14322A,
        userBubbleBorder: 0xFFB9D6CA,
        rule: 0xFF4E9A82,
        codeWellBg: 0xFFE9F0EC,
        codeWellHeader: 0xFFDFEAE4,
        codeWellBorder: 0xFFC9DBD2,
        inlineCodeBg: 0xFFE2EEE8,
        inlineCodeFg: 0xFF1F5445,
        syntaxKeyword: 0xFF1F6B57,
        syntaxString: 0xFF8A6A2A,
        syntaxNumber: 0xFF9A5B3A,
        syntaxComment: 0xFF8A9A92,
        syntaxFunction: 0xFF2A5F86,
        syntaxType: 0xFF4F5F9A,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF121A17,
        backdropBottom: 0xFF17201C,
        glowPrimary: 0xFF2E6B58,
        glowSecondary: 0xFF2A4E59,
        userBubble: 0xFF21332C,
        onUserBubble: 0xFFE4EFEA,
        userBubbleBorder: 0xFF345247,
        rule: 0xFF7FC7B0,
        codeWellBg: 0xFF1A2521,
        codeWellHeader: 0xFF202E29,
        codeWellBorder: 0xFF2E423B,
        inlineCodeBg: 0xFF1F2E29,
        inlineCodeFg: 0xFF9AD6C2,
        syntaxKeyword: 0xFF7FC7B0,
        syntaxString: 0xFFD9C48A,
        syntaxNumber: 0xFFE0A583,
        syntaxComment: 0xFF6E8279,
        syntaxFunction: 0xFF8FBDE0,
        syntaxType: 0xFFA9B4E6,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.glass,
      chromeBlur: 14.0,
      cardOpacity: 0.72,
      hairlineWidth: 0.8,
      glowLayout: ThemeGlowLayout.center,
    ),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      headingFont: 'serif',
      readingLineHeight: 1.66,
      readingLetterSpacing: 0.1,
      headingScale: 1.08,
      headingLetterSpacing: 1.0,
    ),
    shapes: ThemeShapeSpec(cornerScale: 1.05, borderWidth: 0.8, turnGap: 26.0, bubbleCorners: ThemeBubbleCorners.leaf),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.glass,
      composerStyle: ThemeComposerStyle.floatingGlass,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      userBubbleStyle: ThemeUserBubbleStyle.outlined,
      assistantStyle: ThemeAssistantStyle.leftRule,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.well,
      headingStyle: ThemeHeadingStyle.marker,
      bulletStyle: ThemeBulletStyle.diamond,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.glyph,
      heroGlyph: '竹',
      heroScale: 1.1,
      useReadingFontForGreeting: true,
      showConnectedSubtitle: true,
      greeting: ThemeLocalizedText(zh: '清风徐来', en: 'A quiet breeze'),
      subtitle: ThemeLocalizedText(zh: '慢慢说，不着急', en: 'Take your time'),
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const terminalNoir = ThemePack(
    id: 'terminal-noir',
    name: '极夜终端',
    titleZh: '极夜终端',
    titleEn: 'Terminal Noir',
    description: '切角线框、淡淡的坐标网格、全等宽排版，每句话前面带一个提示符。',
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
        heading: 0xFF0D736A,
        codeWellBg: 0xFFE7ECEB,
        codeWellHeader: 0xFFDBE3E1,
        codeWellBorder: 0xFFC2CFCC,
        inlineCodeBg: 0xFFDFE9E7,
        inlineCodeFg: 0xFF0B5F58,
        syntaxKeyword: 0xFF0D736A,
        syntaxString: 0xFF8A5A00,
        syntaxNumber: 0xFFB0483A,
        syntaxComment: 0xFF8B9997,
        syntaxFunction: 0xFF1F5FA8,
        syntaxType: 0xFF6A4FB0,
        patternInk: 0xFF0D736A,
      ),
      dark: ThemeColorOverrides(
        backdropTop: 0xFF0C1113,
        backdropBottom: 0xFF10161A,
        surface: 0xFF0C1113,
        onSurface: 0xFFE2ECEB,
        outlineVariant: 0xFF253338,
        userBubble: 0xFF142326,
        onUserBubble: 0xFFD9F3EE,
        heading: 0xFF2DD4BF,
        link: 0xFF5EEAD4,
        codeWellBg: 0xFF11181B,
        codeWellHeader: 0xFF182125,
        codeWellFg: 0xFFDCEBE9,
        codeWellBorder: 0xFF27373D,
        inlineCodeBg: 0xFF15242A,
        inlineCodeFg: 0xFF5EEAD4,
        syntaxKeyword: 0xFF2DD4BF,
        syntaxString: 0xFFFACC6B,
        syntaxNumber: 0xFFF59E8B,
        syntaxComment: 0xFF5F7378,
        syntaxFunction: 0xFF7CC4FA,
        syntaxType: 0xFFC4A7F5,
        patternInk: 0xFF2DD4BF,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.outlined,
      hairlineWidth: 1.0,
      pattern: ThemeBackdropPattern.grid,
      patternOpacity: 0.05,
    ),
    typography: ThemeTypographySpec(uiFont: 'mono', readingFont: 'mono', headingFont: 'mono', readingLineHeight: 1.5),
    shapes: ThemeShapeSpec(
      cornerScale: 0.5,
      cornerStyle: ThemeCornerStyle.bevel,
      bubbleRadius: 10.0,
      cardRadius: 10.0,
      codeRadius: 8.0,
      composerRadius: 12.0,
      borderWidth: 1.0,
      turnGap: 20.0,
      inTurnGap: 6.0,
      gutter: 14.0,
    ),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.outlined,
      composerStyle: ThemeComposerStyle.outlined,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      sendButtonShape: ThemeSendButtonShape.square,
      userBubbleStyle: ThemeUserBubbleStyle.outlined,
      assistantStyle: ThemeAssistantStyle.leftRule,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.outlined,
      codeBlockStyle: ThemeCodeBlockStyle.outlined,
      codeHeaderStyle: ThemeCodeHeaderStyle.plain,
      turnDivider: ThemeTurnDivider.dashed,
      headingStyle: ThemeHeadingStyle.accent,
      bulletStyle: ThemeBulletStyle.dash,
      headerTitleFont: ThemeHeaderTitleFont.code,
      userLabel: ThemeLocalizedText(en: 'you \$'),
      assistantLabel: ThemeLocalizedText(en: 'dsh >'),
      composerHint: ThemeLocalizedText(zh: '输入点什么…', en: 'type something…'),
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.glyph,
      heroGlyph: '>_',
      greeting: ThemeLocalizedText(zh: '就绪', en: 'Ready'),
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const sakuraCard = ThemePack(
    id: 'sakura-card',
    name: '落樱手账',
    titleZh: '落樱手账',
    titleEn: 'Sakura Journal',
    description: '手账的点阵纸、带小尾巴的气泡，每条回复是一张贴上去的便签。',
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
        assistantBorder: 0xFFF1D3DF,
        codeWellBg: 0xFFFBF1F5,
        codeWellHeader: 0xFFF6E4EC,
        codeWellBorder: 0xFFEFD3DE,
        inlineCodeBg: 0xFFF8E6EE,
        inlineCodeFg: 0xFF8E3F5C,
        syntaxKeyword: 0xFFB85A7C,
        syntaxString: 0xFF7A6FB0,
        syntaxNumber: 0xFFB0704A,
        syntaxComment: 0xFFA898A0,
        syntaxFunction: 0xFF4F7FA8,
        syntaxType: 0xFF8A5FA8,
        patternInk: 0xFFB85A7C,
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
        assistantBorder: 0xFF41303A,
        codeWellBg: 0xFF2A1F25,
        codeWellHeader: 0xFF33262D,
        codeWellBorder: 0xFF46333C,
        inlineCodeBg: 0xFF33252C,
        inlineCodeFg: 0xFFF2A7C3,
        syntaxKeyword: 0xFFF2A7C3,
        syntaxString: 0xFFC3B6F2,
        syntaxNumber: 0xFFF0B894,
        syntaxComment: 0xFF8A7780,
        syntaxFunction: 0xFF9CC6EA,
        syntaxType: 0xFFD4A9E8,
        patternInk: 0xFFF2A7C3,
      ),
    ),
    surfaces: ThemeSurfaceSpec(
      preset: ThemeSurfacePreset.glass,
      cardOpacity: 0.78,
      shadowOpacity: 0.5,
      pattern: ThemeBackdropPattern.dots,
      patternOpacity: 0.12,
      patternScale: 0.8,
    ),
    typography: ThemeTypographySpec(readingLineHeight: 1.6),
    shapes: ThemeShapeSpec(cornerScale: 1.32, borderWidth: 0.6, turnGap: 24.0, bubbleCorners: ThemeBubbleCorners.tail),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.glass,
      composerStyle: ThemeComposerStyle.floatingGlass,
      sendButtonStyle: ThemeSendButtonStyle.primary,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.card,
      suggestionCardStyle: ThemeSuggestionCardStyle.glass,
      codeBlockStyle: ThemeCodeBlockStyle.card,
      headingStyle: ThemeHeadingStyle.marker,
      composerHint: ThemeLocalizedText(zh: '写点什么…', en: 'Write something…'),
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.centered,
      heroStyle: ThemeHeroStyle.whale,
      heroScale: 1.15,
      subtitle: ThemeLocalizedText(zh: '今天想记点什么？', en: 'What would you like to note down?'),
      suggestionsDisplay: ThemeSuggestionsDisplay.grid,
    ),
  );

  static const amberCafe = ThemePack(
    id: 'amber-cafe',
    name: '琥珀咖啡馆',
    titleZh: '琥珀咖啡馆',
    titleEn: 'Amber Café',
    description: '头顶一盏暖灯，燕麦色的实面，回复像写在杯垫上的一段话。',
    tags: ['暖调', '舒适', '卡片'],
    palette: ThemePaletteSpec(
      seed: 0xFF9A5B1F,
      seedDark: 0xFFE8B272,
      tintHue: 52,
      tintChroma: 0.45,
      glowOpacity: 0.6,
      light: ThemeColorOverrides(
        backdropTop: 0xFFFBF6EE,
        backdropBottom: 0xFFF4EBDC,
        glowPrimary: 0xFFF0CFA6,
        glowSecondary: 0xFFEADBC4,
        userBubble: 0xFFF0E2CC,
        onUserBubble: 0xFF2C1E12,
        assistantBubble: 0xFFFFFBF4,
        onAssistantBubble: 0xFF271D15,
        assistantBorder: 0xFFE6D8C0,
        rule: 0xFFC98A3C,
        codeWellBg: 0xFFF2E9DA,
        codeWellHeader: 0xFFE9DEC9,
        codeWellBorder: 0xFFDDD0B8,
        inlineCodeBg: 0xFFF0E4D0,
        inlineCodeFg: 0xFF7A4514,
        syntaxKeyword: 0xFF9A5B1F,
        syntaxString: 0xFF5E7039,
        syntaxNumber: 0xFFA8432E,
        syntaxComment: 0xFF9A8E7C,
        syntaxFunction: 0xFF3E5F7A,
        syntaxType: 0xFF7A4A63,
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
        assistantBorder: 0xFF3A2E23,
        rule: 0xFFE8B272,
        codeWellBg: 0xFF221B15,
        codeWellHeader: 0xFF2B221A,
        codeWellBorder: 0xFF3E3227,
        inlineCodeBg: 0xFF2B2119,
        inlineCodeFg: 0xFFE8B272,
        syntaxKeyword: 0xFFE8B272,
        syntaxString: 0xFFB9C78E,
        syntaxNumber: 0xFFE89A7C,
        syntaxComment: 0xFF857868,
        syntaxFunction: 0xFF9FBAD0,
        syntaxType: 0xFFD2A8C2,
      ),
    ),
    surfaces: ThemeSurfaceSpec(preset: ThemeSurfacePreset.flat, hairlineWidth: 0.8, glowLayout: ThemeGlowLayout.top),
    typography: ThemeTypographySpec(
      readingFont: 'serif',
      headingFont: 'serif',
      readingLineHeight: 1.64,
      headingWeight: 700,
    ),
    shapes: ThemeShapeSpec(cornerScale: 1.1, borderWidth: 0.8, turnGap: 24.0),
    components: ThemeComponentSpec(
      headerStyle: ThemeHeaderStyle.minimal,
      composerStyle: ThemeComposerStyle.solidPaper,
      sendButtonStyle: ThemeSendButtonStyle.tonal,
      sendButtonShape: ThemeSendButtonShape.squircle,
      userBubbleStyle: ThemeUserBubbleStyle.soft,
      assistantStyle: ThemeAssistantStyle.quote,
      useReadingFontForReply: true,
      suggestionCardStyle: ThemeSuggestionCardStyle.paper,
      codeBlockStyle: ThemeCodeBlockStyle.well,
      turnDivider: ThemeTurnDivider.hairline,
      headingStyle: ThemeHeadingStyle.underline,
    ),
    emptyState: ThemeEmptyStateSpec(
      layout: ThemeEmptyLayout.compact,
      heroStyle: ThemeHeroStyle.badge,
      heroScale: 1.1,
      useReadingFontForGreeting: true,
      showConnectedSubtitle: true,
      greeting: ThemeLocalizedText(zh: '坐一会儿，慢慢聊', en: 'Stay a while'),
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
