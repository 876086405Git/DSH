// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../themes/theme_pack.dart';
import 'oklch.dart';
import 'palette.dart';

/// 一套配色:强调色的浅深两套色阶,加上中性色(页面、玻璃、文字)往哪个
/// 色调上染。枚举不了的(自定义、跟随壁纸)由 [AppAccent.derive] 现推。
///
/// ## 推导规则(OKLCH,所有色相同一把尺子)
///
/// DeepSeek 品牌蓝 `#4D6BFE` 是 OKLCH(0.59, 0.22, 270):饱和度几乎顶格,
/// 大面积看久了刺眼。默认 [mist] 保留它的色相(267°),彩度压到 0.125,
/// 明度 0.53,白字 5.39。其余每套只换色相和彩度,明度沿用:
///
/// | 角色 | 明度 L | 彩度(× 强调彩度) |
/// |---|---|---|
/// | seed / pressed | 0.53 / 0.47 | 1 / 0.95 |
/// | container / onContainer | 0.93 / 0.33 | 0.26 / 0.70 |
/// | bubble / glow | 0.918 / 0.819 | 0.29 / 0.68 |
/// | seedDark / pressedDark | 0.764 / 0.704 | 0.76 |
/// | onSeedDark | 0.231 | 0.39 |
/// | containerDark / onContainerDark | 0.361 / 0.909 | 0.51 / 0.24 |
/// | bubbleDark / glowDark | 0.314 / 0.52 | 0.29 / 0.72 |
///
/// - 浅色主色上用白字(≥ 4.5),深色主色上用同色相的深墨字(≥ 7)。
/// - 中性色:雾蓝那条中性色阶原样转到 [tintHue],彩度乘 [tintChroma]
///   (见 `NeutralTones`)。明度不动,所以各级文字的对比度不随配色变。
/// - [haze]:页面左下角那团光,配主色的邻近色,给玻璃一点可透的颜色。
///
/// 每套预设都在 `test/theme/palette_contrast_test.dart` 里逐条验对比度。
@immutable
class AppAccent {
  const AppAccent({
    required this.id,
    this._label,
    required this.seed,
    required this.pressed,
    required this.container,
    required this.onContainer,
    required this.bubble,
    required this.glow,
    required this.seedDark,
    required this.pressedDark,
    required this.onSeedDark,
    required this.containerDark,
    required this.onContainerDark,
    required this.bubbleDark,
    required this.glowDark,
    required this.tintHue,
    required this.tintChroma,
    required this.haze,
    required this.hazeDark,
  });

  /// 持久化键:预设名,或 [customId] / [wallpaperId]。
  final String id;

  /// 设置页展示名。
  final String? _label;

  String get label =>
      _label ??
      switch (id) {
        'mist' => appL10n.phoneAccentMist,
        'daiqing' => appL10n.phoneAccentDaiqing,
        'dusk' => appL10n.phoneAccentDusk,
        'turquoise' => appL10n.phoneAccentTurquoise,
        'amber' => appL10n.phoneAccentAmber,
        'graphite' => appL10n.phoneAccentGraphite,
        _ => appL10n.phoneAccentCustom,
      };

  /// 浅色主色(色板上显示的颜色)。白字 ≥ 4.5。
  final Color seed;

  /// 浅色按下态。
  final Color pressed;

  /// 浅色:强调容器 / 其上前景(≥ 7)。
  final Color container;
  final Color onContainer;

  /// 浅色用户气泡:比页面深一档(OKLCH L 0.918),像轻轻按进纸里的一块。
  /// 气泡里只用主文字 / 次级文字(≥ 5.8),三级文字和主色在这里不过 AA。
  final Color bubble;

  /// 浅色背景光晕(使用时再乘透明度)。
  final Color glow;

  /// 深色主色:提亮版,配 [onSeedDark] 深墨字。
  final Color seedDark;
  final Color pressedDark;
  final Color onSeedDark;
  final Color containerDark;
  final Color onContainerDark;
  final Color bubbleDark;
  final Color glowDark;

  /// 中性色转到的色相(度)。雾蓝的中性色在 [NeutralTones.baseHue]。
  final double tintHue;

