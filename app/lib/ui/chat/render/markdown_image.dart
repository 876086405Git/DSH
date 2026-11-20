// Images in replies. `![…](chart.png)` usually names a file the agent just
// made in the session's workspace, so it is read the way the artifact card
// reads files (local engine: in place; remote Host: downloaded once into the
// cache); web and `data:` images load directly.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/custom_widgets/svg_image.dart' show NetworkSvg, isSvgUrl, memorySvg;

import '../../../l10n/l10n.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../../state/chat_state.dart';
import '../../../state/emoji_state.dart';
import '../../../state/image_snapshots.dart';
import '../../../state/sessions_state.dart';
import '../../../media/gallery.dart' show imageProviderBytes;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../artifact_preview.dart';
import '../media/media_paths.dart';
import '../widgets/image_actions.dart';
import '../widgets/image_gallery.dart' show ViewerImage;

/// Largest workspace image a reply downloads from a remote Host just to show
/// it inline (the Host's own image limit is 20 MiB).
const maxMarkdownImageBytes = 20 * 1024 * 1024;

/// Tallest an image is drawn in the reply; taller ones keep their aspect
/// ratio and get narrower. A tap opens the full image.
const maxMarkdownImageHeight = 480.0;

/// [source] decoded no larger than it is drawn inline (the reading width and
/// [maxMarkdownImageHeight], or a smaller size hint), in physical pixels; small images are not scaled up.
/// The full-screen viewer gets the original.
ImageProvider inlineImageProvider(ImageProvider source, double dpr, Size? hint) => ResizeImage(
  source,
  width: (math.min(hint?.width ?? AppSpace.readingWidth, AppSpace.readingWidth) * dpr).round(),
  height: (math.min(hint?.height ?? maxMarkdownImageHeight, maxMarkdownImageHeight) * dpr).round(),
  policy: ResizeImagePolicy.fit,
);

// -----------------------------------------------------------------------------
// Where an image comes from

/// Where the bytes of a Markdown image come from.
sealed class ImageSource {
  const ImageSource();
}

/// `http(s)://…`.
class WebImageSource extends ImageSource {
  const WebImageSource(this.url);
  final String url;
}

/// `data:image/png;base64,…`.
class DataImageSource extends ImageSource {
  const DataImageSource(this.url);
  final String url;
}

/// A file the session can see: absolute (`/root/workspace/x.png`), or
/// relative to the session's working directory (`test-image.jpg`).
class WorkspaceImageSource extends ImageSource {
  const WorkspaceImageSource(this.path);

  /// The local URI path, percent-escapes decoded once.
  final String path;
}

/// A scheme that is not an image address (`javascript:`, `intent:`…).
class UnsupportedImageSource extends ImageSource {
  const UnsupportedImageSource();
}

/// Classifies a Markdown image destination.
ImageSource imageSourceOf(String url) {
  var target = url.trim();
  if (target.startsWith('<') && target.endsWith('>')) {
    target = target.substring(1, target.length - 1).trim();
  }
  final lower = target.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return WebImageSource(target);
  }
  if (lower.startsWith('data:')) return DataImageSource(target);
  // Windows drive paths included: the same rules as links and artifact cards.
  final path = resolveWorkspaceLink(url);
  return path == null ? const UnsupportedImageSource() : WorkspaceImageSource(path);
}

/// [path] (a workspace image as written) as the path to read.
///
/// Relative paths join [baseDir] (the folder of a previewed Markdown file),
/// else the session's working directory [cwd], else — on the local engine,
/// whose sessions all start there — [localWorkspaceDir]. On a remote Host
/// without a known working directory the path stays relative: the Host
/// resolves it against the session's own.
String workspaceImagePath(String path, {String? baseDir, String? cwd, bool local = false}) {
  final base = baseDir ?? cwd ?? (local ? localWorkspaceDir : null);
  return resolveSessionPath(path, cwd: base);
}

