import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../themes/theme_library.dart';
import '../themes/theme_pack.dart';
import '../ui/theme/accent.dart';

/// 配色从哪来。
enum AccentSource {
  /// 六套预设之一([AppearanceSettings.presetId])。
  preset,

  /// 用户挑的颜色([AppearanceSettings.customColor]),过对比度守卫。
  custom,

  /// 系统壁纸取色(Android 12 起)。
  wallpaper,
}

/// 外观设置里的配色部分。外观模式(浅 / 深 / 跟随系统)仍在
/// `settings_state.dart` 的 `themeMode`,只是界面挪到了外观页。
class AppearanceSettings {
  const AppearanceSettings({
    this.source = AccentSource.preset,
    this.presetId = 'mist',
    this.customColor = defaultCustom,
    this.themePackId,
    this.loaded = false,
  });

  final AccentSource source;

  /// 最近一次选的预设;切到自定义 / 壁纸再切回来时用。
  final String presetId;

  /// 自定义色(ARGB),守卫之前的原色。
  final int customColor;

  /// 当前启用的主题包 ID(内置如 `paper` 或已安装如 `user-xxx`);null 表示默认玻璃主题。
  final String? themePackId;
  final bool loaded;

  /// 自定义色的初值:一抹灰调的苔绿(色相 140°),第一次打开时和六套预设
  /// 都不撞。
  static const defaultCustom = 0xFF5F7A55;

  AppearanceSettings copyWith({
    AccentSource? source,
    String? presetId,
    int? customColor,
    String? themePackId,
    bool clearThemePack = false,
    bool? loaded,
  }) => AppearanceSettings(
    source: source ?? this.source,
    presetId: presetId ?? this.presetId,
    customColor: customColor ?? this.customColor,
    themePackId: clearThemePack ? null : (themePackId ?? this.themePackId),
    loaded: loaded ?? this.loaded,
  );
}

class AppearanceController extends Notifier<AppearanceSettings> {
  static const _sourceKey = 'appearance.accent_source';
  static const _presetKey = 'appearance.preset';
  static const _customKey = 'appearance.custom_color';
  static const _themePackKey = 'appearance.theme_pack';

  /// 当前配色的浅色主色(ARGB),给原生通知的强调色读
  /// (`DynamicColorPlugin.kt` 的 `ThemeAccent`)。
  static const notifyColorKey = 'appearance.notify_color';

  late Future<void> _loaded;

  @override
  AppearanceSettings build() {
    _loaded = _load();
    return const AppearanceSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final source = AccentSource.values.asNameMap()[prefs.getString(_sourceKey)] ?? AccentSource.preset;
      state = AppearanceSettings(
        source: source,
        presetId: AppAccent.preset(prefs.getString(_presetKey)).id,
        customColor: prefs.getInt(_customKey) ?? AppearanceSettings.defaultCustom,
        themePackId: prefs.getString(_themePackKey),
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): the default palette.
      state = state.copyWith(loaded: true);
    }
  }

  /// 存在读完之后:启动后马上改的值不会被晚到的读取盖掉。
  Future<void> _save(AppearanceSettings next, Future<void> Function(SharedPreferences prefs) write) async {
    await _loaded;
    state = next.copyWith(loaded: true);
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> selectPreset(String id) =>
      _save(state.copyWith(source: AccentSource.preset, presetId: id, clearThemePack: true), (p) async {
        await p.setString(_sourceKey, AccentSource.preset.name);
        await p.setString(_presetKey, id);
        await p.remove(_themePackKey);
      });

  /// 选中自定义;[color] 给了就同时换颜色(色相条、推荐色)。
  Future<void> selectCustom([int? color]) =>
      _save(state.copyWith(source: AccentSource.custom, customColor: color, clearThemePack: true), (p) async {
        await p.setString(_sourceKey, AccentSource.custom.name);
        if (color != null) await p.setInt(_customKey, color);
        await p.remove(_themePackKey);
      });

  Future<void> selectWallpaper() => _save(
    state.copyWith(source: AccentSource.wallpaper, clearThemePack: true),
    (p) async {
      await p.setString(_sourceKey, AccentSource.wallpaper.name);
      await p.remove(_themePackKey);
    },
  );

  /// 启用或退出主题包(传 null 回到常规玻璃主题)。
  Future<void> selectThemePack(String? id) => _save(
    state.copyWith(themePackId: id, clearThemePack: id == null),
    (p) async {
      if (id == null || id.isEmpty) {
        await p.remove(_themePackKey);
      } else {
        await p.setString(_themePackKey, id);
      }
    },
  );

  /// 关掉跟随壁纸:回到上一次的预设。
  Future<void> leaveWallpaper() => selectPreset(state.presetId);
}

