// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'accent.dart';
import 'app_icons.dart';
import 'ink_glow.dart';
import 'page_transitions.dart';
import 'palette.dart';
import 'semantic_colors.dart';
import '../../themes/theme_pack.dart';
import 'shapes.dart';
import 'squircle.dart';
import 'surfaces.dart';
import 'theme_style.dart';
import 'typography.dart';

/// 浅色主题。
///
/// [accent] 是整套配色(强调色 + 中性色的色调),见 `accent.dart`。
/// [glassBlur] 关掉后所有玻璃改用近乎不透明的填充(设置里的"减少透明效果",
/// 或性能探测判定为低端机时)。
///
/// [glyphLocale] pins the locale CJK glyphs are picked by (the English UI
/// passes zh_CN so Chinese content keeps Chinese shapes).
///
/// [instantPages] 让二级页的推入 / 退出不花时间(动画开关关掉时)。
///
/// [fluid] 灵动档:默认水波换成按压光晕([AppInkGlow])。
ThemeData buildLightTheme({
  AppAccent accent = AppAccent.mist,
  bool glassBlur = true,
  Locale? glyphLocale,
  bool instantPages = false,
  bool fluid = false,
  ThemePack? themePack,
  Map<String, String> loadedFonts = const {},
}) => _build(
  applyThemePackScheme(DshPalette.lightScheme(accent), themePack),
  applyThemePackColors(DshColors.forAccent(Brightness.light, accent), themePack, Brightness.light),
  applyThemePackSurfaces(
    DshSurfaces.light(accent, blurEnabled: glassBlur),
    themePack,
    Brightness.light,
    blurEnabled: glassBlur,
  ),
  accent,
  glyphLocale,
  instantPages,
  fluid,
  themePack,
  loadedFonts,
);

/// 深色主题。
ThemeData buildDarkTheme({
  AppAccent accent = AppAccent.mist,
  bool glassBlur = true,
  Locale? glyphLocale,
  bool instantPages = false,
  bool fluid = false,
  ThemePack? themePack,
  Map<String, String> loadedFonts = const {},
}) => _build(
  applyThemePackScheme(DshPalette.darkScheme(accent), themePack),
  applyThemePackColors(DshColors.forAccent(Brightness.dark, accent), themePack, Brightness.dark),
  applyThemePackSurfaces(
    DshSurfaces.dark(accent, blurEnabled: glassBlur),
    themePack,
    Brightness.dark,
    blurEnabled: glassBlur,
  ),
  accent,
  glyphLocale,
  instantPages,
  fluid,
  themePack,
  loadedFonts,
);

/// 边到边(edge-to-edge)的系统栏样式:状态栏、导航栏全透明,图标随明暗。
///
/// 自绘顶栏的页面(聊天页没有 AppBar)要自己包一层
/// `AnnotatedRegion<SystemUiOverlayStyle>(value: dshSystemOverlay(...))`,
/// 并在 `main()` 里 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`。
SystemUiOverlayStyle dshSystemOverlay(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );
}

/// What Material should behave as on [os]. HarmonyOS is meant to feel like the
/// Android app: page transitions, ink, dialogs and text limits all read this.
/// Written as the Android value because stock Flutter has no `TargetPlatform.ohos`.
@visibleForTesting
TargetPlatform? themePlatformFor(String os) => os == 'ohos' ? TargetPlatform.android : null;