/// The file name to show for [url] (`test-image.jpg`), never a whole
/// `data:` payload.
String imageDisplayName(String url) {
  final source = imageSourceOf(url);
  final path = switch (source) {
    WorkspaceImageSource(:final path) => path,
    WebImageSource(:final url) => Uri.tryParse(url)?.path ?? url,
    DataImageSource() => '',
    UnsupportedImageSource() => url,
  };
  final name = baseName(path.trim());
  return name.isEmpty ? appL10n.chatImage : name;
}

// -----------------------------------------------------------------------------
// Session context

/// Which session's files a reply's images come from, for Markdown shown
/// outside the chat list (a previewed `.md` file; tests). Without one, the
/// conversation open in the chat ([currentSessionProvider]) is used.
class MarkdownImageScope extends InheritedWidget {
  const MarkdownImageScope({super.key, required this.sessionId, this.baseDir, this.turn, required super.child});

  final String sessionId;

  /// Where relative paths start; null: the session's working directory.
  final String? baseDir;

  /// Null outside a chat turn: standalone file previews remain live.
  final int? turn;

  static MarkdownImageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownImageScope>();

  @override
  bool updateShouldNotify(MarkdownImageScope oldWidget) =>
      sessionId != oldWidget.sessionId || baseDir != oldWidget.baseDir || turn != oldWidget.turn;
}

/// A single rendered Markdown body, never the entire chat or another reply.
/// Images are collected in element order on tap, including HTML/reference images
/// already parsed by the Markdown renderer, without scanning Markdown source.
class MarkdownGalleryScope extends InheritedWidget {
  const MarkdownGalleryScope({super.key, required super.child});

  static List<_MarkdownImageState> _imagesOf(BuildContext context) {
    final root = context.getElementForInheritedWidgetOfExactType<MarkdownGalleryScope>();
    if (root == null) return const [];
    final images = <_MarkdownImageState>[];
    void visit(Element element) {
      if (element.widget is MarkdownGalleryScope) return;
      if (element is StatefulElement && element.state is _MarkdownImageState) {
        final image = element.state as _MarkdownImageState;
        if (image._source is WorkspaceImageSource && image._engineUrl == null
            ? image._workspaceGallery
            : image._galleryImage != null) {
          images.add(image);
        }
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return images;
  }

  @override
  bool updateShouldNotify(MarkdownGalleryScope oldWidget) => false;
}

// -----------------------------------------------------------------------------
// Reading workspace images

/// A decoded-ready workspace image.
sealed class LoadedImage {
  const LoadedImage();
}

class RasterImage extends LoadedImage {
  const RasterImage(this.provider);
  final ImageProvider provider;
}

class SvgImageBytes extends LoadedImage {
  const SvgImageBytes(this.bytes);
  final Uint8List bytes;
}

/// Reads one image file of a session.
abstract interface class WorkspaceImageReader {
  Future<LoadedImage> read(String sessionId, String path);
}

/// Too big to fetch just to draw it inline.
class ImageTooLarge implements Exception {
  const ImageTooLarge();
}

/// Reads through [ArtifactFiles]: the local engine's file in place, a remote
/// Host's file downloaded once into the artifact cache (refetched only when
/// the Host reports a new version).
class ArtifactImageReader implements WorkspaceImageReader {
  const ArtifactImageReader(this.files, {this.turn});

  final ArtifactFiles files;
  final int? turn;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    final connection = files.connection;
    if (connection == null) throw const ArtifactError('offline');
    if (!files.canFetch) throw const ArtifactError('unsupported');
    if (!connection.isLocal && turn == null) {
      final stat = await connection.client.statFile(sessionId, path);
      if ((stat.bytes ?? 0) > maxMarkdownImageBytes) throw const ImageTooLarge();
    }
    final file = await files.materialize(
      sessionId,
      Artifact(path: path, origin: ArtifactOrigin.linked, turn: turn ?? 0, snapshotImage: turn != null),
      maxBytes: maxMarkdownImageBytes,
    );
    if (isSvgUrl(path)) return SvgImageBytes(await file.readAsBytes());
    return RasterImage(FileImage(file));
  }
}

/// Remembers each image per (session, path) while the connection lasts, so
/// scrolling a reply back into view draws it at once instead of reading the
/// file again. A failed read is forgotten, so the next attempt reads afresh.
class CachedImageReader implements WorkspaceImageReader {
  CachedImageReader(this.inner, {this.capacity = 64, this.keeps});

