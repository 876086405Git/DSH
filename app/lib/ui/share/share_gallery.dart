// The pictures on a share card. A prompt's attachments come from
// `session/attachment` and a reply's `![…](…)` from the workspace, the web or a
// `data:` URL — the same roads the chat takes — and are drawn as a gallery: one
// at its own shape, two side by side, three as one tall and two stacked, four
// and more as a 2 × 2 grid with 「+N」 on the fourth. A picture that cannot be
// had is a quiet tile, never an error line, and the export waits until every
// picture is in ([shareImagesSettled]).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/custom_widgets/svg_image.dart' show isSvgUrl, memorySvg;

import '../../l10n/l10n.dart';
import '../../state/artifact_files.dart' show artifactFilesProvider;
import '../../state/attachments.dart' show sessionImageProvider;
import '../../state/chat_state.dart' show chatProvider;
import '../../state/sessions_state.dart' show currentSessionProvider, sessionsProvider;
import '../chat/render/markdown_image.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'share_content.dart';

/// The conversation and shared decode limit for a card's galleries.
class ShareImageScope extends InheritedWidget {
  const ShareImageScope({super.key, required this.sessionId, this.decodeBound = maxDecodeBound, required super.child});

  final String? sessionId;
  final int decodeBound;

  static const maxDecodeBound = 1200;
  // Eight full-size square pictures, about 44 MiB of retained RGBA pixels.
  static const _decodePixelBudget = 8 * maxDecodeBound * maxDecodeBound;

  /// Count mounted cells, not URLs hidden behind a gallery's +N tile.
  static int decodeBoundFor(Iterable<ShareBlock> blocks) {
    var cells = 0;
    for (final block in blocks) {
      switch (block) {
        case ShareQuestion(:final images):
          cells += ShareGalleryLayout.cells(images.length);
        case ShareAnswer(:final markdown):
          for (final segment in shareSegments(markdown)) {
            cells += ShareGalleryLayout.cells(segment.images.length);
          }
        default:
      }
    }
    if (cells <= 8) return maxDecodeBound;
    return math.max(1, math.sqrt(_decodePixelBudget / cells).floor());
  }

  static String? sessionIdOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShareImageScope>()?.sessionId;

  static int decodeBoundOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShareImageScope>()?.decodeBound ?? maxDecodeBound;

  @override
  bool updateShouldNotify(ShareImageScope oldWidget) =>
      sessionId != oldWidget.sessionId || decodeBound != oldWidget.decodeBound;
}

/// Waits (at most [timeout]) until every picture under [context] has been
/// decoded or given up on, then for the frame that paints them: what an
/// export calls before it takes the picture.
Future<void> shareImagesSettled(BuildContext context, {Duration timeout = const Duration(seconds: 8)}) async {
  final pending = [for (final cell in _cells(context)) cell.settled];
  if (pending.isEmpty) return;
  try {
    await Future.wait(pending).timeout(timeout);
  } on TimeoutException {
    // Whatever has not come by now is drawn as its quiet tile.
  }
  await WidgetsBinding.instance.endOfFrame;
}

/// Pictures under [context] still on their way.
@visibleForTesting
int shareImagesPending(BuildContext context) => _cells(context).where((c) => !c.isSettled).length;

List<_ShareImageCellState> _cells(BuildContext context) {
  final cells = <_ShareImageCellState>[];
  void visit(Element element) {
    if (element is StatefulElement && element.state is _ShareImageCellState) {
      cells.add(element.state as _ShareImageCellState);
    }
    element.visitChildren(visit);
  }

  if (context.mounted) (context as Element).visitChildren(visit);
  return cells;
}

/// Pictures of one message laid out by [ShareGalleryLayout], [width] wide
/// (a prompt's at most [ShareGalleryLayout.questionWidth], right-aligned).
class ShareGallery extends StatelessWidget {
  const ShareGallery({super.key, required this.images, required this.width, this.question = false});

  final List<ShareImage> images;

  /// The column's width.
  final double width;

  /// A prompt's pictures: narrower, square frames, at the right edge.
  final bool question;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final n = images.length;
    if (n == 0) return const SizedBox.shrink();
    const g = ShareGalleryLayout.gap;
    const o = Radius.circular(ShareGalleryLayout.radius);
    const i = Radius.circular(ShareGalleryLayout.innerRadius);
    final w = question ? (width < ShareGalleryLayout.questionWidth ? width : ShareGalleryLayout.questionWidth) : width;
    final half = (w - g) / 2;
    final frame = w / ShareGalleryLayout.frameAspect(question: question);
    Widget cell(int index, Size? size, BorderRadius radius, {int more = 0}) => _ShareImageCell(
      key: ValueKey('share-image-$index'),
      image: images[index],
      decodeBound: ShareImageScope.decodeBoundOf(context),
      size: size,
      maxWidth: w,
      question: question,
      radius: radius,
      more: more,
    );