/// 雾蓝玻璃主题。三条铁律:
///
/// 1. **层次靠材质,不靠阴影。** 页面是渐变,浮在内容上的(顶栏、输入条、
///    弹层)是真模糊玻璃,躺在页面上的(卡片、胶囊)是半透明白;M3 的
///    elevation 一律 0,`surfaceTint` 透明。唯一的投影在玻璃外沿,且很淡。
/// 2. **细线是骨架。** 卡片、Chip、输入框、对话框都有 0.5–1px 的线;
///    它比阴影安静,在浅色雾蓝底上又比纯色块清楚。
/// 3. **连续圆角。** 全部走 `AppShape` 的五档 + 胶囊,不手写半径。
ThemeData _build(
  ColorScheme scheme,
  DshColors colors,
  DshSurfaces surfaces,
  AppAccent accent,
  Locale? glyphLocale,
  bool instantPages,
  bool fluid, [
  ThemePack? themePack,
  Map<String, String> loadedFonts = const {},
]) {
  // iOS 式水平推入,上一页左移变暗;系统预测返回与边缘右滑都跟手
  // (见 page_transitions.dart)。全平台同一套,二级页的观感只此一处。
  final pages = instantPages
      ? const AppPageTransitionsBuilder.instant()
      : fluid
      ? const AppPageTransitionsBuilder.fluid()
      : const AppPageTransitionsBuilder();
  final transitions = PageTransitionsTheme(builders: {for (final platform in TargetPlatform.values) platform: pages});

  final isDark = scheme.brightness == Brightness.dark;
  final hairline = scheme.outlineVariant;
  // 开关的圆钮:平时是一颗浅色钮。主色本身就近白(石墨的深色)时,开态轨道
  // 和浅色钮糊成一片,开态换成主色上的深墨钮,勾换回主色。
  final lightKnob = isDark ? scheme.onSurface : Colors.white;
  final knobBlends = contrastRatio(lightKnob, scheme.primary) < 1.6;
  final onKnob = knobBlends ? scheme.onPrimary : lightKnob;
  final checkOn = knobBlends ? scheme.primary : (isDark ? scheme.inversePrimary : scheme.primary);
  final baseTextTheme = AppType.withGlyphLocale(
    AppType.tracked(AppType.textTheme),
    glyphLocale,
  ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
  final textTheme = applyThemePackTypography(baseTextTheme, themePack, loadedFonts);
  final themeStyle = buildDshThemeStyle(themePack, scheme.brightness, loadedFonts);
  final rSm = themePack == null ? AppShape.sm : themeStyle.scaleRadius(AppShape.sm);
  final rMd = themePack == null ? AppShape.md : themeStyle.scaleRadius(AppShape.md);
  final rXl = themePack == null ? AppShape.xl : themeStyle.scaleRadius(AppShape.xl);
  final radiusMd = themePack == null ? AppShape.radiusMd : BorderRadius.all(Radius.circular(rMd));
  final borderW = themePack == null ? 0.5 : themeStyle.borderWidth;
  final cardBorder = themePack == null ? AppShape.card : SquircleBorder(borderRadius: radiusMd);
  final sheetBorder = themePack == null
      ? AppShape.sheet
      : SquircleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(rXl)));
  // 输入框 / Chip 的填充:与卡片玻璃同值,保证"表单是长在页面上的"。
  final fieldFill = surfaces.card.fallbackFill;
  // 弹出层(对话框、菜单)用不透明面:它们压在遮罩上,不需要也不应该透。
  final popupFill = isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest;

  return ThemeData(
    useMaterial3: true,
    adaptations: const [_SwitchAdaptation()],
    platform: themePlatformFor(Platform.operatingSystem),
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: textTheme,
    extensions: [colors, surfaces, themeStyle],
    pageTransitionsTheme: transitions,
    visualDensity: VisualDensity.standard,
    // 水波保留但更含蓄。
    // iOS 的控件按下只变一层底色,没有水波。
    splashFactory: fluid
        ? AppInkGlow.splashFactory
        : (defaultTargetPlatform == TargetPlatform.iOS ? NoSplash.splashFactory : null),
    splashColor: scheme.primary.withValues(alpha: 0.08),
    highlightColor: scheme.primary.withValues(alpha: 0.04),
    hoverColor: scheme.onSurface.withValues(alpha: 0.04),
    focusColor: scheme.primary.withValues(alpha: 0.12),
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),

    // 顶栏透明:页面背景就是顶栏背景,需要分隔时由玻璃或细线承担。
    appBarTheme: AppBarThemeData(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleTextStyle: textTheme.titleMedium?.copyWith(fontSize: 17),
      systemOverlayStyle: dshSystemOverlay(scheme.brightness),
    ),

    // 卡片 = 半透明白玻璃(不模糊)+ 0.5px 细线 + 零阴影。
    cardTheme: CardThemeData(
      color: surfaces.card.fill,
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: themePack == null
          ? AppShape.outlined(hairline, radius: rMd, width: borderW)
          : themeStyle.cardShape(hairline, borderW),
    ),

    // 输入框:长在页面上的玻璃片。描边用 outline(≥ 3:1,WCAG 1.4.11),
    // 聚焦时换主色。
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: fieldFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: hairline),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
      hintStyle: TextStyle(color: colors.textTertiary),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      floatingLabelStyle: TextStyle(color: scheme.primary),
      helperStyle: TextStyle(color: colors.textTertiary),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
    ),

    // 主按钮:主色实心 + 连续圆角(不是胶囊)。按下换更深一档,不只靠水波。
    filledButtonTheme: FilledButtonThemeData(
      style:
          // No background here: a theme colour would override every
          // FilledButton.tonal too (they would render as solid primary). The
          // variants' own defaults give primary / secondaryContainer.
          FilledButton.styleFrom(
            minimumSize: const Size(64, 50),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            elevation: 0,
            shape: cardBorder,
            textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
          ),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 50),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        elevation: 0,
        backgroundColor: fieldFill,
        foregroundColor: scheme.onSurface,
        shape: AppShape.outlined(hairline, radius: rMd, width: themePack == null ? 1 : borderW),
        textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
      ),
    ),

    // 次按钮:描边是 outline 的 40%,卡片上、弹层上都看得见,又比主按钮安静
    // (发丝色在浅色弹层上和底色几乎一样)。禁用时描边减半。
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            minimumSize: const Size(64, 50),
            padding: const EdgeInsets.symmetric(horizontal: 22),
            foregroundColor: scheme.onSurface,
            shape: cardBorder,
            textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: scheme.outline.withValues(alpha: states.contains(WidgetState.disabled) ? 0.2 : 0.4),
              ),
            ),
          ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        foregroundColor: scheme.primary,
        shape: Squircle.border(rSm),
        textStyle: textTheme.labelLarge,
      ),
    ),

    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: scheme.onSurfaceVariant),
    ),

    chipTheme: ChipThemeData(
      shape: Squircle.border(rSm),
      side: BorderSide(color: hairline),
      backgroundColor: fieldFill,
      selectedColor: scheme.primaryContainer,
      checkmarkColor: scheme.onPrimaryContainer,
      labelStyle: textTheme.labelMedium?.copyWith(color: scheme.onSurface),
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: scheme.onPrimaryContainer),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: fieldFill,
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        foregroundColor: scheme.onSurfaceVariant,
        side: BorderSide(color: hairline),
        minimumSize: const Size(0, 44),
        shape: Squircle.border(AppShape.sm),
      ),
    ),

    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(fieldFill),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: WidgetStatePropertyAll(AppShape.outlined(hairline, radius: AppShape.md)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
      hintStyle: WidgetStatePropertyAll(textTheme.bodyLarge?.copyWith(color: colors.textTertiary)),
      constraints: const BoxConstraints(minHeight: 48),
    ),

    // 角标默认主色:默认的 error 红会让"当前"读起来像出错。
    badgeTheme: BadgeThemeData(
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
      largeSize: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      textStyle: AppType.tabular(textTheme.labelSmall!.copyWith(fontWeight: FontWeight.w600)),
    ),

    // 折叠面板不画框:它通常已经在一张卡里。
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      iconColor: scheme.onSurfaceVariant,
      collapsedIconColor: scheme.onSurfaceVariant,
    ),

    dialogTheme: DialogThemeData(
      // Material's 560 cap: a confirm keeps its shape on a tablet.
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 560),
      elevation: 0,
      backgroundColor: popupFill,
      surfaceTintColor: Colors.transparent,
      barrierColor: surfaces.scrim,
      shape: AppShape.outlined(hairline, radius: rXl, width: borderW),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
    ),

    // 默认弹层是不透明的;要玻璃弹层用 common/app_sheet.dart 的
    // `showAppSheet(glass: true)`(背景透明 + GlassSurface)。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surfaces.sheet.fallbackFill,
      modalBackgroundColor: surfaces.sheet.fallbackFill,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      modalBarrierColor: surfaces.scrim,
      dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.35),
      dragHandleSize: const Size(36, 4),
      clipBehavior: Clip.antiAlias,
      shape: sheetBorder,
      showDragHandle: true,
    ),

    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: scheme.onInverseSurface),
      actionTextColor: scheme.inversePrimary,
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      shape: cardBorder,
    ),

    dividerTheme: DividerThemeData(color: hairline, thickness: 0.5, space: 1),

    // 2024 版 M3 进度条(轨道留缝 + 端点),主色细条。
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primary.withValues(alpha: 0.16),
      circularTrackColor: scheme.primary.withValues(alpha: 0.16),
      stopIndicatorColor: scheme.primary,
      linearMinHeight: 4,
      borderRadius: AppShape.radiusXs,
      // ignore: deprecated_member_use
      year2023: false,
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: popupFill,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shadowColor: scheme.shadow.withValues(alpha: 0.5),
      shape: AppShape.outlined(hairline, radius: rMd, width: borderW),
      textStyle: textTheme.bodyMedium,
    ),

    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(popupFill),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(2),
        shadowColor: WidgetStatePropertyAll(scheme.shadow.withValues(alpha: 0.5)),
        shape: WidgetStatePropertyAll(AppShape.outlined(hairline, radius: rMd, width: borderW)),
      ),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      selectedColor: scheme.onPrimaryContainer,
      selectedTileColor: scheme.primaryContainer,
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      shape: cardBorder,
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: AppShape.bubble,
    ),

    // 抽屉默认不透明兜底;会话抽屉自己用 sheet 玻璃画。
    drawerTheme: DrawerThemeData(
      backgroundColor: surfaces.sheet.fallbackFill,
      surfaceTintColor: Colors.transparent,
      scrimColor: surfaces.scrim,
      elevation: 0,
      width: 320,
      shape: const SquircleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(AppShape.xl),
          bottomRight: Radius.circular(AppShape.xl),
        ),
      ),
    ),

    // 底栏透明:外壳把它放进 chrome 玻璃里。
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      dividerColor: Colors.transparent,
      labelStyle: textTheme.titleSmall,
      unselectedLabelStyle: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400),
    ),

    // iOS 式开关:两态都是同一颗浅色圆钮;开 = 主色轨道,关 = 看得见的
    // 中性轨道。禁用不另起配色,整颗淡下去,和"关"一眼分开。
    switchTheme: SwitchThemeData(
      // 关态也给一颗透明图标:M3 只有带图标时才把关态圆钮画得和开态一样大。
      // 勾用主色的深一档(深色主题的 primary 太浅,在浅色圆钮上看不清)。
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => Icon(
          AppIcons.selected,
          size: 14,
          color: states.contains(WidgetState.selected)
              ? checkOn.withValues(alpha: states.contains(WidgetState.disabled) ? 0.5 : 1)
              : Colors.transparent,
        ),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      trackColor: WidgetStateProperty.resolveWith((states) {
        final disabled = states.contains(WidgetState.disabled);
        if (states.contains(WidgetState.selected)) {
          return scheme.primary.withValues(alpha: disabled ? 0.38 : 1);
        }
        // 关态轨道在卡片上约 1.5:1:看得出是个开关,不像禁用。
        return scheme.onSurface.withValues(alpha: disabled ? 0.09 : 0.22);
      }),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        final knob = states.contains(WidgetState.selected) ? onKnob : lightKnob;
        if (!states.contains(WidgetState.disabled)) return knob;
        return knob.withValues(alpha: isDark ? 0.5 : 0.8);
      }),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: scheme.inverseSurface, borderRadius: AppShape.radiusSm),
      textStyle: textTheme.bodySmall?.copyWith(color: scheme.onInverseSurface),
      waitDuration: const Duration(milliseconds: 400),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: isDark ? 0.28 : 0.24),
      selectionHandleColor: scheme.primary,
    ),

    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(scheme.onSurfaceVariant.withValues(alpha: 0.35)),
      radius: const Radius.circular(999),
      thickness: const WidgetStatePropertyAll(4),
      crossAxisMargin: 2,
    ),
  );
}

/// `Switch.adaptive` on iOS draws the system's switch, in the app's colours and without Material's
/// check mark. Other platforms keep the theme as it is.
class _SwitchAdaptation extends Adaptation<SwitchThemeData> {
  const _SwitchAdaptation();

  @override
  SwitchThemeData adapt(ThemeData theme, SwitchThemeData defaultValue) => theme.platform == TargetPlatform.iOS
      ? SwitchThemeData(
          thumbColor: defaultValue.thumbColor,
          trackColor: defaultValue.trackColor,
          trackOutlineColor: defaultValue.trackOutlineColor,
        )
      : defaultValue;
}