  final WorkspaceImageReader inner;
  final int capacity;

  /// Whether a read image is worth holding; null holds all of them.
  final bool Function(LoadedImage image)? keeps;
  final _pending = <(String, String), Future<LoadedImage>>{};
  final _done = <(String, String), LoadedImage>{};

  /// The image when it has already been read; null while it is not.
  LoadedImage? peek(String sessionId, String path) {
    final key = (sessionId, path);
    final hit = _done.remove(key);
    if (hit != null) _done[key] = hit;
    return hit;
  }

  @override
  Future<LoadedImage> read(String sessionId, String path) {
    final key = (sessionId, path);
    final done = peek(sessionId, path);
    if (done != null) return SynchronousFuture(done);
    final pending = _pending[key];
    if (pending != null) return pending;
    final request = Completer<LoadedImage>();
    _pending[key] = request.future;
    request.complete(
      Future.sync(() => inner.read(sessionId, path)).then(
        (image) {
          // Another tile can retry this path before the old read completes.
          if (!identical(_pending[key], request.future)) return image;
          _pending.remove(key);
          if (keeps?.call(image) == false) return image;
          _done[key] = image;
          while (_done.length > capacity) {
            _done.remove(_done.keys.first);
          }
          return image;
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_pending[key], request.future)) _pending.remove(key);
          Error.throwWithStackTrace(error, stack);
        },
      ),
    );
    return request.future;
  }

  /// Forgets [path] so it is read again (a retry after a failure).
  void forget(String sessionId, String path) {
    _pending.remove((sessionId, path));
    _done.remove((sessionId, path));
  }
}

/// Reads images the connected engine serves itself, such as a plugin's
/// `/api/…` assets: they need the session's cookie, which NetworkImage can't
/// send. [path] is the image's full URL or root-relative API path.
class EngineImageReader implements WorkspaceImageReader {
  const EngineImageReader(this.client);

  final DshClient? client;

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    final client = this.client;
    if (client == null) throw const ArtifactError('offline');
    final bytes = await client.readEngineUrl(path, maxBytes: maxMarkdownImageBytes);
    return isSvgUrl(path) ? SvgImageBytes(bytes) : RasterImage(MemoryImage(bytes));
  }
}

/// Largest engine image held in memory between reads. These hold their bytes,
/// unlike workspace images (a file handle): small assets such as emoji repeat
/// in a chat, and anything bigger is read again when it scrolls back.
const maxHeldEngineImageBytes = 256 * 1024;

/// Images from the engine's own address; one cache per connection, at most
/// 8 MiB of bytes.
final engineImageReaderProvider = Provider<CachedImageReader>(
  (ref) => CachedImageReader(
    EngineImageReader(ref.watch(artifactFilesProvider).connection?.client),
    capacity: 32,
    keeps: (image) => switch (image) {
      RasterImage(provider: MemoryImage(:final bytes)) ||
      SvgImageBytes(:final bytes) => bytes.length <= maxHeldEngineImageBytes,
      _ => true,
    },
  ),
);

/// The reader reply images use; one cache per connection.
final workspaceImageReaderProvider = Provider<CachedImageReader>(
  (ref) => CachedImageReader(ArtifactImageReader(ref.watch(artifactFilesProvider))),
);