final appearanceProvider = NotifierProvider<AppearanceController, AppearanceSettings>(AppearanceController.new);

/// 系统的壁纸取色(Android 12+ 的 `system_accent1_*`)。低版本、取不到时为
/// null,外观页据此整行不显示「跟随壁纸」。
class DynamicColorChannel {
  const DynamicColorChannel([this._methods = const MethodChannel('dsh/dynamic_color')]);

  final MethodChannel _methods;

  /// 壁纸主色(accent1 的中间调);不支持时 null。
  Future<Color?> wallpaperAccent() async {
    try {
      final palette = await _methods.invokeMapMethod<String, Object?>('palette');
      final value = palette?['accent'] ?? palette?['accentLight'];
      return value is int ? Color(value) : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final dynamicColorChannelProvider = Provider<DynamicColorChannel>((ref) => const DynamicColorChannel());

/// 壁纸主色;App 回到前台时重读(用户可能刚换了壁纸)。
final wallpaperAccentProvider = FutureProvider<Color?>((ref) {
  final listener = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(listener.dispose);
  return ref.watch(dynamicColorChannelProvider).wallpaperAccent();
});

/// 当前生效的主题包(未选择或已卸载时为 null)。
final activeThemePackProvider = Provider<ThemePack?>((ref) {
  final id = ref.watch(appearanceProvider.select((s) => s.themePackId));
  if (id == null || id.isEmpty) return null;
  final builtIn = ThemePack.builtInById(id);
  if (builtIn != null) return builtIn;
  return ref.watch(themePackByIdProvider(id)).value;
});

/// 当前生效主题包已动态加载的包内字体族映射。
final activeThemeFontsProvider = Provider<Map<String, String>>((ref) {
  final id = ref.watch(appearanceProvider.select((s) => s.themePackId));
  if (id == null || id.isEmpty || ThemePack.builtInById(id) != null) return const {};
  return ref.watch(themeLoadedFontsProvider(id)).value ?? const {};
});

/// 当前生效的配色。壁纸色还没读到(或读不到)时先用上一次的预设。
final accentProvider = Provider<AppAccent>((ref) {
  final s = ref.watch(appearanceProvider);
  final themePack = ref.watch(activeThemePackProvider);
  if (themePack != null) {
    final packAccent = AppAccent.fromThemePack(themePack);
    if (s.loaded) unawaited(_publishNotifyColor(packAccent));
    return packAccent;
  }
  final preset = AppAccent.preset(s.presetId);
  final accent = switch (s.source) {
    AccentSource.preset => preset,
    AccentSource.custom => AppAccent.derive(Color(s.customColor)),
    AccentSource.wallpaper => switch (ref.watch(wallpaperAccentProvider).value) {
      final c? => AppAccent.derive(c, id: AppAccent.wallpaperId, label: appL10n.stateWallpaper),
      null => preset,
    },
  };
  if (s.loaded) unawaited(_publishNotifyColor(accent));
  return accent;
});

int? _published;

/// 原生通知读这个值给小图标着色;只在变了时写。
Future<void> _publishNotifyColor(AppAccent accent) async {
  final argb = accent.seed.toARGB32();
  if (_published == argb) return;
  _published = argb;
  try {
    await (await SharedPreferences.getInstance()).setInt(AppearanceController.notifyColorKey, argb);
  } catch (_) {
    // Tests: no backend.
  }
}
