import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart';
import '../../../media/video.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../common/brief_notice.dart';
import '../../theme/app_icons.dart';

/// Capture the Host before navigation; a later active-host switch cannot move
/// this viewer's download, retry, save or external playback to another Host.
Future<void> openMediaVideoViewer(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
  MediaItem item, {
  ArtifactFiles? sourceFiles,
}) {
  final files = sourceFiles ?? ref.read<ArtifactFiles>(artifactFilesProvider);
  final video = ref.read(mediaVideoChannelProvider);
  final gallery = ref.read(mediaChannelProvider);
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          MediaVideoViewerPage(sessionId: sessionId, item: item, files: files, video: video, gallery: gallery),
    ),
  );
}

class MediaVideoViewerPage extends StatefulWidget {
  const MediaVideoViewerPage({
    super.key,
    required this.sessionId,
    required this.item,
    required this.files,
    required this.video,
    required this.gallery,
  });
  final String sessionId;
  final MediaItem item;
  final ArtifactFiles files;
  final MediaVideoChannel video;
  final MediaChannel gallery;

  @override
  State<MediaVideoViewerPage> createState() => _MediaVideoViewerPageState();
}

class _MediaVideoViewerPageState extends State<MediaVideoViewerPage> with WidgetsBindingObserver {
  MediaVideoHandle? _handle;
  final _playback = ValueNotifier((positionMs: 0, durationMs: 0, playing: false));
  File? _file;
  Object? _error;
  Timer? _poller;
  double? _progress;
  double? _seeking;
  bool _loading = true;
  bool _polling = false;
  bool _saving = false;
  bool _external = false;
  bool _commanding = false;
  int _generation = 0;

  Artifact get _artifact => Artifact(path: widget.item.path, origin: ArtifactOrigin.linked, turn: 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _close(MediaVideoHandle? handle) async {
    if (handle != null) {
      try {
        await widget.video.close(handle.texture);
      } catch (_) {
        /* Already released by Android. */
      }
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _poller?.cancel();
    final previous = _handle;
    setState(() {
      _handle = null;
      _error = null;
      _loading = true;
      _progress = null;
    });
    await _close(previous);
    if (!mounted || generation != _generation) return;
    try {
      final file =
          _file ??
          await widget.files.materialize(
            widget.sessionId,
            _artifact,
            onProgress: (value) {
              if (mounted && generation == _generation) setState(() => _progress = value);
            },
          );
      if (!mounted || generation != _generation) return;
      _file = file;
      unawaited(
        cacheMediaVideoThumbnail(widget.files, widget.video, widget.sessionId, widget.item, materialized: file),
      );
      final handle = await widget.video.open(file.path);
      if (!mounted || generation != _generation) {
        await _close(handle);
        return;
      }
      setState(() {
        _handle = handle;
        _playback.value = (positionMs: 0, durationMs: handle.durationMs, playing: false);
        _loading = false;
      });
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) await widget.video.play(handle.texture);
      if (!mounted || generation != _generation) return;
      await _poll();
      if (!mounted || generation != _generation || !identical(_handle, handle)) return;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) _startPolling();
    } catch (error) {
      if (mounted && generation == _generation) _fail(error);
    }
  }

  void _fail(Object error) {
    _poller?.cancel();
    final handle = _handle;
    setState(() {
      _error = error;
      _loading = false;
      _handle = null;
    });
    unawaited(_close(handle));
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(milliseconds: 400), (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    final handle = _handle;
    if (handle == null || _polling) return;
    _polling = true;
    try {
      final state = await widget.video.state(handle.texture);
      if (!mounted || !identical(_handle, handle)) return;
      _playback.value = (positionMs: state.positionMs, durationMs: state.durationMs, playing: state.playing);
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error);
    } finally {
      _polling = false;
    }
  }