    final Widget gallery = switch (n) {
      1 => cell(0, null, const BorderRadius.all(o)),
      2 => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cell(0, Size(half, half), const BorderRadius.horizontal(left: o, right: i)),
          const SizedBox(width: g),
          cell(1, Size(half, half), const BorderRadius.horizontal(left: i, right: o)),
        ],
      ),
      3 => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cell(0, Size(half, frame), const BorderRadius.horizontal(left: o, right: i)),
          const SizedBox(width: g),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                1,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: i, topRight: o, bottomLeft: i, bottomRight: i),
              ),
              const SizedBox(height: g),
              cell(
                2,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: i, topRight: i, bottomLeft: i, bottomRight: o),
              ),
            ],
          ),
        ],
      ),
      _ => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                0,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: o, topRight: i, bottomLeft: i, bottomRight: i),
              ),
              const SizedBox(width: g),
              cell(
                1,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: i, topRight: o, bottomLeft: i, bottomRight: i),
              ),
            ],
          ),
          const SizedBox(height: g),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                2,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: i, topRight: i, bottomLeft: o, bottomRight: i),
              ),
              const SizedBox(width: g),
              cell(
                3,
                Size(half, (frame - g) / 2),
                const BorderRadius.only(topLeft: i, topRight: i, bottomLeft: i, bottomRight: o),
                more: n - 4,
              ),
            ],
          ),
        ],
      ),
    };
    return Semantics(
      image: true,
      label: n == 1 ? l10n.viewShareImages : l10n.viewImageCount(n),
      excludeSemantics: true,
      child: Align(alignment: question ? Alignment.centerRight : Alignment.centerLeft, child: gallery),
    );
  }
}

/// One picture of a gallery: [size] (cover) in a grid, or its own shape
/// within [maxWidth] and the layout's height when alone.
class _ShareImageCell extends ConsumerStatefulWidget {
  const _ShareImageCell({
    super.key,
    required this.image,
    required this.decodeBound,
    required this.size,
    required this.maxWidth,
    required this.question,
    required this.radius,
    this.more = 0,
  });

  final ShareImage image;
  final int decodeBound;
  final Size? size;
  final double maxWidth;
  final bool question;
  final BorderRadius radius;

  /// Pictures left out after this one (「+N」).
  final int more;

  @override
  ConsumerState<_ShareImageCell> createState() => _ShareImageCellState();
}

class _ShareImageCellState extends ConsumerState<_ShareImageCell> {
  var _settled = Completer<void>();

  /// Done once the picture is drawn or given up on.
  Future<void> get settled => _settled.future;
  bool get isSettled => _settled.isCompleted;

  ImageStream? _stream;
  ImageInfo? _info;
  Uint8List? _svg;
  bool _failed = false;
  bool _started = false;
  ProviderSubscription<Object?>? _subscription;

