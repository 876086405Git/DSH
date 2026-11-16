// 自定义启动画面的导入：系统选择器（插件 v2 的 pickFile 通道，照片 + 视频）→ 按字节上限
// （视频 30 MB，图片和动图 8 MB）流式拷进 App 私有目录 → 看文件头认类型 → 解码一遍确认能读
// （视频由原生量时长和尺寸、截首帧，时长不设上限）→ 落盘，换掉旧文件。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../plugins/native/native_effects.dart';
import '../plugins/native/native_file_platform.dart';
import 'custom_launch.dart';

/// Why a picked file didn't become the launch screen.
enum LaunchImportProblem {
  /// The picker was closed without a choice.
  cancelled,

  /// No system picker (or it is busy with something else).
  unavailable,

  /// A picture or an animation over [LaunchImport.maxPictureBytes] (the launch screen's 8 MB,
  /// the wallpaper's 15).
  tooLarge,

  /// Next to clips: anything over [LaunchImport.maxBytes] (the launch screen's 30 MB), known
  /// before it is read.
  overLimit,

  /// Not a PNG, JPEG, WebP, GIF, MP4 or WebM.
  unsupported,

  /// It says it is a picture but doesn't decode.
  unreadable,
}

/// What the file is, from its first bytes.
enum LaunchFileType {
  png('png'),
  jpeg('jpg'),
  gif('gif'),
  webp('webp'),
  mp4('mp4'),
  webm('webm');

  const LaunchFileType(this.extension);

  final String extension;

  bool get isVideo => this == mp4 || this == webm;

  static LaunchFileType? sniff(Uint8List head) {
    bool at(int offset, List<int> bytes) {
      if (head.length < offset + bytes.length) return false;
      for (var i = 0; i < bytes.length; i++) {
        if (head[offset + i] != bytes[i]) return false;
      }
      return true;
    }

    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return png;
    if (at(0, const [0xFF, 0xD8, 0xFF])) return jpeg;
    if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) return gif;
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return webp;
    if (at(4, 'ftyp'.codeUnits)) return mp4;
    if (at(0, const [0x1A, 0x45, 0xDF, 0xA3])) return webm;
    return null;
  }
}

/// What the native side reads off a clip (`dsh/launch_clip` `probe`).
class ClipProbe {
  const ClipProbe({required this.duration, required this.width, required this.height});

  final Duration duration;

  /// The frame as shown (rotation applied).
  final int width;
  final int height;
}

/// Reads a clip's length and size and saves its first frame as a PNG at `poster`; null when it
/// isn't a playable video.
typedef ClipProber = Future<ClipProbe?> Function(String path, String poster);

/// Picks a picture or clip and keeps a copy as the launch screen.
class LaunchImport {
  LaunchImport({
    NativeFilePlatform? platform,
    ClipProber? probeClip,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
    this.maxBytes = CustomLaunch.maxVideoBytes,
    this.videos = true,
    this.action = 'launch',
  }) : platform = platform ?? MethodNativeFilePlatform(),
       probeClip = probeClip ?? _probeClip,
       directory = directory ?? launchDirectory,
       now = now ?? DateTime.now;

  final NativeFilePlatform platform;
  final ClipProber probeClip;
  final Future<Directory> Function() directory;
  final DateTime Function() now;

  /// Files over this are refused (the picker's budget too): the launch screen's 30 MB by default,
  /// the wallpaper's own (15 MB) for its import.
  final int maxBytes;

  /// Clips too (the launch screen). False: the picker shows photos only, and a clip is
  /// [LaunchImportProblem.unsupported] (the wallpaper's import).
  final bool videos;

  /// A picture or an animation over this is [LaunchImportProblem.tooLarge]: it is decoded whole.
  /// Next to clips (the launch screen) that is 8 MB; photos only (the wallpaper), [maxBytes].
  int get maxPictureBytes => videos ? math.min(CustomLaunch.maxImageBytes, maxBytes) : maxBytes;

  /// Over [maxBytes]: next to clips, [LaunchImportProblem.overLimit] (a picture's own limit is
  /// lower); photos only, the picture is [LaunchImportProblem.tooLarge].
  LaunchImportProblem get _over => videos ? LaunchImportProblem.overLimit : LaunchImportProblem.tooLarge;

  /// The picker request's name.
  final String action;