/// A separate decoded-ready cache per turn; immutable files survive its disposal.
final turnWorkspaceImageReaderProvider = Provider.autoDispose.family<CachedImageReader, int>(
  (ref, turn) => CachedImageReader(ArtifactImageReader(ref.watch(artifactFilesProvider), turn: turn)),
);

/// A short sentence for a failed image (shown under its file name).
String imageErrorText(Object error) {
  final code = switch (error) {
    ImageTooLarge() || ImageSnapshotTooLarge() => 'too-large',
    ImageSnapshotMissing() => 'missing',
    ArtifactError(:final code) => code,
    PlatformException(:final code) => code,
    DshRemoteException(:final code) => code,
    DshTransportException() || DshCarrierLostException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'missing' || 'workspace-file/not-found' => appL10n.chatImageNotFound,
    'offline' => appL10n.chatImageOffline,
    'too-large' || 'workspace-file/too-large' => appL10n.chatImageTooLarge,
    'unsupported' || 'workspace-file/unsupported' || 'workspace-file/not-allowed' => appL10n.chatImageReadFailed,
    _ => appL10n.chatImageDisplayFailed,
  };
}

// -----------------------------------------------------------------------------
// The image in a reply

/// Natural sizes of images already drawn, so the placeholder of an image
/// coming back into view has the right shape and nothing below it moves.
final _knownSizes = <String, Size>{};

void _rememberSize(String key, Size size) {
  _knownSizes.remove(key);
  _knownSizes[key] = size;
  while (_knownSizes.length > 256) {
    _knownSizes.remove(_knownSizes.keys.first);
  }
}

/// `data:` images decoded once per address.
final _dataImages = <String, Uint8List?>{};

Uint8List? _dataBytes(String url) {
  final hit = _dataImages.remove(url);
  if (hit != null || _dataImages.containsKey(url)) {
    _dataImages[url] = hit;
    return hit;
  }
  Uint8List? bytes;
  try {
    bytes = UriData.parse(url).contentAsBytes();
  } on FormatException {
    bytes = null;
  }
  _dataImages[url] = bytes;
  while (_dataImages.length > 32) {
    _dataImages.remove(_dataImages.keys.first);
  }
  return bytes;
}

/// The gpt_markdown image builder: [MarkdownImage] for every `![…](…)` and
/// `<img>`. [width] / [height] come from a `WxH` alt text.
Widget markdownImageBuilder(BuildContext context, String url, double? width, double? height) =>
    MarkdownImage(url: url, width: width, height: height);

/// The image-builder callback has no text style argument. Carry the body or
/// heading's unscaled em through the built tree; gpt_markdown's WidgetSpan
/// applies the text scaler once around the image.
class MarkdownImageFont extends InheritedWidget {
  const MarkdownImageFont({super.key, required this.size, required super.child});

  final double size;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownImageFont>()?.size ?? AppType.chatBody(context).fontSize!;

  @override
  bool updateShouldNotify(MarkdownImageFont oldWidget) => size != oldWidget.size;
}

bool _inlineEmoji(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.fragment == 'dsh-emoji-block') return false;
  final parts = uri.pathSegments;
  // Current pack/version/file and the plugin's legacy pack/file route.
  return (parts.length == 5 || parts.length == 6) &&
      parts[0] == 'api' &&
      parts[1] == 'dsh-emoji' &&
      parts[2] == 'assets' &&
      parts.skip(3).every((part) => part.isNotEmpty);
}

/// One image in a reply: no wider than the column, its own aspect ratio,
/// rounded like the code wells beside it. While it loads, a calm box of the
/// right (or a 4:3) shape; when it cannot be shown, its file name and why.
/// A tap opens it full screen.
class MarkdownImage extends ConsumerStatefulWidget {
  const MarkdownImage({super.key, required this.url, this.width, this.height});

  final String url;
  final double? width;
  final double? height;