  /// 中性色的彩度倍数(雾蓝 = 1;石墨接近 0)。
  final double tintChroma;

  /// 左下角光晕(浅 / 深;使用时再乘透明度)。
  final Color haze;
  final Color hazeDark;

  /// 浅色主色上的文字。所有配色都是白字。
  Color get onSeed => const Color(0xFFFFFFFF);

  /// 按亮度取主色。
  Color seedFor(Brightness brightness) => brightness == Brightness.dark ? seedDark : seed;

  // ══ 预设 ══════════════════════════════════════════════════════════════

  /// 默认:雾蓝。DeepSeek 色相,低彩度。
  static const mist = AppAccent(
    id: 'mist',
    seed: Color(0xFF4B67B4),
    pressed: Color(0xFF3D569D),
    container: Color(0xFFDEE8FF),
    onContainer: Color(0xFF213262),
    bubble: Color(0xFFD9E4FD),
    glow: Color(0xFFABC3FC),
    seedDark: Color(0xFF97B1F0),
    pressedDark: Color(0xFF859EDC),
    onSeedDark: Color(0xFF121C34),
    containerDark: Color(0xFF2E3C5F),
    onContainerDark: Color(0xFFD8E1F6),
    bubbleDark: Color(0xFF293144),
    glowDark: Color(0xFF51679D),
    tintHue: NeutralTones.baseHue,
    tintChroma: 1,
    haze: Color(0xFFD5CBEB),
    hazeDark: Color(0xFF514765),
  );

  /// 黛青:墨蓝偏青(238°),比雾蓝沉一档(L 0.47),彩度收到 0.085。
  /// 中性色带一点湖青,光晕配长春花蓝。
  static const daiqing = AppAccent(
    id: 'daiqing',
    seed: Color(0xFF236185),
    pressed: Color(0xFF145071),
    container: Color(0xFFDBEAF5),
    onContainer: Color(0xFF123950),
    bubble: Color(0xFFD6E7F3),
    glow: Color(0xFFA2CAE5),
    seedDark: Color(0xFF8CB9D7),
    pressedDark: Color(0xFF79A6C4),
    onSeedDark: Color(0xFF0D1F2B),
    containerDark: Color(0xFF274152),
    onContainerDark: Color(0xFFD5E3ED),
    bubbleDark: Color(0xFF26333C),
    glowDark: Color(0xFF466E88),
    tintHue: 238,
    tintChroma: 0.9,
    haze: Color(0xFFC7D0EC),
    hazeDark: Color(0xFF444C66),
  );

  /// 暮紫:灰调薰衣草(300°,彩度 0.075)。光晕配一点灰玫瑰。
  static const dusk = AppAccent(
    id: 'dusk',
    seed: Color(0xFF726291),
    pressed: Color(0xFF61517D),
    container: Color(0xFFEAE5F4),
    onContainer: Color(0xFF392F4C),
    bubble: Color(0xFFE6E1F1),
    glow: Color(0xFFC8BDE1),
    seedDark: Color(0xFFB8ABD2),
    pressedDark: Color(0xFFA598BF),
    onSeedDark: Color(0xFF1F1A29),
    containerDark: Color(0xFF40394F),
    onContainerDark: Color(0xFFE2DEEC),
    bubbleDark: Color(0xFF332F3B),
    glowDark: Color(0xFF6D6284),
    tintHue: 295,
    tintChroma: 0.85,
    haze: Color(0xFFE6C7D7),
    hazeDark: Color(0xFF5F4353),
  );

  /// 松石:低饱和青绿(186°,彩度 0.068)。中性色只带三成青,免得发绿发灰;
  /// 光晕配天青。
  static const turquoise = AppAccent(
    id: 'turquoise',
    seed: Color(0xFF34766F),
    pressed: Color(0xFF296760),
    container: Color(0xFFDBECE9),
    onContainer: Color(0xFF123D39),
    bubble: Color(0xFFD6E8E6),
    glow: Color(0xFFA3CEC8),
    seedDark: Color(0xFF8DBEB7),
    pressedDark: Color(0xFF7BABA4),
    onSeedDark: Color(0xFF0D211F),
    containerDark: Color(0xFF274340),
    onContainerDark: Color(0xFFD6E5E2),
    bubbleDark: Color(0xFF263533),
    glowDark: Color(0xFF47726D),
    tintHue: 190,
    tintChroma: 0.7,
    haze: Color(0xFFB9D7E3),
    hazeDark: Color(0xFF34525E),
  );

