// 设置 › 主题 › 壁纸: the user's own wallpaper (lib/wallpaper/custom_wallpaper.dart), whether it's
// the one in use, and the picture baked for the screen it's on.

import 'dart:ui' as ui;
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../performance/performance_state.dart';
import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';
import '../wallpaper/wallpaper_render.dart';

export '../wallpaper/wallpaper_import.dart' show LaunchImportProblem;

final wallpaperImportProvider = Provider<WallpaperImport>((ref) => WallpaperImport());

/// Bakes for the backdrop and the settings' small phones; keeps the last decoded picture.
final wallpaperRendererProvider = Provider<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// The stored wallpaper (null: none chosen yet, or its file is gone).
final customWallpaperProvider = AsyncNotifierProvider<CustomWallpaperController, CustomWallpaper?>(
  CustomWallpaperController.new,
);

class CustomWallpaperController extends AsyncNotifier<CustomWallpaper?> {
  @override
  Future<CustomWallpaper?> build() => CustomWallpaper.load();

  /// The system picker; the pick becomes the wallpaper in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = await _current;
    final (wallpaper, problem) = await ref.read(wallpaperImportProvider).pick(previous: previous);
    if (wallpaper == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(wallpaper);
    // Only now: until the new one is saved, the old file is the one the next launch reads.
    if (previous != null && previous.path != wallpaper.path) await WallpaperImport.removeFile(previous.path);
    return null;
  }

  /// The stored wallpaper, once it's read.
  Future<CustomWallpaper?> get _current async {
    if (state.hasValue) return state.value;
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  /// The custom one in use (true) or the default backdrop (false); the picture stays either way.
  Future<void> use(bool custom) async {
    final current = await _current;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  /// Where the screen sits in the picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = await _current;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomWallpaper.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> setBlur(double blur) async {
    final current = await _current;
    if (current == null || current.blur == blur) return;
    await _store(current.copyWith(blur: blur.clamp(0.0, 1.0)));
  }

  /// 提亮 (light mode) or 压暗 (dark mode).
  Future<void> setTone(Brightness brightness, double tone) async {
    final current = await _current;
    if (current == null || current.toneFor(brightness) == tone) return;
    await _store(current.withTone(brightness, tone.clamp(0.0, 1.0)));
  }

  /// 自动保证文字清晰: off, the picture is only as soft and as calm as the sliders say.
  Future<void> setGuard(bool guard) async {
    final current = await _current;
    if (current == null || current.guard == guard) return;
    await _store(current.copyWith(guard: guard));
  }

  /// 播放动图, or its first frame only.
  Future<void> setPlay(bool play) async {
    final current = await _current;
    if (current == null || current.play == play) return;
    await _store(current.copyWith(play: play));
  }

  Future<void> _store(CustomWallpaper wallpaper) async {
    state = AsyncData(wallpaper);
    await CustomWallpaper.save(wallpaper);
  }
}

/// The wallpaper baked for [WallpaperFrame]; null: the default backdrop (none chosen, switched
/// off, or the picture can't be read — the page never breaks over it).
final wallpaperImageProvider = FutureProvider.autoDispose.family<ui.Image?, WallpaperFrame>((ref, frame) async {
  final CustomWallpaper? wallpaper;
  try {
    wallpaper = await ref.watch(customWallpaperProvider.future);
  } catch (_) {
    return null;
  }
  if (wallpaper == null || !wallpaper.on) return null;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final on = frame.copyWith(lightweight: lightweight);
  final image = await ref.read(wallpaperRendererProvider).bake(wallpaper, on, moving: on.plays(wallpaper));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});

/// Bakes a page's own picture ([sceneImageProvider]); apart from [wallpaperRendererProvider], so
/// the app's wallpaper stays decoded meanwhile.
final _sceneRendererProvider = Provider.autoDispose<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// A page's own picture (a tavern chat's background, `WallpaperBackdrop.scene`) baked for its
/// frame the way the wallpaper is; null when it can't be read. Always its first frame under the
/// guard's veil, whatever the picture says of itself: its page has no switch for either.
final sceneImageProvider = FutureProvider.autoDispose.family<ui.Image?, (CustomWallpaper, WallpaperFrame)>((
  ref,
  key,
) async {
  final (picture, frame) = key;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final on = frame.copyWith(lightweight: lightweight);
  final image = await ref.watch(_sceneRendererProvider).bake(picture.copyWith(guard: true), on);
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});