  @override
  ConsumerState<MarkdownImage> createState() => _MarkdownImageState();
}

class _MarkdownImageState extends ConsumerState<MarkdownImage> {
  late ImageSource _source = imageSourceOf(widget.url);

  /// Workspace images: the session and the path read.
  String? _sessionId;
  String? _path;
  int? _turn;

  CachedImageReader get _workspaceReader =>
      ref.read(_turn == null ? workspaceImageReaderProvider : turnWorkspaceImageReaderProvider(_turn!));

  /// An image the connected engine serves itself: read with its cookie.
  String? _engineUrl;
  Future<LoadedImage>? _future;
  LoadedImage? _loaded;
  Object? _error;
  double? _emojiSide;

  /// Bumped by a retry, so a failed web image is fetched again.
  int _attempt = 0;

  String get _sizeKey => '${_sessionId ?? ''}\n${_turn ?? ''}\n${_path ?? widget.url}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _source = imageSourceOf(widget.url);
      _resolve();
    }
  }

  void _resolve() {
    final source = _source;
    final url = source is WebImageSource ? source.url : widget.url.trim();
    final engine =
        (source is WebImageSource || source is WorkspaceImageSource) &&
        (ref.read(artifactFilesProvider).connection?.client.isEngineUrl(url) ?? false);
    if (source is WebImageSource || engine) {
      final next = engine ? url : null;
      if (next == _engineUrl && (next == null || _future != null || _loaded != null)) return;
      _engineUrl = next;
      _sessionId = null;
      _path = null;
      _future = null;
      _loaded = null;
      _error = null;
      if (next != null) _load();
      return;
    }
    _engineUrl = null;
    if (source is! WorkspaceImageSource) return;
    final scope = MarkdownImageScope.maybeOf(context);
    final sessionId = scope?.sessionId ?? ref.read(currentSessionProvider);
    if (sessionId == null) {
      _sessionId = null;
      _path = null;
      _future = null;
      _loaded = null;
      _error = const ArtifactError('offline');
      return;
    }
    final local = ref.read(artifactFilesProvider).isLocal;
    final baseDir = scope?.baseDir;
    final path = workspaceImagePath(
      source.path,
      baseDir: baseDir,
      cwd: baseDir == null && !source.path.startsWith('/') ? _cwdOf(sessionId) : null,
      local: local,
    );
    final turn = scope?.turn;
    if (sessionId == _sessionId && path == _path && turn == _turn && (_future != null || _loaded != null)) return;
    _sessionId = sessionId;
    _path = path;
    _turn = turn;
    _load();
  }

  /// The session's working directory, when the app knows it. Only a chat
  /// already open is asked: reading one would start watching the session.
  String? _cwdOf(String sessionId) {
    final chat = chatProvider(sessionId);
    final header = ref.exists(chat) ? ref.read(chat.notifier).header : null;
    return header?.cwd ?? ref.read(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.cwd;
  }

  void _load() {
    final engineUrl = _engineUrl;
    final reader = engineUrl != null ? ref.read(engineImageReaderProvider) : _workspaceReader;
    final sessionId = engineUrl != null ? '' : _sessionId!;
    final path = engineUrl ?? _path!;
    _error = null;
    _loaded = reader.peek(sessionId, path);
    if (_loaded != null) {
      _future = null;
      return;
    }
    final future = _future = reader.read(sessionId, path);
    future.then(
      (image) {
        if (!mounted || _future != future) return;
        setState(() => _loaded = image);
      },
      onError: (Object error) {
        if (!mounted || _future != future) return;
        setState(() => _error = error);
      },
    );
  }

  /// The resized provider last drawn: a retry evicts it as well.
  ImageProvider? _inlineProvider;

  /// Original provider for a rendered bitmap; hidden/error/SVG tiles stay out.
  ImageProvider? _galleryImage;

  /// Pending workspace bitmaps can be opened lazily by the artifact preview.
  bool _workspaceGallery = false;

  void _retry() {
    _inlineProvider?.evict();
    setState(() {
      _attempt += 1;
      final source = _source;
      if (_engineUrl != null) {
        ref.read(engineImageReaderProvider).forget('', _engineUrl!);
        _load();
      } else if (source is WorkspaceImageSource && _sessionId != null && _path != null) {
        _workspaceReader.forget(_sessionId!, _path!);
        _load();
      } else if (source is WebImageSource) {
        PaintingBinding.instance.imageCache.evict(NetworkImage(source.url));
        // The connection may have arrived since this image was first drawn.
        _resolve();
      }
    });
  }

  void _open(ImageProvider? image) {
    final source = _source;
    final sessionId = _sessionId;
    final path = _path;
    // Workspace previews stay live; chat turns keep their immutable read,
    // including share and file actions.
    // They form their own gallery, separate from web/data images in this body.
    if (source is WorkspaceImageSource && sessionId != null && path != null) {
      final group = image == null
          ? <_MarkdownImageState>[] // Preserve the single large-image fallback.
          : MarkdownGalleryScope._imagesOf(context)
                .where((state) => state._source is WorkspaceImageSource && state._sessionId == sessionId)
                .toList();
      final initial = group.indexOf(this);
      final artifacts = initial < 0
          ? null
          : [
              for (final state in group)
                Artifact(
                  path: state._path!,
                  origin: ArtifactOrigin.linked,
                  turn: state._turn ?? 0,
                  snapshotImage: state._turn != null,
                ),
            ];
      Navigator.of(context).push(
        ArtifactPreviewPage.route(
          sessionId: sessionId,
          artifact: Artifact(path: path, origin: ArtifactOrigin.linked, turn: _turn ?? 0, snapshotImage: _turn != null),
          gallery: artifacts,
          initial: initial < 0 ? 0 : initial,
        ),
      );
      return;
    }
    if (image != null) {
      final group = MarkdownGalleryScope._imagesOf(context)
          .where((state) => state._source is! WorkspaceImageSource || state._engineUrl != null)
          .toList();
      final initial = group.indexOf(this);
      Navigator.of(context).push(
        ImageViewerPage.galleryRoute(
          images: initial < 0
              ? [ViewerImage(name: imageDisplayName(widget.url), image: image)]
              : [
                  for (final state in group)
                    ViewerImage(name: imageDisplayName(state.widget.url), image: state._galleryImage!),
                ],
          initial: initial < 0 ? 0 : initial,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_turn case final turn?) ref.watch(turnWorkspaceImageReaderProvider(turn));
    // A replaced connection has its own cookie and cache: read through it again.
    ref.listen(artifactFilesProvider.select((files) => files.connection?.client), (_, _) {
      if (_source is! WebImageSource && _source is! WorkspaceImageSource) return;
      setState(() {
        _engineUrl = null;
        // A workspace path can stay the same across clients. Retire its read
        // before resolving it, including a completion still in flight.
        _future = null;
        _loaded = null;
        _error = null;
        _resolve();
      });
    });
    final l10n = context.l10n;
    final client = ref.watch(artifactFilesProvider.select((files) => files.connection?.client));
    _emojiSide =
        _engineUrl != null &&
            client != null &&
            widget.width == null &&
            widget.height == null &&
            _inlineEmoji(_engineUrl!)
        ? MarkdownImageFont.of(context) * ref.watch(emojiSizeProvider(client))
        : null;
    _galleryImage = null;
    _workspaceGallery = false;
    // A media card above already shows this file: not a second time. Only
    // for a conversation already open (a previewed file never starts one).
    if (_source is WorkspaceImageSource &&
        _sessionId != null &&
        _path != null &&
        ref.exists(chatProvider(_sessionId!))) {
      final shown = ref.watch(sessionMediaPathsProvider(_sessionId!));
      if (shownInMediaCard(shown, _path!)) return const SizedBox.shrink();
    }
    final name = imageDisplayName(widget.url);
    Widget placeholder() => _emojiSide == null
        ? _ImagePlaceholder(size: _knownSizes[_sizeKey], hint: _hint)
        : SizedBox.square(
            dimension: _emojiSide,
            child: _ImagePlaceholder(hint: _hint),
          );
    Widget failed(Object? error) {
      final message = error == null ? l10n.chatImageDisplayFailed : imageErrorText(error);
      // Too big to draw inline, but the full-screen preview can still show it.
      if (error is ImageTooLarge) {
        return _ImageError(name: name, message: message, action: l10n.chatImageTapToView, onTap: () => _open(null));
      }
      return _ImageError(name: name, message: message, action: l10n.chatImageTapToRetry, onTap: _retry);
    }

    Widget read() {
      final loaded = _loaded;
      if (_error != null) return failed(_error);
      if (loaded == null) return placeholder();
      return switch (loaded) {
        RasterImage(:final provider) => _raster(provider, placeholder: placeholder, failed: failed),
        // The preview page shows bitmaps only.
        SvgImageBytes(:final bytes) => _framed(
          memorySvg(bytes, fit: BoxFit.contain, error: (_) => failed(null)),
          onTap: null,
        ),
      };
    }

    final source = _source;
    final Widget child;
    switch (source) {
      case UnsupportedImageSource():
        child = _ImageError(name: name, message: l10n.chatImageUnsupportedAddress);
      case WebImageSource() when _engineUrl != null:
        child = read();
      case WebImageSource(:final url) when isSvgUrl(url):
        child = _framed(
          NetworkSvg(
            url,
            key: ValueKey(_attempt),
            fit: BoxFit.contain,
            loading: (_) => placeholder(),
            error: (_) => failed(null),
          ),
          onTap: null,
        );
      case WebImageSource(:final url):
        child = _raster(NetworkImage(url), placeholder: placeholder, failed: failed);
      case DataImageSource(:final url):
        final bytes = _dataBytes(url);
        if (bytes == null) {
          child = failed(null);
        } else if (isSvgUrl(url)) {
          child = _framed(memorySvg(bytes, fit: BoxFit.contain, error: (_) => failed(null)), onTap: null);
        } else {
          child = _raster(MemoryImage(bytes), placeholder: placeholder, failed: failed);
        }
      case WorkspaceImageSource():
        _workspaceGallery =
            _sessionId != null &&
            _path != null &&
            previewModeOf(_path!) == PreviewMode.image &&
            _error == null &&
            _loaded is! SvgImageBytes;
        child = read();
    }
    return Semantics(image: true, label: name, child: child);
  }

  Size? get _hint {
    final emojiSide = _emojiSide;
    if (emojiSide != null) return Size.square(emojiSide);
    final w = widget.width;
    final h = widget.height;
    return w != null && h != null && w > 0 && h > 0 ? Size(w, h) : null;
  }

  Widget _raster(
    ImageProvider provider, {
    required Widget Function() placeholder,
    required Widget Function(Object? error) failed,
  }) {
    _galleryImage = provider;
    // Emoji packs cap both axes at 512px but permit e.g. 512×1. Resizing that
    // to an em-sized fit box can round the short axis to zero. Keep its source
    // decode and fit it at paint time; the gallery also retains the original.
    final resized = _emojiSide != null
        ? provider
        : inlineImageProvider(provider, MediaQuery.devicePixelRatioOf(context), _hint);
    _inlineProvider = resized;
    return _SizeProbe(
      provider: resized,
      sizeKey: _sizeKey,
      child: Image(
        key: ValueKey((resized, _attempt)),
        image: resized,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        frameBuilder: (context, image, frame, synchronous) {
          if (frame == null) return placeholder();
          return _framed(image, onTap: () => _open(provider), onLongPress: () => _actions(provider));
        },
        errorBuilder: (context, error, _) {
          _galleryImage = null;
          _workspaceGallery = false;
          return failed(error);
        },
      ),
    );
  }

  /// [image] constrained to the column and [maxMarkdownImageHeight] (or the
  /// alt text's `WxH`), clipped to the well radius with a hairline edge so a
  /// white image still has a shape on a white page.
  Widget _framed(Widget image, {required VoidCallback? onTap, VoidCallback? onLongPress}) {
    if (_emojiSide case final side?) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox.square(dimension: side, child: image),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final hint = _hint;
    Widget framed = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: hint?.width ?? double.infinity,
        maxHeight: hint?.height ?? maxMarkdownImageHeight,
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusMd,
            side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.6), width: 0.5),
          ),
        ),
        child: Squircle.clip(radius: AppShape.md, child: image),
      ),
    );
    if (onTap != null || onLongPress != null) {
      framed = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, onLongPress: onLongPress, child: framed);
    }
    return framed;
  }

  /// Long-press on a drawn picture: 「保存到相册」 / 「分享」 with its own bytes
  /// (the workspace file, the web image, the `data:` payload), not the
  /// smaller copy drawn inline. Wins over the reply's own long-press menu.
  void _actions(ImageProvider provider) => showImageActions(
    context,
    image: provider,
    load: () => imageProviderBytes(provider),
    name: imageDisplayName(widget.url),
  );
}