  /// 琥珀:克制的金棕(70°,彩度 0.082,L 0.54)。页面转成米白纸、深色转成
  /// 暖炭,彩度只留七成半;光晕配杏粉。
  static const amber = AppAccent(
    id: 'amber',
    seed: Color(0xFF8D6636),
    pressed: Color(0xFF7A5528),
    container: Color(0xFFF2E6D9),
    onContainer: Color(0xFF483011),
    bubble: Color(0xFFEEE2D3),
    glow: Color(0xFFDCBE9D),
    seedDark: Color(0xFFCCAC87),
    pressedDark: Color(0xFFB99975),
    onSeedDark: Color(0xFF271A0C),
    containerDark: Color(0xFF4C3A25),
    onContainerDark: Color(0xFFEADFD3),
    bubbleDark: Color(0xFF392F24),
    glowDark: Color(0xFF7F6343),
    tintHue: 75,
    tintChroma: 0.75,
    haze: Color(0xFFEAC8C1),
    hazeDark: Color(0xFF64443D),
  );

  /// 石墨:中性灰。主色在浅色里近黑(L 0.30)、深色里近白(L 0.93),
  /// 中性色只留一丝冷调。像系统设置那样的黑白。
  static const graphite = AppAccent(
    id: 'graphite',
    seed: Color(0xFF2C2E32),
    pressed: Color(0xFF1D1F23),
    container: Color(0xFFE3E6EC),
    onContainer: Color(0xFF2C2E32),
    bubble: Color(0xFFE0E3E8),
    glow: Color(0xFFBBBEC3),
    seedDark: Color(0xFFE5E8ED),
    pressedDark: Color(0xFFCED1D6),
    onSeedDark: Color(0xFF191B1E),
    containerDark: Color(0xFF3B3D41),
    onContainerDark: Color(0xFFDEE1E7),
    bubbleDark: Color(0xFF2E3034),
    glowDark: Color(0xFF616368),
    tintHue: 262,
    tintChroma: 0.25,
    haze: Color(0xFFCED1D6),
    hazeDark: Color(0xFF4A4D52),
  );

  /// 设置页里的顺序。
  static const presets = [mist, daiqing, dusk, turquoise, amber, graphite];

  static const customId = 'custom';
  static const wallpaperId = 'wallpaper';

  /// 按 [id] 取预设;未知 / 缺失回退雾蓝(向前兼容旧值)。
  static AppAccent preset(String? id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return mist;
  }

