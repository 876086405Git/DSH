// 自定义启动画面：用户选的图片、动图或短视频，怎么摆，铺什么底色。文件在
// App 私有目录（`<support>/launch/`），设置存在 shared_preferences 的
// `launch_custom`（一条 JSON：启动时和语言一起读出来，首帧就知道要不要用）。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/container_paths.dart';

/// What the file is.
enum LaunchMediaKind {
  /// PNG, JPEG or a still WebP.
  image,

  /// GIF or animated WebP: played once.
  animation,

  /// A clip (MP4 / WebM, at most [CustomLaunch.maxVideoBytes]): played once, silent, whole.
  video;

  static LaunchMediaKind? byName(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// How the picture sits on the screen.
enum LaunchFit {
  /// Covers the whole screen, cropped at the edges.
  fill,

  /// All of it, centred, on the background colour.
  center,
}

/// The colour around (and under) the picture.
enum LaunchBackdrop {
  /// The launch window's own page colour, light or dark with the system.
  auto,

  /// The colour along the picture's edges, so a centred picture blends into it.
  edge,
  white,
  black;

  static LaunchBackdrop byName(Object? name) {
    for (final b in values) {
      if (b.name == name) return b;
    }
    return auto;
  }
}

/// The user's launch screen.
class CustomLaunch {
  const CustomLaunch({
    required this.kind,
    required this.path,
    required this.width,
    required this.height,
    this.poster,
    this.fit = LaunchFit.fill,
    this.backdrop = LaunchBackdrop.auto,
    this.edge,
    this.zoom = 1,
    this.alignX = 0,
    this.alignY = 0,
    this.on = true,
    this.bytes,
    this.durationMs,
  });

  /// Pictures and animations over this are refused.
  static const maxImageBytes = 8 * 1024 * 1024;

  /// Clips over this are refused (the system picker's budget for a launch screen, too).
  static const maxVideoBytes = 30 * 1024 * 1024;

  /// The closest a [LaunchFit.fill] picture zooms in: a fifth of it across the screen.
  static const maxZoom = 5.0;

  static const prefsKey = 'launch_custom';

  final LaunchMediaKind kind;

  /// The copy in the app's own storage.
  final String path;

  /// The first frame of a clip, a still shown until the clip is playing.
  final String? poster;

  /// Pixel size of the picture (a clip's frame).
  final int width;
  final int height;

  final LaunchFit fit;
  final LaunchBackdrop backdrop;

  /// The edge colour, ARGB ([LaunchBackdrop.edge]); null when it couldn't be read.
  final int? edge;

  /// 1: the picture just covers the screen ([LaunchFit.fill]); up to [maxZoom].
  final double zoom;

  /// Where the screen sits in the picture ([LaunchFit.fill]), -1 (left / top edge) to 1, like an
  /// [Alignment].
  final double alignX;
  final double alignY;

  /// In use. Off: the default launch screen, with this one kept to switch back to.
  final bool on;

  /// The file's size, as copied in.
  final int? bytes;

  /// A clip's length (it plays to its end; this only tells a stalled player from a long clip).
  final int? durationMs;

  /// The colour to lay under the picture, [dark] being the system's mode.
  Color background({required bool dark}) => switch (backdrop) {
    LaunchBackdrop.white => const Color(0xFFFFFFFF),
    LaunchBackdrop.black => const Color(0xFF000000),
    LaunchBackdrop.edge when edge != null => Color(edge!),
    _ => dark ? LaunchColors.nightTop : LaunchColors.mistTop,
  };

  CustomLaunch copyWith({
    LaunchFit? fit,
    LaunchBackdrop? backdrop,
    double? zoom,
    double? alignX,
    double? alignY,
    bool? on,
  }) => CustomLaunch(
    kind: kind,
    path: path,
    width: width,
    height: height,
    poster: poster,
    fit: fit ?? this.fit,
    backdrop: backdrop ?? this.backdrop,
    edge: edge,
    zoom: zoom ?? this.zoom,
    alignX: alignX ?? this.alignX,
    alignY: alignY ?? this.alignY,
    on: on ?? this.on,
    bytes: bytes,
    durationMs: durationMs,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'path': path,
    'width': width,
    'height': height,
    'poster': ?poster,
    'fit': fit.name,
    'backdrop': backdrop.name,
    'edge': ?edge,
    if (zoom != 1) 'zoom': zoom,
    if (alignX != 0) 'alignX': alignX,
    if (alignY != 0) 'alignY': alignY,
    'on': on,
    'bytes': ?bytes,
    'durationMs': ?durationMs,
  };

  static CustomLaunch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = LaunchMediaKind.byName(raw['kind']);
    final path = raw['path'];
    final width = raw['width'];
    final height = raw['height'];
    if (kind == null || path is! String || path.isEmpty || width is! int || height is! int) return null;
    if (width <= 0 || height <= 0) return null;
    double unit(Object? v, double fallback, {double lo = 0, double hi = 1}) =>
        v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
    final poster = raw['poster'];
    final edge = raw['edge'];
    return CustomLaunch(
      kind: kind,
      path: path,
      width: width,
      height: height,
      poster: poster is String && poster.isNotEmpty ? poster : null,
      fit: raw['fit'] == LaunchFit.center.name ? LaunchFit.center : LaunchFit.fill,
      backdrop: LaunchBackdrop.byName(raw['backdrop']),
      edge: edge is int ? edge : null,
      zoom: unit(raw['zoom'], 1, lo: 1, hi: maxZoom),
      alignX: unit(raw['alignX'], 0, lo: -1, hi: 1),
      alignY: unit(raw['alignY'], 0, lo: -1, hi: 1),
      on: raw['on'] != false,
      bytes: raw['bytes'] is int ? raw['bytes'] as int : null,
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : null,
    );
  }

  /// The stored launch screen (in use or not), or null (none, unreadable, or its file is gone).
  static Future<CustomLaunch?> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final raw = store.getString(prefsKey);
      if (raw == null) return null;
      var json = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final paths = ContainerPaths.enabled ? await ContainerPaths.load() : null;
      if (paths != null) {
        final relocated = await paths.decodeOwned(json, 'launch');
        if (relocated == null) return null;
        json = relocated;
      }
      final custom = fromJson(json);
      if (custom == null || !File(custom.path).existsSync()) return null;
      if (paths != null) {
        final saved = jsonEncode(await paths.encodeOwned(custom.toJson(), 'launch'));
        if (saved != raw) {
          try {
            await store.setString(prefsKey, saved);
          } catch (_) {
            // A migrated in-memory value remains usable if preferences cannot be written.
          }
        }
      }
      return custom;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CustomLaunch custom) async {
    final prefs = await SharedPreferences.getInstance();
    final json = ContainerPaths.enabled
        ? await (await ContainerPaths.load()).encodeOwned(custom.toJson(), 'launch')
        : custom.toJson();
    await prefs.setString(prefsKey, jsonEncode(json));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsKey);
  }

  @override
  bool operator ==(Object other) =>
      other is CustomLaunch &&
      other.kind == kind &&
      other.path == path &&
      other.poster == poster &&
      other.width == width &&
      other.height == height &&
      other.fit == fit &&
      other.backdrop == backdrop &&
      other.edge == edge &&
      other.zoom == zoom &&
      other.alignX == alignX &&
      other.alignY == alignY &&
      other.on == on &&
      other.bytes == bytes &&
      other.durationMs == durationMs;

  @override
  int get hashCode =>
      Object.hash(kind, path, poster, width, height, fit, backdrop, edge, zoom, alignX, alignY, on, bytes, durationMs);
}

/// The Android launch window's colours (res/values{,-night}/colors.xml `launch_background_*`)
/// and the wordmark's ink on them. Fixed like the window itself: a palette or theme chosen in
/// the app doesn't reach the system's launch window. test/launch/launch_colors_test.dart reads
/// colors.xml to keep them equal.
abstract final class LaunchColors {
  static const mistTop = Color(0xFFEBF1FE);
  static const mistBottom = Color(0xFFF6F7FC);
  static const nightTop = Color(0xFF1D222C);
  static const nightBottom = Color(0xFF1B1C23);

  /// The wordmark: the default palette's main text on each.
  static const ink = Color(0xFF1E232E);
  static const paper = Color(0xFFE6E9F0);
}
