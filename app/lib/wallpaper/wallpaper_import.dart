// 自定义壁纸的导入：就是启动画面那条链路（lib/launch/launch_import.dart：系统选择器 → 按字节
// 上限流式拷进私有目录 → 看文件头认类型 → 解码一遍确认能读、取边缘色），换成壁纸的预算：
// 只要照片、15 MB 以内、放 `<support>/wallpaper/`。动图只用第一帧（渲染时只取首帧）。

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../launch/custom_launch.dart' show CustomLaunch;
import '../launch/launch_import.dart';
import '../plugins/native/native_file_platform.dart';
import 'custom_wallpaper.dart';

export '../launch/launch_import.dart' show LaunchImportProblem;

/// Picks a photo and keeps a copy as the wallpaper.
class WallpaperImport {
  WallpaperImport({NativeFilePlatform? platform, Future<Directory> Function()? directory, DateTime Function()? now})
    : directory = directory ?? wallpaperDirectory,
      _launch = LaunchImport(
        platform: platform,
        directory: directory ?? wallpaperDirectory,
        now: now,
        maxBytes: CustomWallpaper.maxBytes,
        videos: false,
        action: 'wallpaper',
      );

  final Future<Directory> Function() directory;
  final LaunchImport _launch;

  /// `<app support>/wallpaper`: the app's own storage, not backed up, not visible to other apps.
  static Future<Directory> wallpaperDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/wallpaper').create(recursive: true);
  }

  /// The system picker (photos), then [keep].
  Future<(CustomWallpaper?, LaunchImportProblem?)> pick({CustomWallpaper? previous}) async {
    final (launch, problem) = await _launch.pick();
    return _adopt(launch, problem, previous);
  }

  /// Copies [bytes] into the wallpaper folder and checks them; [previous]'s look comes along, its
  /// framing doesn't (its file stays until the new one is saved).
  Future<(CustomWallpaper?, LaunchImportProblem?)> keep(Stream<List<int>> bytes, {CustomWallpaper? previous}) async {
    final (launch, problem) = await _launch.keep(bytes);
    return _adopt(launch, problem, previous);
  }

  /// The launch import's result (a still or the first frame of an animation, read and checked)
  /// as the wallpaper.
  Future<(CustomWallpaper?, LaunchImportProblem?)> _adopt(
    CustomLaunch? launch,
    LaunchImportProblem? problem,
    CustomWallpaper? previous,
  ) async {
    if (launch == null) return (null, problem ?? LaunchImportProblem.unreadable);
    final wallpaper =
        previous?.replacedBy(path: launch.path, width: launch.width, height: launch.height, edge: launch.edge) ??
        CustomWallpaper(path: launch.path, width: launch.width, height: launch.height, edge: launch.edge);
    return (wallpaper, null);
  }

  /// Deletes a wallpaper file; nothing if it's already gone.
  static Future<void> removeFile(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