  /// 由 [ThemePack] 构造配色:支持细粒度主色、气泡色、光晕与中性色相覆盖。
  factory AppAccent.fromThemePack(ThemePack pack, {String? label}) {
    final displayLabel = label ?? pack.displayName(AppLocale.isEnglish ? 'en' : 'zh');
    // Keyed on the seeds, not the id: a pack that extends or forks Paper & Ink keeps its hand-tuned tones.
    if (pack.palette.seed == ThemePack.paper.palette.seed && pack.palette.seedDark == ThemePack.paper.palette.seedDark) {
      return AppAccent(
        id: pack.id,
        label: displayLabel,
        seed: Color(pack.palette.seed),
        pressed: const Color(0xFF873927),
        container: Color(pack.palette.light.primaryContainer ?? 0xFFF5E4DA),
        onContainer: Color(pack.palette.light.onPrimaryContainer ?? 0xFF52271D),
        bubble: Color(pack.palette.light.userBubble ?? 0xFFECE8E2),
        glow: Color(pack.palette.light.glowPrimary ?? 0xFFD7A790),
        seedDark: Color(pack.palette.seedDark ?? 0xFFE4A58C),
        pressedDark: const Color(0xFFD39178),
        onSeedDark: const Color(0xFF321C16),
        containerDark: Color(pack.palette.dark.primaryContainer ?? 0xFF4F352C),
        onContainerDark: Color(pack.palette.dark.onPrimaryContainer ?? 0xFFF1DFD5),
        bubbleDark: Color(pack.palette.dark.userBubble ?? 0xFF36322E),
        glowDark: Color(pack.palette.dark.glowPrimary ?? 0xFF845442),
        tintHue: pack.palette.tintHue ?? 74,
        tintChroma: pack.palette.tintChroma,
        haze: Color(pack.palette.light.glowSecondary ?? 0xFFECD4A9),
        hazeDark: Color(pack.palette.dark.glowSecondary ?? 0xFF624939),
      );
    }
    final derived = AppAccent.derive(
      Color(pack.palette.seed),
      id: pack.id,
      label: displayLabel,
    );
    final p = pack.palette;
    return AppAccent(
      id: pack.id,
      label: displayLabel,
      seed: p.light.primary != null ? Color(p.light.primary!) : derived.seed,
      pressed: derived.pressed,
      container: p.light.primaryContainer != null ? Color(p.light.primaryContainer!) : derived.container,
      onContainer: p.light.onPrimaryContainer != null ? Color(p.light.onPrimaryContainer!) : derived.onContainer,
      bubble: p.light.userBubble != null ? Color(p.light.userBubble!) : derived.bubble,
      glow: p.light.glowPrimary != null ? Color(p.light.glowPrimary!) : derived.glow,
      seedDark: p.dark.primary != null
          ? Color(p.dark.primary!)
          : (p.seedDark != null ? Color(p.seedDark!) : derived.seedDark),
      pressedDark: derived.pressedDark,
      onSeedDark: p.dark.onPrimary != null ? Color(p.dark.onPrimary!) : derived.onSeedDark,
      containerDark: p.dark.primaryContainer != null ? Color(p.dark.primaryContainer!) : derived.containerDark,
      onContainerDark:
          p.dark.onPrimaryContainer != null ? Color(p.dark.onPrimaryContainer!) : derived.onContainerDark,
      bubbleDark: p.dark.userBubble != null ? Color(p.dark.userBubble!) : derived.bubbleDark,
      glowDark: p.dark.glowPrimary != null ? Color(p.dark.glowPrimary!) : derived.glowDark,
      tintHue: p.tintHue ?? derived.tintHue,
      tintChroma: p.tintChroma,
      haze: p.light.glowSecondary != null ? Color(p.light.glowSecondary!) : derived.haze,
      hazeDark: p.dark.glowSecondary != null ? Color(p.dark.glowSecondary!) : derived.hazeDark,
    );
  }

  // ══ 现推:自定义、跟随壁纸 ═══════════════════════════════════════════

  /// 强调彩度上限:再高就不"静"了(雾蓝 0.125)。
  static const maxChroma = 0.13;

  /// 色相条、推荐色的明度(与雾蓝相同)。
  static const lightSeedL = 0.53;

  /// 深色主色比浅色主色亮多少(雾蓝 0.53 → 0.764)。
  static const darkLift = 0.234;

  /// 由任意一个颜色推出整套配色:取它的色相、彩度(封顶 [maxChroma])和
  /// 明度(限在 0.30–0.60,深色再提 [darkLift]),按上面那张表推出各个
  /// 角色;浅色、深色主色各过一次 [guard],离原色最近地调到达标。
  ///
  /// 中性色转到同一色相,彩度按强调彩度折算(近灰的颜色得到近灰的页面)。
  factory AppAccent.derive(Color pick, {String id = customId, String? label}) {
    final key = (pick.toARGB32(), id, label);
    final hit = _derived[key];
    if (hit != null) return hit;
    if (_derived.length > 64) _derived.clear();
    return _derived[key] = AppAccent._derive(pick, id: id, label: label);
  }

  static final _derived = <(int, String, String?), AppAccent>{};