  Future<void> _command(Future<void> Function(int texture) command) async {
    final handle = _handle;
    if (handle == null || _commanding) return;
    setState(() => _commanding = true);
    try {
      await command(handle.texture);
      await _poll();
    } catch (error) {
      if (mounted && identical(_handle, handle)) _fail(error);
    } finally {
      if (mounted) setState(() => _commanding = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _poller?.cancel();
      final handle = _handle;
      if (handle != null) {
        unawaited(widget.video.pause(handle.texture).catchError((Object _) {}));
        final previous = _playback.value;
        _playback.value = (positionMs: previous.positionMs, durationMs: previous.durationMs, playing: false);
      }
    } else if (_handle != null) {
      unawaited(_poll());
      _startPolling();
    }
  }

  Future<void> _openExternal() async {
    if (_external) return;
    setState(() => _external = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_handle case final handle?) {
        try {
          await widget.video.pause(handle.texture);
        } catch (_) {
          /* External fallback must still work. */
        }
      }
      await widget.files.open(widget.sessionId, _artifact);
    } catch (error) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(artifactErrorText(error))));
    } finally {
      if (mounted) setState(() => _external = false);
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null || _saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await widget.gallery.saveVideoFile(file.path, name: widget.item.name);
      if (mounted) messenger.showBriefNotice(l10n.chatImageSavedToPhotos);
    } catch (error) {
      if (!mounted || saveWindowDismissed(error)) return;
      final permission = error is PlatformException && error.code == 'permission';
      messenger.showSnackBar(
        SnackBar(
          content: Text(permission ? l10n.chatImageStorageDenied : l10n.mediaVideoSaveFailed),
          persist: false,
          action: permission
              ? SnackBarAction(label: l10n.chatGoToSettings, onPressed: widget.gallery.openSettings)
              : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _playbackControls() => ValueListenableBuilder(
    valueListenable: _playback,
    builder: (context, state, _) {
      final l10n = context.l10n;
      final duration = state.durationMs.clamp(0, 1 << 53).toDouble();
      final transport = IconButton(
        tooltip: state.playing ? l10n.mediaVideoPause : l10n.mediaVideoPlay,
        onPressed: _commanding
            ? null
            : () => _command((texture) async {
                if (state.playing) {
                  await widget.video.pause(texture);
                } else {
                  if (state.positionMs >= state.durationMs) await widget.video.seek(texture, 0);
                  await widget.video.play(texture);
                }
              }),
        icon: Icon(state.playing ? AppIcons.mediaPause : AppIcons.mediaPlay),
      );
      final total = Text(mediaVideoTime(duration.toInt()));
      return StatefulBuilder(
        builder: (context, setPosition) {
          final position = (_seeking ?? state.positionMs.toDouble()).clamp(0.0, duration);
          return Row(
            children: [
              transport,
              Text(mediaVideoTime(position.toInt())),
              Expanded(
                child: Slider(
                  value: position,
                  max: duration > 0 ? duration : 1,
                  onChanged: _commanding ? null : (value) => setPosition(() => _seeking = value),
                  onChangeEnd: (value) {
                    setPosition(() => _seeking = null);
                    unawaited(_command((texture) => widget.video.seek(texture, value.toInt())));
                  },
                ),
              ),
              total,
            ],
          );
        },
      );
    },
  );

  @override
  void dispose() {
    ++_generation;
    _poller?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close(_handle));
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final handle = _handle;
    final unsupported = _error is PlatformException && (_error as PlatformException).code == 'unsupported';
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark, colorScheme: const ColorScheme.dark()),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(widget.item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: l10n.chatSaveToPhotos,
              onPressed: _file == null || _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(AppIcons.save),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: _loading
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(value: _progress),
                            const SizedBox(height: 16),
                            Text(l10n.mediaVideoLoading),
                          ],
                        )
                      : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _file == null
                                    ? artifactErrorText(_error!)
                                    : unsupported
                                    ? l10n.mediaVideoUnsupported
                                    : l10n.mediaVideoCannotPlay,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              if (!unsupported) FilledButton(onPressed: _load, child: Text(l10n.commonRetry)),
                            ],
                          ),
                        )
                      : handle == null
                      ? const SizedBox.shrink()
                      : AspectRatio(
                          aspectRatio: handle.aspectRatio,
                          // Dimensions already describe the display; rotate the buffer inside them.
                          child: RotatedBox(
                            quarterTurns: handle.rotation ~/ 90,
                            child: Texture(textureId: handle.texture),
                          ),
                        ),
                ),
              ),
              if (handle != null)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _playbackControls()),
              TextButton(onPressed: _external || _loading ? null : _openExternal, child: Text(l10n.mediaOpenElsewhere)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
