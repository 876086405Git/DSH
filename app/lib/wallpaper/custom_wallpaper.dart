// 自定义壁纸：用户选的一张图片，铺在首页、对话和抽屉后面。文件在 App 私有目录
// （`<support>/wallpaper/`），设置存在 shared_preferences 的 `wallpaper_custom`（一条 JSON）。
//
// 取景（缩放 + 位置）按屏幕比例存成相对值，换屏幕尺寸、横竖屏都还对得上；模糊一份，
// 提亮（浅色）和压暗（深色）各一份。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/container_paths.dart';

/// The user's wallpaper and how it sits.
class CustomWallpaper {
  const CustomWallpaper({
    required this.path,
    required this.width,
    required this.height,
    this.edge,
    this.zoom = 1,
    this.alignX = 0,
    this.alignY = 0,
    this.blur = defaultBlur,
    this.lighten = defaultLighten,
    this.dim = defaultDim,
    this.on = true,
  });

  /// Files over this are refused (the system picker's budget, too).
  static const maxBytes = 15 * 1024 * 1024;

  /// The closest it zooms in: a fifth of the picture across the screen.
  static const maxZoom = 5.0;

  static const defaultBlur = 0.3;
  static const defaultLighten = 0.2;
  static const defaultDim = 0.2;

  static const prefsKey = 'wallpaper_custom';

  /// The copy in the app's own storage.
  final String path;

  /// Pixel size of the picture (its first frame).
  final int width;
  final int height;

  /// The colour along the picture's edges (ARGB), read on import; drawn while it loads.
  final int? edge;

  /// 1: the picture just covers the screen; up to [maxZoom].
  final double zoom;

  /// Where the screen sits in the picture, -1 (left / top edge) to 1, like an [Alignment].
  final double alignX;
  final double alignY;

  /// 0–1: how soft the picture is ([WallpaperLook.blurSigma]).
  final double blur;

  /// 0–1: the page's own colour laid over the picture, in light mode ([lighten]) and in dark
  /// mode ([dim]). Text keeps its contrast whatever these say ([WallpaperLook]).
  final double lighten;
  final double dim;

  /// In use. Off: the default backdrop, with this one kept to switch back to.
  final bool on;

  /// [lighten] or [dim], for a page in [brightness].
  double toneFor(Brightness brightness) => brightness == Brightness.dark ? dim : lighten;

  /// The part of the picture (its pixels) a [screen]-shaped window shows.
  Rect window(Size screen) => windowIn(Size(width.toDouble(), height.toDouble()), screen);

  /// The same window in a picture [picture] large (a downscaled decode of it).
  Rect windowIn(Size picture, Size screen) {
    if (picture.isEmpty || screen.isEmpty) return Offset.zero & picture;
    final cover = (picture.width / picture.height > screen.width / screen.height)
        ? Size(picture.height * screen.width / screen.height, picture.height)
        : Size(picture.width, picture.width * screen.height / screen.width);
    final z = zoom.clamp(1.0, maxZoom);
    final seen = Size(cover.width / z, cover.height / z);
    final spareX = picture.width - seen.width;
    final spareY = picture.height - seen.height;
    return Rect.fromLTWH(
      spareX / 2 * (1 + alignX.clamp(-1.0, 1.0)),
      spareY / 2 * (1 + alignY.clamp(-1.0, 1.0)),
      seen.width,
      seen.height,
    );
  }

  CustomWallpaper copyWith({
    double? zoom,
    double? alignX,
    double? alignY,
    double? blur,
    double? lighten,
    double? dim,
    bool? on,
  }) => CustomWallpaper(
    path: path,
    width: width,
    height: height,
    edge: edge,
    zoom: zoom ?? this.zoom,
    alignX: alignX ?? this.alignX,
    alignY: alignY ?? this.alignY,
    blur: blur ?? this.blur,
    lighten: lighten ?? this.lighten,
    dim: dim ?? this.dim,
    on: on ?? this.on,
  );

  /// [tone] as the value for [brightness].
  CustomWallpaper withTone(Brightness brightness, double tone) =>
      brightness == Brightness.dark ? copyWith(dim: tone) : copyWith(lighten: tone);

  /// A new picture in place of this one: how it sits starts over, the look is kept.
  CustomWallpaper replacedBy({required String path, required int width, required int height, int? edge}) =>
      CustomWallpaper(path: path, width: width, height: height, edge: edge, blur: blur, lighten: lighten, dim: dim);

  Map<String, Object?> toJson() => {
    'path': path,
    'width': width,
    'height': height,
    'edge': ?edge,
    'zoom': zoom,
    'alignX': alignX,
    'alignY': alignY,
    'blur': blur,
    'lighten': lighten,
    'dim': dim,
    'on': on,
  };

  static CustomWallpaper? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final width = raw['width'];
    final height = raw['height'];
    if (path is! String || path.isEmpty || width is! int || height is! int || width <= 0 || height <= 0) {
      return null;
    }
    double unit(Object? v, double fallback, {double lo = 0, double hi = 1}) =>
        v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
    final edge = raw['edge'];
    return CustomWallpaper(
      path: path,
      width: width,
      height: height,
      edge: edge is int ? edge : null,
      zoom: unit(raw['zoom'], 1, lo: 1, hi: maxZoom),
      alignX: unit(raw['alignX'], 0, lo: -1),
      alignY: unit(raw['alignY'], 0, lo: -1),
      blur: unit(raw['blur'], defaultBlur),
      lighten: unit(raw['lighten'], defaultLighten),
      dim: unit(raw['dim'], defaultDim),
      on: raw['on'] != false,
    );
  }

  /// The stored wallpaper (in use or not), or null (none, unreadable, or its file is gone).
  static Future<CustomWallpaper?> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final raw = store.getString(prefsKey);
      if (raw == null) return null;
      var json = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final paths = ContainerPaths.enabled ? await ContainerPaths.load() : null;
      if (paths != null) {
        final relocated = await paths.decodeOwned(json, 'wallpaper');
        if (relocated == null) return null;
        json = relocated;
      }
      final wallpaper = fromJson(json);
      if (wallpaper == null || !File(wallpaper.path).existsSync()) return null;
      if (paths != null) {
        final saved = jsonEncode(await paths.encodeOwned(wallpaper.toJson(), 'wallpaper'));
        if (saved != raw) {
          try {
            await store.setString(prefsKey, saved);
          } catch (_) {
            // A migrated in-memory value remains usable if preferences cannot be written.
          }
        }
      }
      return wallpaper;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CustomWallpaper wallpaper) async {
    final prefs = await SharedPreferences.getInstance();
    final json = ContainerPaths.enabled
        ? await (await ContainerPaths.load()).encodeOwned(wallpaper.toJson(), 'wallpaper')
        : wallpaper.toJson();
    await prefs.setString(prefsKey, jsonEncode(json));
  }

  @override
  bool operator ==(Object other) =>
      other is CustomWallpaper &&
      other.path == path &&
      other.width == width &&
      other.height == height &&
      other.edge == edge &&
      other.zoom == zoom &&
      other.alignX == alignX &&
      other.alignY == alignY &&
      other.blur == blur &&
      other.lighten == lighten &&
      other.dim == dim &&
      other.on == on;

  @override
  int get hashCode => Object.hash(path, width, height, edge, zoom, alignX, alignY, blur, lighten, dim, on);
}
