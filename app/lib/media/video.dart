import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/artifact_files.dart';
import '../state/artifacts.dart';

/// No URL entry point: the caller must materialize through its captured Host.
class MediaVideoChannel {
  const MediaVideoChannel([this.channel = const MethodChannel('dsh/media_video')]) : _refreshMaterializedPoster = false;
  const MediaVideoChannel.ohos([this.channel = const MethodChannel('dsh/media_video')])
    : _refreshMaterializedPoster = true;
  // The viewer has explicitly materialized this file again. OH refreshes its
  // poster then; ordinary scrolling and the default channel retain the cache.
  final bool _refreshMaterializedPoster;
  final MethodChannel channel;

  // One decoder request at a time across channel instances. Queued requests
  // retain paths only, never decoded frames or full video buffers.
  static Future<void> _posterTail = Future<void>.value();

  Future<MediaVideoHandle> open(String path) async {
    _localPath(path);
    final Map<String, dynamic>? value;
    try {
      value = await channel.invokeMapMethod<String, dynamic>('open', {'path': path});
    } on MissingPluginException {
      throw PlatformException(code: 'unsupported');
    }
    if (value == null) throw PlatformException(code: 'unsupported');
    return MediaVideoHandle(
      texture: (value['texture'] as num).toInt(),
      width: (value['width'] as num).toInt(),
      height: (value['height'] as num).toInt(),
      durationMs: (value['durationMs'] as num).toInt(),
      rotation: (value['rotation'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Uint8List?> poster(String path) {
    _localPath(path);
    final request = _posterTail.then((_) async {
      try {
        return await channel.invokeMethod<Uint8List>('poster', {'path': path});
      } on MissingPluginException {
        return null;
      }
    });
    _posterTail = request.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return request;
  }

  Future<void> play(int texture) => channel.invokeMethod<void>('play', {'texture': texture});
  Future<void> pause(int texture) => channel.invokeMethod<void>('pause', {'texture': texture});
  Future<void> seek(int texture, int positionMs) =>
      channel.invokeMethod<void>('seek', {'texture': texture, 'positionMs': positionMs});
  Future<void> close(int texture) => channel.invokeMethod<void>('close', {'texture': texture});
  Future<MediaVideoState> state(int texture) async {
    final value = await channel.invokeMapMethod<String, dynamic>('state', {'texture': texture});
    if (value == null) throw PlatformException(code: 'closed');
    return MediaVideoState(
      positionMs: (value['positionMs'] as num).toInt(),
      durationMs: (value['durationMs'] as num).toInt(),
      playing: value['playing'] == true,
    );
  }

  static void _localPath(String path) {
    if (!path.startsWith('/') || Uri.tryParse(path)?.hasScheme == true) {
      throw ArgumentError.value(path, 'path', 'Expected an absolute local materialized file');
    }
  }
}

class MediaVideoHandle {
  const MediaVideoHandle({
    required this.texture,
    required this.width,
    required this.height,
    required this.durationMs,
    this.rotation = 0,
  });
  final int texture;
  final int width;
  final int height;
  final int durationMs;
  final int rotation;
  double get aspectRatio => width > 0 && height > 0 ? width / height : 16 / 9;
}

class MediaVideoState {
  const MediaVideoState({required this.positionMs, required this.durationMs, required this.playing});
  final int positionMs;
  final int durationMs;
  final bool playing;
}

final mediaVideoChannelProvider = Provider<MediaVideoChannel>(
  (ref) => ref.watch(operatingSystemProvider) == 'ohos' ? const MediaVideoChannel.ohos() : const MediaVideoChannel(),
);

// Keyed by captured ArtifactFiles, not a mutable active-host provider. Bounded
// per Host snapshot, with weak ownership when that connection is discarded.
final _posters = Expando<Map<(String, String), Future<ImageProvider?>>>();

/// Card thumbnail: NEVER downloads a remote video simply because it scrolled
/// into view. Remote posters become available after an explicit viewer open.
Future<ImageProvider?> mediaVideoThumbnail(
  ArtifactFiles files,
  MediaVideoChannel video,
  String sessionId,
  MediaItem item,
) {
  final cache = _posters[files] ??= {};
  final key = (sessionId, item.path);
  if (cache[key] case final existing?) return existing;
  if (!files.isLocal) return Future.value(null);
  return cacheMediaVideoThumbnail(files, video, sessionId, item);
}

/// After user-requested materialization, also seed the card's remote poster.
Future<ImageProvider?> cacheMediaVideoThumbnail(
  ArtifactFiles files,
  MediaVideoChannel video,
  String sessionId,
  MediaItem item, {
  File? materialized,
}) {
  final cache = _posters[files] ??= {};
  final key = (sessionId, item.path);
  if (!video._refreshMaterializedPoster || materialized == null) {
    if (cache[key] case final existing?) return existing;
  }
  if (materialized == null && !files.isLocal) return Future.value(null);
  if (cache.length >= 24 && !cache.containsKey(key)) cache.remove(cache.keys.first);
  final future = () async {
    try {
      final file =
          materialized ??
          await files.materialize(sessionId, Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0));
      final bytes = await video.poster(file.path);
      return bytes == null || bytes.isEmpty ? null : MemoryImage(bytes);
    } catch (_) {
      // Optional decoration: a failed poster never prevents playback or retries.
      return null;
    }
  }();
  cache[key] = future;
  future.then((value) {
    if (value == null && identical(cache[key], future)) cache.remove(key);
  });
  return future;
}

String mediaVideoTime(int milliseconds) {
  final seconds = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
