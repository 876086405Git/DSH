// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// 字体规范:**系统无衬线负责一切文字,等宽只给代码**。
///
/// ## 为什么不打包中文字体、也不用衬线标题
///
/// - 思源黑体 / 宋体单字重 10–20 MB,APK 已经背着 Linux 运行时,不能再加;
/// - 国产 ROM(MIUI/HyperOS、ColorOS、OriginOS、HarmonyOS)把系统字体换成了
///   MiSans、OPPO Sans、vivo Sans、HarmonyOS Sans,质量都很好,而且自带配套的
///   拉丁字形 —— 跟着系统走就是最协调的;
/// - 这些 ROM 普遍**没有** Noto Serif CJK,衬线标题在它们上面会变成
///   "拉丁是衬线、中文是黑体"的拼盘。所以标题用无衬线 + 字号 / 颜色分层。
///
/// ## 字重只用两档
///
/// AOSP / Pixel 只带 Noto Sans CJK **Regular** 一个字重,w500 会被就近映射回
/// Regular,w600+ 走合成加粗。所以层级只靠 400 / 600 两档 + 字号 + 颜色,
/// 不要指望 500 和 400 在中文上看得出区别。大号展示字用 300(在有多字重的
/// 系统上更轻盈,没有时退回 400,不影响阅读)。
///
/// ## 等宽
///
/// JetBrains Mono(OFL,Regular + Medium + Bold 约 0.8 MB)。Android 的
/// `monospace` 在不同机型上是 Droid Sans Mono / Cutive Mono,观感参差,代码
/// 是这个 App 的主要内容之一,值得打包。缺失时回退系统等宽。
///
/// ## 汉字字形
///
/// 中日韩统一码同一个码位在不同地区字形不同(如「直」「写」)。务必在
/// `MaterialApp` 里声明 `supportedLocales: [Locale('zh', 'CN'), ...]` 并接入
/// `GlobalMaterialLocalizations`,否则在非中文系统语言下会取到日文字形。
abstract final class AppType {
  /// 无衬线族。`null` = 系统默认(Android:Roboto + 系统中文字体)。
  /// 将来若打包拉丁 UI 字体,只改这一处。
  static const String? sansFamily = null;

  /// 打包的等宽族名(pubspec `fonts:` 里的 family)。
  static const monoFamily = 'JetBrainsMono';

  /// Source operators remain separate glyphs (<=, !=, ->), not programming
  /// ligatures. This changes shaping only, never the text copied or selected.
  static const monoFeatures = [FontFeature.disable('calt'), FontFeature.disable('liga')];

  /// 等宽回退:系统等宽 → 中文(代码注释里的中文落到系统黑体)。
  static const monoFallback = <String>['monospace', 'Noto Sans Mono CJK SC', 'Noto Sans CJK SC'];

  /// [t] with every style's glyph locale set to [locale] (null: unchanged).
  /// The English UI passes zh_CN so Chinese content keeps Chinese shapes.
  static TextTheme withGlyphLocale(TextTheme t, Locale? locale) {
    if (locale == null) return t;
    final s = TextStyle(locale: locale);
    return t.merge(
      TextTheme(
        displayLarge: s,
        displayMedium: s,
        displaySmall: s,
        headlineLarge: s,
        headlineMedium: s,
        headlineSmall: s,
        titleLarge: s,
        titleMedium: s,
        titleSmall: s,
        bodyLarge: s,
        bodyMedium: s,
        bodySmall: s,
        labelLarge: s,
        labelMedium: s,
        labelSmall: s,
      ),
    );
  }

  /// ThemeData merges Material's tracking in under [textTheme]. It's made for Roboto and reads loose
  /// in San Francisco and PingFang, so iOS sets its own: none, and a little less on big titles, as
  /// the system's own type does.
  static TextTheme tracked(TextTheme t) {
    if (defaultTargetPlatform != TargetPlatform.iOS) return t;
    const none = TextStyle(letterSpacing: 0);
    const tight = TextStyle(letterSpacing: -0.2);
    return t.merge(
      const TextTheme(
        displayLarge: tight,
        displayMedium: tight,
        displaySmall: tight,
        headlineLarge: tight,
        headlineMedium: tight,
        headlineSmall: tight,
        titleLarge: tight,
        titleMedium: none,
        titleSmall: none,
        bodyLarge: none,
        bodyMedium: none,
        bodySmall: none,
        labelLarge: none,
        labelMedium: none,
        labelSmall: none,
      ),
    );
  }