  /// `<app support>/launch`: the app's own storage, not backed up, not visible to other apps.
  static Future<Directory> launchDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/launch').create(recursive: true);
  }

  /// The system picker (photos and videos), then [keep]. [previous] is replaced on success.
  Future<(CustomLaunch?, LaunchImportProblem?)> pick({CustomLaunch? previous}) async {
    final owner = _owner();
    try {
      if (!await platform.supported()) return (null, LaunchImportProblem.unavailable);
      final List<NativeSelectedFile> files;
      try {
        files = await platform.pick(
          PickFileEffect(
            request: owner,
            action: action,
            images: true,
            visual: videos,
            maxFiles: 1,
            own: true,
            maxBytes: maxBytes,
            maxTotalBytes: maxBytes,
          ),
        );
      } on PlatformException catch (e) {
        return (null, e.code == 'too-large' ? _over : LaunchImportProblem.unavailable);
      }
      if (files.isEmpty) return (null, LaunchImportProblem.cancelled);
      final file = files.first;
      if ((file.length ?? 0) > maxBytes) return (null, _over);
      return await keep(file.openRead(), previous: previous);
    } on PlatformException catch (e) {
      return (null, e.code == 'too-large' ? _over : LaunchImportProblem.unreadable);
    } catch (_) {
      return (null, LaunchImportProblem.unreadable);
    } finally {
      unawaited(platform.cancel(owner));
    }
  }

  /// Copies [bytes] into the launch folder, checks it and returns the launch screen it makes
  /// ([previous] lends its fit and background; its files stay until the new one is saved).
  Future<(CustomLaunch?, LaunchImportProblem?)> keep(Stream<List<int>> bytes, {CustomLaunch? previous}) async {
    final dir = await directory();
    final stamp = now().microsecondsSinceEpoch;
    final incoming = File('${dir.path}/incoming-$stamp');
    final created = <File>[incoming];
    try {
      final sink = incoming.openWrite();
      var total = 0;
      var over = false;
      try {
        await for (final chunk in bytes) {
          total += chunk.length;
          if (total > maxBytes) {
            over = true;
            break;
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (over) return (null, _over);
      if (total == 0) return (null, LaunchImportProblem.unreadable);
      final head = await _head(incoming);
      final type = LaunchFileType.sniff(head);
      if (type == null || (type.isVideo && !videos)) return (null, LaunchImportProblem.unsupported);
      // A picture or an animation is decoded whole: the launch screen's are held to 8 MB.
      if (!type.isVideo && total > maxPictureBytes) return (null, LaunchImportProblem.tooLarge);
      final kept = File('${dir.path}/custom-$stamp.${type.extension}');
      await incoming.rename(kept.path);
      created
        ..remove(incoming)
        ..add(kept);
      final CustomLaunch custom;
      if (type.isVideo) {
        final poster = File('${dir.path}/custom-$stamp-poster.png');
        created.add(poster);
        final probe = await probeClip(kept.path, poster.path);
        if (probe == null || !poster.existsSync()) return (null, LaunchImportProblem.unreadable);
        final look = await _look(poster.path);
        custom = CustomLaunch(
          kind: LaunchMediaKind.video,
          path: kept.path,
          poster: poster.path,
          width: probe.width,
          height: probe.height,
          fit: previous?.fit ?? LaunchFit.fill,
          backdrop: previous?.backdrop ?? LaunchBackdrop.auto,
          edge: look?.edge,
          bytes: total,
          durationMs: probe.duration.inMilliseconds,
        );
      } else {
        final look = await _look(kept.path);
        if (look == null) return (null, LaunchImportProblem.unreadable);
        custom = CustomLaunch(
          kind: look.frames > 1 ? LaunchMediaKind.animation : LaunchMediaKind.image,
          path: kept.path,
          width: look.width,
          height: look.height,
          // A cut-out picture (a logo) sits whole on its colour; a photo fills.
          fit: look.see ? LaunchFit.center : LaunchFit.fill,
          backdrop: previous?.backdrop ?? (look.see || look.edge == null ? LaunchBackdrop.auto : LaunchBackdrop.edge),
          edge: look.edge,
          bytes: total,
        );
      }
      created.clear();
      return (custom, null);
    } finally {
      for (final f in created) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Deletes [custom]'s files (not those [except] still uses).
  static Future<void> removeFiles(CustomLaunch? custom, {CustomLaunch? except}) async {
    if (custom == null) return;
    for (final path in [custom.path, custom.poster]) {
      if (path == null || path == except?.path || path == except?.poster) continue;
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  static Future<Uint8List> _head(File file) async {
    final raf = await file.open();
    try {
      return await raf.read(32);
    } finally {
      await raf.close();
    }
  }

  static String _owner() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
    final random = math.Random.secure();
    return String.fromCharCodes([for (var i = 0; i < 32; i++) chars.codeUnitAt(random.nextInt(chars.length))]);
  }

  static Future<ClipProbe?> _probeClip(String path, String poster) async {
    try {
      final raw = await const MethodChannel('dsh/launch_clip')
          .invokeMapMethod<String, Object?>('probe', {'path': path, 'poster': poster});
      final ms = raw?['durationMs'];
      final width = raw?['width'];
      final height = raw?['height'];
      if (ms is! int || width is! int || height is! int || width <= 0 || height <= 0) return null;
      return ClipProbe(
        duration: Duration(milliseconds: ms),
        width: width,
        height: height,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// A picture read once on import: its size, frame count and the colour along its edges.
class PictureLook {
  const PictureLook({required this.width, required this.height, required this.frames, this.edge, this.see = false});

  final int width;
  final int height;
  final int frames;

  /// The average colour of the edge pixels (ARGB), null when the edge is mostly see-through.
  final int? edge;

  /// The edge is mostly see-through: a cut-out (a logo).
  final bool see;
}

/// Decodes [path] (small) to check it reads and to take its edge colour; null if it doesn't.
Future<PictureLook?> _look(String path) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
    final scale = math.min(1.0, 64 / math.max(width, height));
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return null;
    final (edge, see) = edgeColour(data.buffer.asUint8List(), image.width, image.height);
    return PictureLook(width: width, height: height, frames: codec.frameCount, edge: edge, see: see);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// The mean colour of the outermost ring of [rgba] (straight alpha, [w] × [h]), and whether
/// that ring is mostly see-through (then there's no colour to take).
(int?, bool) edgeColour(Uint8List rgba, int w, int h) {
  var r = 0, g = 0, b = 0, n = 0, all = 0;
  void take(int x, int y) {
    final i = (y * w + x) * 4;
    all++;
    if (rgba[i + 3] < 230) return;
    r += rgba[i];
    g += rgba[i + 1];
    b += rgba[i + 2];
    n++;
  }

  for (var x = 0; x < w; x++) {
    take(x, 0);
    if (h > 1) take(x, h - 1);
  }
  for (var y = 1; y < h - 1; y++) {
    take(0, y);
    if (w > 1) take(w - 1, y);
  }
  if (all == 0 || n < all * 0.6) return (null, true);
  return (0xFF000000 | ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n), false);
}