  factory AppAccent._derive(Color pick, {required String id, required String? label}) {
    final o = Oklch.fromColor(pick);
    final c = math.min(o.c, maxChroma);
    final h = o.h;
    final k = math.min(1.0, c / 0.1255);
    final tintChroma = 0.8 * k;
    final neutrals = NeutralTones.of(tintHue: h, tintChroma: tintChroma);
    Color tone(double l, double ratio) => Oklch(l, c * ratio, h).toColor();

    final onSeedDark = tone(0.231, 0.39);
    final lightL = o.l.clamp(0.30, 0.60);
    final seed = guard(
      Oklch(lightL, c, h),
      brightness: Brightness.light,
      surface: neutrals.mistHighest,
      onAccent: const Color(0xFFFFFFFF),
    );
    final seedDark = guard(
      Oklch(math.min(0.93, lightL + darkLift), c * 0.76, h),
      brightness: Brightness.dark,
      surface: neutrals.nightHighest,
      onAccent: onSeedDark,
    );
    final sl = Oklch.fromColor(seed).l;
    final sdl = Oklch.fromColor(seedDark).l;
    return AppAccent(
      id: id,
      label: label,
      seed: seed,
      pressed: tone(sl - 0.06, 0.95),
      container: tone(0.93, 0.26),
      onContainer: tone(0.33, 0.70),
      bubble: tone(0.918, 0.29),
      glow: tone(0.819, 0.68),
      seedDark: seedDark,
      pressedDark: tone(sdl - 0.06, 0.76),
      onSeedDark: onSeedDark,
      containerDark: tone(0.361, 0.51),
      onContainerDark: tone(0.909, 0.24),
      bubbleDark: tone(0.314, 0.29),
      glowDark: tone(0.52, 0.72),
      tintHue: h,
      tintChroma: tintChroma,
      haze: Oklch(0.86, 0.045 * k, h + 33).toColor(),
      hazeDark: Oklch(0.42, 0.05 * k, h + 33).toColor(),
    );
  }

  /// 强调色在底面上的最低对比度(WCAG 1.4.11 非文字)。
  static const minOnSurface = 3.0;

  /// 强调色上文字的最低对比度(WCAG 1.4.3 正文)。
  static const minText = 4.5;

  /// 对比度守卫:色相、彩度不动,只沿明度移动 [start],直到
  ///
  /// - 强调色对 [surface] ≥ [minOnSurface](3:1),且
  /// - [onAccent] 对强调色 ≥ [minText](4.5:1)。
  ///
  /// 浅色往暗处走(白字在上),深色往亮处走(深墨字在上);已经达标就原样
  /// 返回。二分 24 步,停在离起点最近的达标明度上。
  static Color guard(Oklch start, {required Brightness brightness, required Color surface, required Color onAccent}) {
    bool ok(Color c) => contrastRatio(c, surface) >= minOnSurface && contrastRatio(onAccent, c) >= minText;
    final first = start.toColor();
    if (ok(first)) return first;
    final dark = brightness == Brightness.dark;
    // 浅色:在 [0, start.l] 里找最大的达标明度;深色:在 [start.l, 1] 里找最小的。
    var pass = dark ? 1.0 : 0.0;
    var fail = start.l;
    for (var i = 0; i < 24; i++) {
      final mid = (pass + fail) / 2;
      if (ok(start.copyWith(l: mid).toColor())) {
        pass = mid;
      } else {
        fail = mid;
      }
    }
    return start.copyWith(l: pass).toColor();
  }

  /// [pick] 在 [brightness] 下守卫后的主色:设置页的色块和色相条直接画它。
  static Color guardedSeed(Color pick, Brightness brightness) => AppAccent.derive(pick).seedFor(brightness);

  /// 色相条 / 推荐色用的颜色:[hue] 度、雾蓝的彩度和明度。
  static Color hueColor(double hue, {double chroma = 0.11}) => Oklch(lightSeedL, chroma, hue).toColor();

  @override
  bool operator ==(Object other) =>
      other is AppAccent &&
      other.id == id &&
      other.seed == seed &&
      other.seedDark == seedDark &&
      other.tintHue == tintHue &&
      other.tintChroma == tintChroma;

  @override
  int get hashCode => Object.hash(id, seed, seedDark, tintHue, tintChroma);

  @override
  String toString() => 'AppAccent($id)';
}