  late final _listener = ImageStreamListener(_onImage, onError: (_, _) => _fail());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _start();
  }

  @override
  void didUpdateWidget(_ShareImageCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSource(oldWidget.image, widget.image) || oldWidget.decodeBound != widget.decodeBound) {
      _reset();
      if (!_settled.isCompleted) _settled.complete();
      _settled = Completer<void>();
      _start();
    }
  }

  static bool _sameSource(ShareImage a, ShareImage b) => switch ((a, b)) {
    (ShareAttachmentImage(attachmentId: final x), ShareAttachmentImage(attachmentId: final y)) => x == y,
    (ShareUrlImage(url: final x, turn: final tx), ShareUrlImage(url: final y, turn: final ty)) => x == y && tx == ty,
    (ShareProvidedImage(provider: final x), ShareProvidedImage(provider: final y)) => x == y,
    _ => false,
  };

  @override
  void dispose() {
    _reset();
    if (!_settled.isCompleted) _settled.complete();
    super.dispose();
  }

  void _reset() {
    _subscription?.close();
    _subscription = null;
    _stream?.removeListener(_listener);
    _stream = null;
    _info?.dispose();
    _info = null;
    _svg = null;
    _failed = false;
  }

  String? get _sessionId => ShareImageScope.sessionIdOf(context) ?? ref.read(currentSessionProvider);

  void _start() {
    switch (widget.image) {
      case ShareProvidedImage(:final provider):
        _decode(provider);
      case ShareAttachmentImage(:final attachment):
        final sessionId = _sessionId;
        if (sessionId == null) return _fail();
        _subscription = ref.listenManual(sessionImageProvider((sessionId, attachment)), (_, next) {
          switch (next) {
            case AsyncData(:final value):
              _decode(MemoryImage(value));
            case AsyncError():
              _fail();
            default:
          }
        }, fireImmediately: true);
      case ShareUrlImage(:final url, :final turn):
        _fromUrl(url, turn: turn);
    }
  }

  void _fromUrl(String url, {int? turn}) {
    switch (imageSourceOf(url)) {
      case WebImageSource(:final url) when isSvgUrl(url):
        _fail();
      case WebImageSource(:final url):
        _decode(NetworkImage(url));
      case DataImageSource(:final url):
        Uint8List bytes;
        try {
          bytes = UriData.parse(url).contentAsBytes();
        } on FormatException {
          return _fail();
        }
        isSvgUrl(url) ? _useSvg(bytes) : _decode(MemoryImage(bytes));
      case WorkspaceImageSource(:final path):
        final sessionId = _sessionId;
        if (sessionId == null) return _fail();
        final resolved = workspaceImagePath(
          path,
          cwd: path.startsWith('/') ? null : _cwdOf(sessionId),
          local: ref.read(artifactFilesProvider).isLocal,
        );
        final source = widget.image;
        ref
            .read(turn == null ? workspaceImageReaderProvider : turnWorkspaceImageReaderProvider(turn))
            .read(sessionId, resolved)
            .then(
              (image) {
                if (!mounted || !identical(source, widget.image)) return;
                switch (image) {
                  case RasterImage(:final provider):
                    _decode(provider);
                  case SvgImageBytes(:final bytes):
                    _useSvg(bytes);
                }
              },
              onError: (Object _) {
                if (mounted && identical(source, widget.image)) _fail();
              },
            );
      case UnsupportedImageSource():
        _fail();
    }
  }

  /// The session's working directory, when the app knows it (as the chat's
  /// own images resolve relative paths); only a chat already open is asked.
  String? _cwdOf(String sessionId) {
    final chat = chatProvider(sessionId);
    final header = ref.exists(chat) ? ref.read(chat.notifier).header : null;
    return header?.cwd ?? ref.read(sessionsProvider).value?.where((s) => s.sessionId == sessionId).firstOrNull?.cwd;
  }

  void _decode(ImageProvider provider) {
    if (!mounted) return;
    final resized = ResizeImage(
      provider,
      width: widget.decodeBound,
      height: widget.decodeBound,
      policy: ResizeImagePolicy.fit,
    );
    _stream?.removeListener(_listener);
    _stream = resized.resolve(createLocalImageConfiguration(context))..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _info?.dispose();
      _info = info;
      _failed = false;
    });
    _settle();
  }

  void _useSvg(Uint8List bytes) {
    if (!mounted) return;
    setState(() => _svg = bytes);
    // The SVG is parsed off the frame; give it a moment before it counts.
    Future<void>.delayed(const Duration(milliseconds: 300)).then((_) => _settle());
  }

  void _fail() {
    if (mounted) setState(() => _failed = true);
    _settle();
  }

  void _settle() {
    if (!_settled.isCompleted) _settled.complete();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final failed = _failed && info == null && _svg == null;
    final Size size;
    if (widget.size case final fixed?) {
      size = fixed;
    } else if (failed) {
      // A lone picture that cannot be had: a small calm tile, not a big hole.
      final aspect = (widget.image.aspect ?? ShareGalleryLayout.fallbackAspect(question: widget.question)).clamp(
        0.75,
        1.5,
      );
      final w = widget.question ? 120.0 : 168.0;
      size = Size(w, w / aspect);
    } else {
      final aspect = info != null && info.image.height > 0
          ? info.image.width / info.image.height
          : widget.image.aspect ?? ShareGalleryLayout.fallbackAspect(question: widget.question);
      size = ShareGalleryLayout.single(widget.maxWidth, aspect, question: widget.question);
    }

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final quiet = theme.colorScheme.onSurface.withValues(alpha: dark ? 0.08 : 0.055);
    final Widget picture;
    if (info != null) {
      picture = RawImage(
        image: info.image,
        scale: info.scale,
        fit: BoxFit.cover,
        width: size.width,
        height: size.height,
        filterQuality: FilterQuality.medium,
      );
    } else if (_svg case final bytes?) {
      picture = ColoredBox(
        color: Colors.white,
        child: memorySvg(
          bytes,
          fit: BoxFit.contain,
          error: (_) => _Placeholder(color: quiet),
        ),
      );
    } else {
      picture = _Placeholder(color: quiet, glyph: failed || widget.size == null);
    }

    final shape = RoundedSuperellipseBorder(
      borderRadius: widget.radius,
      side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.55), width: 0.5),
    );
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: info == null && _svg == null ? RoundedSuperellipseBorder(borderRadius: widget.radius) : shape,
        ),
        child: ClipRSuperellipse(
          borderRadius: widget.radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              picture,
              if (widget.more > 0)
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.42),
                  child: Center(
                    child: Text(
                      '+${widget.more}',
                      style: AppType.tabular(
                        theme.textTheme.headlineSmall!.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where a picture is (or was meant to be): a faint fill and, when there is
/// room for it to read as a picture, a small glyph. No words.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.color, this.glyph = true});

  final Color color;
  final bool glyph;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return ColoredBox(
      color: color,
      child: glyph
          ? Center(child: Icon(AppIcons.image, size: 20, color: colors.textTertiary.withValues(alpha: 0.7)))
          : null,
    );
  }
}
