import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'companion/companion_initiative_owner.dart' show companionInitiativeProvider;
import 'l10n/l10n.dart';
import 'performance/performance_state.dart';
import 'performance/refresh_rate.dart';
import 'state/app_info.dart';
import 'state/appearance_state.dart';
import 'state/locale_state.dart';
import 'state/star_prompt.dart' show starPromptGateProvider, starPromptProvider;
import 'state/tile_style_state.dart';
import 'ui/chat/dsh_ui/dsh_ui_model.dart' show DshUiAppAccent;
import 'ui/common/keyboard_motion.dart';
import 'ui/common/side_insets.dart';
import 'ui/launch/launch_overlay.dart';
import 'ui/shell/root_gate.dart';
import 'ui/theme/theme.dart';
import 'ui_config/ui_config_state.dart';
import 'usage/usage_stats.dart';

class DshApp extends ConsumerStatefulWidget {
  const DshApp({super.key, this.home});

  /// Replaces the root gate (widget tests).
  final Widget? home;

  @override
  ConsumerState<DshApp> createState() => _DshAppState();
}

class _DshAppState extends ConsumerState<DshApp> with WidgetsBindingObserver {
  /// Themes of the palette last built: rebuilt only when the palette or the
  /// language changes.
  AppAccent? _accent;
  bool? _english;
  bool? _glassBlur;
  bool? _instantPages;
  bool? _fluid;
  late ThemeData _light;
  late ThemeData _dark;

  /// The language last shown; a change after the first frame rebuilds the
  /// whole tree (text read through `appL10n` has no dependency to notify).
  Locale? _shown;

  /// The stored palette arrives a moment after launch; that first switch
  /// lands without a cross-fade, later ones fade (切换配色).
  bool _settled = false;

  /// MaterialApp builds Theme for AnimationStyle.noAnimation and AnimatedTheme for anything else,
  /// so the cross-fade coming on or off replaces everything above the builder. The navigator has a
  /// global key to survive that; what the builder holds needs one too, or the launch screen and
  /// the theme reveal start again from nothing, and a launch screen waiting for its motion to end
  /// never leaves.
  final _layers = GlobalKey(debugLabel: 'app layers');

  @override
  void initState() {
    super.initState();
    // Start loading the stored tile style now, so 全部功能 opens in it rather
    // than flashing the default first.
    ref.read(tileStyleProvider);
    // Anonymous usage statistics live as long as the app, in either 界面
    // (release builds: today is noted, and earlier days go out).
    ref.read(usageStatsProvider);
    // 公测版: the star prompt counts time in front from launch, in either 界面.
    if (ref.read(starPromptGateProvider)) ref.read(starPromptProvider);
    // 伙伴小屋: her invitation ledger is read now, so it is known before the room opens.
    ref.read(companionInitiativeProvider);
    // 刷新率: some systems cap third-party apps at 60 Hz and then show their per-app
    // switch as an in-app setting; the app answers frames to run at the fastest rate
    // while it is actually drawing (see RefreshRateService).
    RefreshRateService.instance.start();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 跟随系统: the system language changed while the app was open.
  @override
  void didChangeLocales(List<Locale>? locales) {
    if (ref.read(appLanguageProvider) == AppLanguage.system) setState(() {});
  }

  /// The system's remove-animations setting changed while the app was open: page
  /// transitions are chosen in [build], so they would keep the old answer.
  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  void _themesFor(AppAccent accent, bool english, bool glassBlur, bool instantPages, bool fluid) {
    if (accent == _accent &&
        english == _english &&
        glassBlur == _glassBlur &&
        instantPages == _instantPages &&
        fluid == _fluid) {
      return;
    }
    _accent = accent;
    _english = english;
    _glassBlur = glassBlur;
    _instantPages = instantPages;
    _fluid = fluid;
    // Plugin views that ask for `accent: "app"` follow the palette.
    DshUiAppAccent.set(accent.seed.toARGB32());
    // English UI still shows Chinese content: keep its glyphs Chinese.
    final glyphs = english ? AppLocale.zhCN : null;
    _light = buildLightTheme(
      accent: accent,
      glyphLocale: glyphs,
      glassBlur: glassBlur,
      instantPages: instantPages,
      fluid: fluid,
    );
    _dark = buildDarkTheme(
      accent: accent,
      glyphLocale: glyphs,
      glassBlur: glassBlur,
      instantPages: instantPages,
      fluid: fluid,
    );
  }

  Locale _resolveLocale() {
    final locale = AppLocale.resolve(
      ref.watch(appLanguageProvider).locale,
      WidgetsBinding.instance.platformDispatcher.locales,
    );
    if (locale != _shown) {
      final first = _shown == null;
      _shown = locale;
      AppLocale.use(locale);
      if (!first) WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
    }
    return locale;
  }

  void _rebuildAll() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    if (mounted) (context as Element).visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) {
    // 刷新率设置改动时告诉原生;setMode 对同一个值不做任何事。
    unawaited(
      RefreshRateService.instance.setMode(ref.watch(performancePrefsProvider.select((p) => p.refreshRate))),
    );
    final themeMode = ref.watch(uiThemeModeProvider.select((s) => s.value));
    final appearance = ref.watch(appearanceProvider);
    final waiting =
        !appearance.loaded ||
        (appearance.source == AccentSource.wallpaper && ref.watch(wallpaperAccentProvider).isLoading);
    final locale = _resolveLocale();
    final performance = ref.watch(performanceDefaultsProvider);
    final reduced =
        performance.reduceMotion || WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    final fluid = performance.fluidMotion && !reduced;
    FrameClock.instance.enabled = fluid;
    _themesFor(ref.watch(accentProvider), locale.languageCode == 'en', performance.blur, reduced, fluid);
    if (!waiting && !_settled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _settled = true);
    }
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      themeMode: themeMode,
      // Palette and light / dark changes cross-fade the whole app (AppMotion).
      // A reveal from the finger brings the new colours in itself.
      themeAnimationStyle: _settled && !reduced && !ThemeRevealHost.active
          ? AnimationStyle(duration: AppMotion.standard, curve: AppMotion.std)
          : AnimationStyle.noAnimation,
      // zh_CN, not bare zh: otherwise CJK falls back to Japanese glyph shapes
      // on non-Chinese system locales. English keeps Chinese glyphs through
      // the theme's text locale (_themesFor).
      locale: locale,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: const [L10n.delegate, ...GlobalMaterialLocalizations.delegates],
      // A phone on its side: the cutout's inset on both sides (side_insets). Over everything,
      // the launch screen of a cold start (启动画面).
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          key: _layers,
          data: media.copyWith(disableAnimations: media.disableAnimations || performance.reduceMotion),
          child: AppMotionScope(
            fluid: fluid,
            child: ThemeRevealHost(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (Platform.operatingSystem == 'ohos')
                    EasedKeyboardInset(child: MirroredSideInsets(child: child!))
                  else
                    MirroredSideInsets(child: child!),
                  const LaunchLayer(),
                ],
              ),
            ),
          ),
        );
      },
      home: widget.home ?? const RootGate(),
    );
  }
}