  /// 等宽样式统一出口 —— 业务代码禁止再写 fontFamily 字面量。
  static TextStyle mono({double size = 13, FontWeight? weight, Color? color, double height = 1.55}) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFeatures: monoFeatures,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// 工具 / 终端输出正文。
  static TextStyle monoSmall({Color? color}) => mono(size: 12, color: color, height: 1.5);

  /// 参数摘要、命令行、路径 chip、diff 统计。
  static TextStyle monoLabel({Color? color, FontWeight? weight}) =>
      mono(size: 12, color: color, weight: weight, height: 1.35);

  /// 聊天正文(用户气泡与助手正文同源,流式 → 渲染完成不跳字号)。
  ///
  /// [scale] / [height] 来自用户设置(建议 scale 0.85–1.3,height 1.5–1.9);
  /// 主题本身不依赖任何状态。
  static TextStyle chatBody(BuildContext context, {double scale = 1, double? height, Color? color}) {
    final base = Theme.of(context).textTheme.bodyLarge ?? textTheme.bodyLarge!;
    return base.copyWith(fontSize: (base.fontSize ?? 16) * scale, height: height ?? base.height, color: color);
  }

  /// 欢迎语 / 空状态大字:大而轻,不靠粗。
  static TextStyle display({double size = 28, Color? color}) => TextStyle(
    fontFamily: sansFamily,
    fontSize: size,
    fontWeight: FontWeight.w300,
    height: 1.25,
    color: color,
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// 字标「DSH」:无衬线粗体 + 轻微字距。
  static TextStyle wordmark({double size = 18, Color? color}) => TextStyle(
    fontFamily: sansFamily,
    fontSize: size,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    height: 1.2,
    color: color,
  );

  /// 分区小标题(「最近会话」「引擎」):小字号 + 字距,替代粗分割线。
  static TextStyle eyebrow({Color? color}) => TextStyle(
    fontFamily: sansFamily,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    height: 1.35,
    color: color,
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// 等宽数字(计时器、token 计数、百分比),防止数字跳动导致宽度抖。
  static TextStyle tabular(TextStyle style) => style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  static const _even = TextLeadingDistribution.even;

  /// Material 3 字阶(颜色在 app_theme 里按方案统一 apply)。
  ///
  /// | 角色 | 字号 / 行高 | 用途 |
  /// |---|---|---|
  /// | displaySmall | 28 / 1.25 w300 | 欢迎语、安装完成大字 |
  /// | headlineMedium | 22 / 1.3 w600 | 页面标题(设置、引擎) |
  /// | headlineSmall | 20 / 1.35 w600 | 对话框标题 |
  /// | titleLarge | 18 / 1.4 w600 | 弹层标题、顶栏会话名(展开态) |
  /// | titleMedium | 16 / 1.45 w600 | 卡片 / 列表标题、正文小标题 |
  /// | titleSmall | 14 / 1.45 w600 | 工具行名、分组名 |
  /// | bodyLarge | 16 / 1.65 | 聊天正文 |
  /// | bodyMedium | 14 / 1.55 | 界面正文 |
  /// | bodySmall | 12 / 1.5 | 说明、元信息 |
  /// | labelLarge | 14 / 1.4 w600 | 按钮 |
  /// | labelMedium | 12 / 1.35 w600 | Chip、胶囊 |
  /// | labelSmall | 11 / 1.35 | 时间戳、角标 |
  static const textTheme = TextTheme(
    displayLarge: TextStyle(fontSize: 36, fontWeight: FontWeight.w300, height: 1.2, leadingDistribution: _even),
    displayMedium: TextStyle(fontSize: 32, fontWeight: FontWeight.w300, height: 1.2, leadingDistribution: _even),
    displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w300, height: 1.25, leadingDistribution: _even),
    headlineLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.w600, height: 1.3, leadingDistribution: _even),
    headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.3, leadingDistribution: _even),
    headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.35, leadingDistribution: _even),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4, leadingDistribution: _even),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.45, leadingDistribution: _even),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.45, leadingDistribution: _even),
    bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.65, leadingDistribution: _even),
    bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, height: 1.55, leadingDistribution: _even),
    bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, height: 1.5, leadingDistribution: _even),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0.1,
      leadingDistribution: _even,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.35,
      letterSpacing: 0.2,
      leadingDistribution: _even,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      height: 1.35,
      letterSpacing: 0.2,
      leadingDistribution: _even,
    ),
  );
}