/// Listens to [provider] once to learn its natural size (for [_knownSizes]).
class _SizeProbe extends StatefulWidget {
  const _SizeProbe({required this.provider, required this.sizeKey, required this.child});

  final ImageProvider provider;
  final String sizeKey;
  final Widget child;

  @override
  State<_SizeProbe> createState() => _SizeProbeState();
}

class _SizeProbeState extends State<_SizeProbe> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener((info, _) {
    _rememberSize(widget.sizeKey, Size(info.image.width / info.scale, info.image.height / info.scale));
    info.dispose();
    _stop();
  }, onError: (_, _) => _stop());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_knownSizes.containsKey(widget.sizeKey)) return;
    _stop();
    _stream = widget.provider.resolve(createLocalImageConfiguration(context))..addListener(_listener);
  }

  void _stop() {
    _stream?.removeListener(_listener);
    _stream = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A calm box where an image is about to be: the image's own shape when it
/// has been seen before (or the alt text says `WxH`), 4:3 otherwise.
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.size, this.hint});

  final Size? size;
  final Size? hint;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final known = size ?? hint;
    final aspect = known == null || known.height <= 0 ? 4 / 3 : known.width / known.height;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: known?.width ?? double.infinity,
        maxHeight: hint?.height ?? maxMarkdownImageHeight,
      ),
      child: AspectRatio(
        aspectRatio: aspect,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: dsh.codeWellBg,
            shape: RoundedSuperellipseBorder(
              borderRadius: AppShape.radiusMd,
              side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
            ),
          ),
          child: Center(child: Icon(AppIcons.image, size: 22, color: dsh.textTertiary)),
        ),
      ),
    );
  }
}

/// An image that cannot be shown: a small icon, its file name and why, on
/// the code-well tone — never a grey box with a broken-image glyph.
class _ImageError extends StatelessWidget {
  const _ImageError({required this.name, required this.message, this.action, this.onTap});

  final String name;
  final String message;

  /// What a tap does (`轻点重试`), appended to [message].
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final text = theme.textTheme.bodyMedium;
    Widget tile = DecoratedBox(
      decoration: ShapeDecoration(
        color: dsh.codeWellBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusMd,
          side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.imageBroken, size: 20, color: dsh.textTertiary),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text?.copyWith(color: theme.colorScheme.onSurface, height: 1.35),
                  ),
                  Text(
                    action == null ? message : '$message · $action',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap != null) {
      tile = GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: tile);
    }
    return tile;
  }
}
