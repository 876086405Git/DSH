// A custom launch screen's clip: the platform's player on a Flutter texture
// (android/.../launch/LaunchClipPlugin.kt, Runner/LaunchChannel.swift, `dsh/launch_clip`), silent,
// played once. Its first
// frame, saved as a poster on import, shows at once and stays under the texture, so the switch
// to the playing clip can't be seen; the last frame stays when it ends.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'custom_launch.dart';
import 'launch_media.dart';

/// The native side, one channel for all clips.
class LaunchClipChannel {
  LaunchClipChannel._() {
    _channel.setMethodCallHandler((call) async {
      final raw = call.arguments;
      final id = raw is Map ? raw['texture'] : null;
      if (id is! int) return;
      final clip = _open[id];
      if (clip == null) return;
      switch (call.method) {
        case 'showing':
          clip._showing();
        case 'done':
          clip._done();
      }
    });
  }

  static final instance = LaunchClipChannel._();

  static const _channel = MethodChannel('dsh/launch_clip');
  final _open = <int, LaunchClip>{};

  Future<int?> open(String path) async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('open', {'path': path});
      final id = raw?['texture'];
      return id is int ? id : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> play(int texture) => _quiet('play', texture);

  Future<void> close(int texture) {
    _open.remove(texture);
    return _quiet('close', texture);
  }

  Future<void> _quiet(String method, int texture) async {
    try {
      await _channel.invokeMethod<Object?>(method, {'texture': texture});
    } on MissingPluginException {
      // Nothing to talk to.
    } on PlatformException {
      // The clip is gone; the poster stays.
    }
  }
}

/// A short clip as a launch picture.
class LaunchClip extends LaunchMedia {
  LaunchClip._(this._poster, this._size, this._length);

  final ui.Image _poster;
  final Size _size;

  /// How long it may take to play: a player that never reports the end stops counting here.
  final Duration _length;

  int? _texture;
  bool _shown = false;
  bool _wantPlay = false;
  bool _disposed = false;
  VoidCallback? _onDone;
  Timer? _safety;

  /// Opens [custom]'s clip: its poster first (null when that doesn't read), the player behind it.
  static Future<LaunchMedia?> open(CustomLaunch custom) async {
    final poster = custom.poster;
    if (poster == null) return null;
    final codec = await ui.instantiateImageCodecFromBuffer(await ui.ImmutableBuffer.fromFilePath(poster));
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final clip = LaunchClip._(
      image,
      Size(custom.width.toDouble(), custom.height.toDouble()),
      // Its own length and a margin: only a player that stalls is cut short.
      Duration(milliseconds: (custom.durationMs ?? 60000) + 2000),
    );
    unawaited(clip._prepare(custom.path));
    return clip;
  }

  Future<void> _prepare(String path) async {
    final id = await LaunchClipChannel.instance.open(path);
    if (id == null) return;
    if (_disposed) {
      unawaited(LaunchClipChannel.instance.close(id));
      return;
    }
    _texture = id;
    LaunchClipChannel.instance._open[id] = this;
    if (_wantPlay) unawaited(LaunchClipChannel.instance.play(id));
  }

  void _showing() {
    if (_shown || _disposed) return;
    _shown = true;
    notifyListeners();
  }

  void _done() {
    _safety?.cancel();
    final done = _onDone;
    _onDone = null;
    done?.call();
  }

  @override
  Size get size => _size;

  @override
  Widget view() => ListenableBuilder(
    listenable: this,
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      children: [
        RawImage(image: _poster, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
        if (_texture != null && _shown) Texture(textureId: _texture!, filterQuality: FilterQuality.medium),
      ],
    ),
  );

  @override
  void play({VoidCallback? onDone}) {
    if (_wantPlay) return;
    _wantPlay = true;
    _onDone = onDone;
    _safety = Timer(_length, _done);
    if (_texture case final id?) unawaited(LaunchClipChannel.instance.play(id));
  }

  @override
  void dispose() {
    _disposed = true;
    _safety?.cancel();
    if (_texture case final id?) unawaited(LaunchClipChannel.instance.close(id));
    _poster.dispose();
    super.dispose();
  }
}
