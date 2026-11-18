// The card a generated batch gets in the chat (docs/design/media-generation.md
// §5.1–§5.3): the pictures in their grid, 「AI 生成 · 模型 · 比例 · 约 ¥x」 under
// them, then save · share · regenerate · ⋯. The files are the host's; they are
// read like reply images (in place on this phone's engine, downloaded once
// from a remote host), drawn at their shown size, and saved and shared from
// the original bytes.
//
// ```
//  ╭────────────────────────────────────╮
//  │               （图片）             │   H = min(480, 0.6 × window)
//  ╰────────────────────────────────────╯
//  AI 生成 · Seedream 5.0 · 1:1 · 约 ¥0.30   8 below, 13, tertiary
//  ⤓    ⇪    ↻    ⋯                          4 below, 20 icons 16 apart
// ```
//
// Video uses a supplied or locally extracted poster and opens the native viewer.
// A remote video is downloaded only after the user opens it, never for scrolling.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart';
import '../../../media/video.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../../state/features_state.dart' show jobsProvider;
import '../../../state/sessions_state.dart';
import '../../common/app_sheet.dart';
import '../../common/bleed.dart';
import '../../common/brief_notice.dart';
import '../../fx/image_gen/image_generation.dart';
import '../../settings/media_settings_page.dart' show MediaSettingsPage;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../artifact_preview.dart' show ArtifactPreviewPage;
import '../render/markdown_image.dart';
import '../widgets/image_actions.dart';
import '../widgets/message_actions.dart' show copyMessage;
import '../widgets/message_menu.dart';
import 'media_format.dart';
import 'media_grid.dart';
import 'media_image_feedback.dart';
import 'media_viewer.dart';
import 'media_video_viewer.dart';

/// What the chat lends a card: generate again, or take a picture back into
/// generation mode. Null fields leave their actions out.
class MediaCardActions extends InheritedWidget {
  const MediaCardActions({super.key, this.regenerate, this.revise, this.edit, this.makeVideo, required super.child});

  /// ↻: the same request again.
  final void Function(MediaMeta meta)? regenerate;

  /// 修改 on a refused description: it goes back into the composer, in
  /// generation mode.
  final void Function(MediaMeta meta)? revise;

  /// ⋯ › 编辑: into generation mode with [MediaItem] in the tray.
  final void Function(MediaMeta meta, MediaItem item)? edit;

  /// ⋯ › 做成视频: video mode, the picture as its first frame.
  final void Function(MediaMeta meta, MediaItem item)? makeVideo;

  static MediaCardActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MediaCardActions>();

  @override
  bool updateShouldNotify(MediaCardActions oldWidget) =>
      regenerate != oldWidget.regenerate ||
      revise != oldWidget.revise ||
      edit != oldWidget.edit ||
      makeVideo != oldWidget.makeVideo;
}

/// The card's measured spacing; `test/media/media_card_test.dart` checks it.
abstract final class MediaCardMetrics {
  /// Grid → metadata line.
  static const metaGap = 8.0;

  /// Metadata line → action row.
  static const actionsGap = 4.0;

  /// Action buttons: 36 round, 20 icons (16 between icons), bled 8 so the
  /// first icon lines up with the reply text.
  static const button = 36.0;
  static const icon = 20.0;
}

/// A generated batch.
class MediaCard extends ConsumerWidget {
  const MediaCard({super.key, required this.meta, this.sessionId});

  final MediaMeta meta;

  /// The conversation whose host has the files; defaults to the chat's.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId =
        this.sessionId ?? MarkdownImageScope.maybeOf(context)?.sessionId ?? ref.watch(currentSessionProvider);
    final windowHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = MediaGridMetrics.maxHeightFor(windowHeight);
    final job = meta.job;
    final progress = job == null || sessionId == null || meta.status != MediaStatus.running
        ? null
        : ref.watch(
            jobsProvider(sessionId).select((jobs) => jobs.value?.where((j) => j.id == job).firstOrNull?.progress),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final count = switch (meta.status) {
              MediaStatus.done => meta.items.length,
              _ => meta.items.isNotEmpty ? meta.items.length : (meta.request.n ?? 1),
            };
            final requested = meta.request.n ?? meta.items.length;
            final shown = meta.status == MediaStatus.done ? requested.clamp(meta.items.length, 4) : count;
            final layout = layoutMediaGrid(
              count: shown,
              aspect: mediaAspectOf(meta),
              width: width,
              maxHeight: maxHeight,
            );
            if (meta.status != MediaStatus.done || meta.items.isEmpty) {
              return _StateBox(meta: meta, layout: layout, progress: progress);
            }
            return SizedBox.fromSize(
              size: layout.size,
              child: Stack(
                children: [
                  for (final (i, cell) in layout.cells.indexed)
                    Positioned.fromRect(
                      rect: cell,
                      child: i < meta.items.length
                          ? MediaCell(
                              sessionId: sessionId,
                              meta: meta,
                              index: i,
                              radius: layout.radiusOf(i),
                              size: cell.size,
                            )
                          : _Missing(radius: layout.radiusOf(i)),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: MediaCardMetrics.metaGap),
        MediaMetaLine(meta: meta),
        if (meta.status != MediaStatus.running && sessionId != null)
          Padding(
            padding: const EdgeInsets.only(top: MediaCardMetrics.actionsGap),
            child: MediaActionRow(meta: meta, sessionId: sessionId),
          ),
      ],
    );
  }
}

/// One picture of a batch: a calm box of its shape until it has loaded, then
/// the picture fading in; a tap opens the viewer at it.
class MediaCell extends ConsumerStatefulWidget {
  const MediaCell({
    super.key,
    required this.sessionId,
    required this.meta,
    required this.index,
    required this.radius,
    required this.size,
  });

  final String? sessionId;
  final MediaMeta meta;
  final int index;
  final BorderRadius radius;
  final Size size;

  @override
  ConsumerState<MediaCell> createState() => _MediaCellState();
}

class _MediaCellState extends ConsumerState<MediaCell> {
  Future<LoadedImage>? _future;
  LoadedImage? _loaded;
  Object? _error;
  String? _path;
  String? _sessionId;
  CachedImageReader? _reader;
  ImageProvider? _displayProvider;
  int _attempt = 0;
  Future<ImageProvider?>? _posterFuture;
  ImageProvider? _videoPoster;
  ArtifactFiles? _posterFiles;
  MediaVideoChannel? _posterChannel;
  (String?, String)? _posterSource;

  MediaItem get _item => widget.meta.items[widget.index];

  /// What the cell draws: the picture, or a video's poster.
  String? get _imagePath => _item.isVideo ? _item.poster : _item.path;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(MediaCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final sessionId = widget.sessionId;
    final path = _imagePath;
    final reader = _reader != null && sessionId == _sessionId ? _reader! : ref.read(workspaceImageReaderProvider);
    if (path == _path &&
        sessionId == _sessionId &&
        identical(reader, _reader) &&
        (_future != null || _loaded != null || _error != null)) {
      return;
    }
    _path = path;
    _sessionId = sessionId;
    _reader = reader;
    _displayProvider = null;
    _attempt += 1;
    _loaded = null;
    _error = null;
    _future = null;
    if (sessionId == null || path == null) return;
    _loaded = reader.peek(sessionId, path);
    if (_loaded != null) return;
    final future = _future = reader.read(sessionId, path);
    future.then(
      (image) {
        if (mounted && _future == future) setState(() => _loaded = image);
      },
      onError: (Object error) {
        if (mounted && _future == future) setState(() => _error = error);
      },
    );
  }

  void _resolveVideo(ArtifactFiles files, MediaVideoChannel channel) {
    final source = (widget.sessionId, _item.path);
    if (identical(files, _posterFiles) && identical(channel, _posterChannel) && source == _posterSource) return;
    _posterFiles = files;
    _posterChannel = channel;
    _posterSource = source;
    _videoPoster = null;
    _posterFuture = null;
    final session = widget.sessionId;
    if (session == null || _item.poster != null) return;
    final future = _posterFuture = mediaVideoThumbnail(files, channel, session, _item);
    future.then(
      (poster) {
        if (mounted && identical(_posterFuture, future)) setState(() => _videoPoster = poster);
      },
      onError: (Object _) {
        /* A missing thumbnail never prevents playback. */
      },
    );
  }

  Future<void> _retry() async {
    final reader = _reader;
    final sessionId = _sessionId;
    final path = _path;
    await _displayProvider?.evict();
    if (!mounted || reader != _reader || sessionId != _sessionId || path != _path) return;
    if (_loaded case RasterImage(:final provider)) await provider.evict();
    if (!mounted || reader != _reader || sessionId != _sessionId || path != _path) return;
    if (sessionId != null && path != null) reader?.forget(sessionId, path);
    setState(() {
      _future = null;
      _loaded = null;
      _error = null;
      _resolve();
    });
  }

  @override
  Widget build(BuildContext context) {
    _resolve();
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final item = _item;
    final count = widget.meta.items.length;
    if (item.isVideo && item.poster == null) {
      final files = _posterFiles != null && _posterSource?.$1 == widget.sessionId
          ? _posterFiles!
          : ref.read(artifactFilesProvider);
      _resolveVideo(files, ref.read(mediaVideoChannelProvider));
    }
    final provider = switch (_loaded) {
      RasterImage(:final provider) => provider,
      _ => item.isVideo ? _videoPoster : null,
    };
    final gone = _error != null && imageErrorText(_error!) == l10n.chatImageNotFound;
    Widget content;
    if (provider != null) {
      content = Image(
        key: ValueKey((_sessionId, _path, _attempt)),
        image: _displayProvider = ResizeImage(
          provider,
          width: (widget.size.width * dpr).round(),
          policy: ResizeImagePolicy.fit,
        ),
        fit: BoxFit.cover,
        width: widget.size.width,
        height: widget.size.height,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, sync) => sync
            ? child
            : Stack(
                fit: StackFit.expand,
                children: [
                  if (frame == null) const MediaImageFeedback(),
                  AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: AppMotion.of(context, AppMotion.standard),
                    curve: AppMotion.std,
                    child: child,
                  ),
                ],
              ),
        errorBuilder: (_, error, _) => MediaImageFeedback(error: imageErrorText(error), onRetry: _retry),
      );
    } else if (item.isVideo) {
      content = Center(child: Text(l10n.mediaVideoNoPoster, style: Theme.of(context).textTheme.labelMedium));
    } else if (gone) {
      content = MediaImageFeedback(error: l10n.mediaFileGone, caption: widget.meta.prompt, onRetry: _retry);
    } else if (_error != null) {
      content = MediaImageFeedback(error: imageErrorText(_error!), onRetry: _retry);
    } else {
      content = item.isVideo
          ? Center(child: Text(l10n.mediaVideoNoPoster, style: Theme.of(context).textTheme.labelMedium))
          : const MediaImageFeedback();
    }
    if (item.isVideo) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          content,
          const Center(
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Icon(AppIcons.play, size: 28, color: Colors.white),
              ),
            ),
          ),
          Positioned(left: 8, bottom: 8, child: MediaOverlayLabel(text: videoBadgeText(item))),
        ],
      );
    }
    final semantics = count > 1
        ? '${l10n.mediaImageOf(widget.index + 1, count)}，${widget.meta.prompt ?? ''}'
        : (widget.meta.prompt ?? l10n.chatImage);
    return Semantics(
      image: true,
      button: true,
      label: semantics,
      child: GestureDetector(
        onTap: () => _open(context),
        onLongPress: provider == null || item.isVideo ? null : () => _menu(context, provider),
        child: ClipRSuperellipse(
          borderRadius: widget.radius,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: widget.radius,
                side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
              ),
            ),
            child: ColoredBox(color: dsh.codeWellHeader, child: content),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    final sessionId = widget.sessionId;
    if (sessionId == null) return;
    final item = _item;
    if (item.isVideo) {
      unawaited(
        openMediaVideoViewer(
          context,
          ref,
          sessionId,
          item,
          sourceFiles:
              _posterFiles ??
              switch (_reader?.inner) {
                ArtifactImageReader(:final files) => files,
                _ => null,
              },
        ).then((_) {
          if (mounted) setState(() => _posterChannel = null);
        }),
      );
      return;
    }
    unawaited(openMediaViewer(context, sessionId: sessionId, meta: widget.meta, index: widget.index, reader: _reader));
  }

  Future<void> _menu(BuildContext context, ImageProvider provider) async {
    final l10n = context.l10n;
    HapticFeedback.mediumImpact();
    final item = _item;
    final prompt = widget.meta.promptToCopy;
    final picked = await showAppSheetMenu(
      context,
      preview: MenuImagePreview(image: provider, name: item.name),
      items: [
        (AppIcons.save, l10n.chatSaveToPhotos, 'save'),
        (AppIcons.share, l10n.commonShare, 'share'),
        if (prompt != null && prompt.isNotEmpty) (AppIcons.copy, l10n.mediaCopyPrompt, 'copy'),
      ],
    );
    if (picked == null || !context.mounted) return;
    switch (picked) {
      case 'save':
        await saveImageToGallery(context, () => imageProviderBytes(provider), name: item.name);
      case 'share':
        await shareImageFile(context, () => imageProviderBytes(provider), name: item.name);
      case 'copy':
        await copyMessage(context, prompt!);
    }
  }
}

/// A one-group menu sheet (the image menu's look) that answers with the
/// picked item's id.
Future<String?> showAppSheetMenu(
  BuildContext context, {
  required Widget preview,
  required List<(IconData, String, String)> items,
}) => showAppSheet<String>(
  context,
  isScrollControlled: true,
  builder: (sheet) => MenuSheet(
    preview: preview,
    groups: [
      [
        for (final (icon, label, id) in items)
          MenuItem(icon: icon, label: label, onTap: () => Navigator.pop(sheet, id)),
      ],
    ],
  ),
);

/// 「视频 · 0:05」.
String videoBadgeText(MediaItem item) {
  final duration = item.duration;
  return duration == null ? appL10n.mediaKindVideo : '${appL10n.mediaKindVideo} · ${formatClip(duration)}';
}

/// A small label over a picture: 60% black, white text, radius 8, 20 high —
/// readable on any picture, the same in both themes.
class MediaOverlayLabel extends StatelessWidget {
  const MediaOverlayLabel({super.key, required this.text});

  final String text;

  static const height = 20.0;

  @override
  Widget build(BuildContext context) {
    final style = AppType.tabular(
      Theme.of(context).textTheme.labelSmall!.copyWith(color: Colors.white, height: 1.2, fontSize: 11.5),
    );
    // Hugs its text wherever it is put (no alignment: that would stretch it).
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: ShapeDecoration(color: Colors.black.withValues(alpha: 0.6), shape: Squircle.border(8)),
      child: Center(widthFactor: 1, child: Text(text, maxLines: 1, style: style)),
    );
  }
}

/// A cell the provider didn't fill (3 of 4 made).
class _Missing extends StatelessWidget {
  const _Missing({required this.radius});

  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: dsh.codeWellHeader,
        shape: RoundedSuperellipseBorder(
          borderRadius: radius,
          side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
        ),
      ),
      child: Center(
        child: Text(
          context.l10n.mediaNotGenerated,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: dsh.textTertiary),
        ),
      ),
    );
  }
}

/// Running or failed: the target shape, a quiet ring or a warning, one line.
class _StateBox extends StatelessWidget {
  const _StateBox({required this.meta, required this.layout, this.progress});

  final MediaMeta meta;
  final MediaGridLayout layout;
  final String? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final failed = meta.status == MediaStatus.failed;
    final cancelled = failed && meta.error?.code == 'cancelled';
    final text = switch (meta.status) {
      // The job's own line (「排队中」, 「生成中 · 42%」) when the host has one.
      MediaStatus.running => switch (progress?.trim()) {
        final p? when p.isNotEmpty => p,
        _ => context.l10n.mediaGenerating,
      },
      _ => cancelled ? context.l10n.mediaCancelled : mediaErrorText(meta.error),
    };
    final label = Text(
      text,
      textAlign: TextAlign.center,
      style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: dsh.textTertiary)),
    );
    if (!failed) {
      // Being made: a churning mosaic of the theme's colours fills the final shape
      // (Libraries.dev Image), the job's line on top.
      return SizedBox.fromSize(
        size: layout.size,
        child: ImageGeneration(
          generating: true,
          cardBg: dsh.codeWellHeader,
          borderRadius: BorderRadius.circular(MediaGridMetrics.outerRadius),
          child: Center(
            child: Padding(padding: const EdgeInsets.all(16), child: label),
          ),
        ),
      );
    }
    return SizedBox.fromSize(
      size: layout.size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: dsh.codeWellHeader,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(MediaGridMetrics.outerRadius),
            side: BorderSide(color: dsh.codeWellBorder, width: 0.5),
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!cancelled) ...[
                  Icon(AppIcons.warning, size: 20, color: dsh.textTertiary),
                  const SizedBox(height: 8),
                ],
                label,
                if (failed && !cancelled) ?_failureAction(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The way on from a failure (§5.3): 修改 for a refused description,
  /// 去设置 for a key or a limit. Elsewhere ↻ below the card is the way.
  Widget? _failureAction(BuildContext context) {
    final l10n = context.l10n;
    final (String label, VoidCallback onPressed) action;
    switch (meta.error?.code) {
      case 'policy' || 'policy-input' || 'policy-output':
        final revise = MediaCardActions.maybeOf(context)?.revise;
        if (revise == null || (meta.prompt?.trim() ?? '').isEmpty) return null;
        action = (l10n.mediaRevise, () => revise(meta));
      case 'auth' || 'unauthorized' || 'quota' || 'daily-limit':
        action = (
          l10n.chatGoToSettings,
          () =>
              unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MediaSettingsPage()))),
        );
      default:
        return null;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton(
        onPressed: action.$2,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
        ),
        child: Text(action.$1),
      ),
    );
  }
}

/// 「AI 生成 · Seedream 5.0 · 1:1 · 约 ¥0.30」: one line; the model's name gives
/// way first when it doesn't fit. 「AI 生成」 is always on what was made; a
/// batch still coming, or refused, says what was asked: 「Seedream 5.0 · 2 张」.
class MediaMetaLine extends StatelessWidget {
  const MediaMetaLine({super.key, required this.meta});

  final MediaMeta meta;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final style = AppType.tabular(
      Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 13, color: DshColors.of(context).textTertiary),
    );
    final model = meta.request.modelName;
    final tail = mediaMetaTail(meta);
    return Semantics(
      container: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final line = fitMediaMetaLine(
            lead: meta.status == MediaStatus.done ? l10n.mediaAiGenerated : null,
            model: model,
            tail: tail,
            // Measured as the Text draws it: the inherited style and the
            // locale (which picks the 「·」 glyph).
            style: DefaultTextStyle.of(context).style.merge(style),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
            maxWidth: constraints.maxWidth,
          );
          return Text(line, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: style);
        },
      ),
    );
  }
}

/// The metadata line in one paragraph (one look for every 「·」): whole when it
/// fits, else with the model's name cut short in its place mid-line —
/// [lead] (「AI 生成」) and what follows the model always show.
String fitMediaMetaLine({
  required String? lead,
  required String? model,
  required List<String> tail,
  required TextStyle style,
  required TextScaler textScaler,
  required double maxWidth,
  Locale? locale,
}) {
  const dot = ' · ';
  String compose(String? name) => [?lead, if (name != null && name.isNotEmpty) name, ...tail].join(dot);
  double width(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  final full = compose(model);
  if (model == null || model.isEmpty || width(full) <= maxWidth) return full;
  final chars = model.characters.toList();
  // The longest start of the name that still fits with 「…」.
  var lo = 0;
  var hi = chars.length - 1;
  var best = -1;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    if (width(compose('${chars.take(mid).join().trimRight()}…')) <= maxWidth) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best <= 0 ? compose(null) : compose('${chars.take(best).join().trimRight()}…');
}

/// Save · share · regenerate · ⋯, the reply action bar's look. Several
/// pictures: save and share take them all.
class MediaActionRow extends ConsumerStatefulWidget {
  const MediaActionRow({super.key, required this.meta, required this.sessionId});

  final MediaMeta meta;
  final String sessionId;

  @override
  ConsumerState<MediaActionRow> createState() => _MediaActionRowState();
}

class _MediaActionRowState extends ConsumerState<MediaActionRow> {
  bool _saving = false;

  MediaMeta get _meta => widget.meta;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveMediaItems(context, ref, widget.sessionId, _meta.items);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = DshColors.of(context).textTertiary;
    final actions = MediaCardActions.maybeOf(context);
    final style = IconButton.styleFrom(
      minimumSize: const Size.square(MediaCardMetrics.button),
      maximumSize: const Size.square(MediaCardMetrics.button),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: muted,
      iconSize: MediaCardMetrics.icon,
    );
    Widget key(IconData icon, String tooltip, VoidCallback? onPressed, {bool busy = false}) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed == null || busy
          ? null
          : () {
              HapticFeedback.lightImpact();
              onPressed();
            },
      style: style,
      icon: busy
          ? SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: muted))
          : Icon(icon),
    );
    final regenerate = actions?.regenerate;
    final failed = _meta.status == MediaStatus.failed;
    return Bleed(
      horizontal: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!failed && _meta.items.isNotEmpty) ...[
            key(AppIcons.save, l10n.chatSaveToPhotos, _save, busy: _saving),
            key(
              AppIcons.share,
              l10n.commonShare,
              () => unawaited(shareMediaItems(context, ref, widget.sessionId, _meta.items)),
            ),
          ],
          if (regenerate != null) key(AppIcons.regenerate, l10n.mediaRegenerate, () => regenerate(_meta)),
          key(AppIcons.more, l10n.commonMore, () => unawaited(_more(actions))),
        ],
      ),
    );
  }

  Future<void> _more(MediaCardActions? actions) async {
    final l10n = context.l10n;
    final meta = _meta;
    final first = meta.items.where((i) => !i.isVideo).firstOrNull;
    final prompt = meta.promptToCopy;
    final edit = actions?.edit;
    final makeVideo = actions?.makeVideo;
    final picked = await showAppSheetMenu(
      context,
      preview: MenuTextPreview(meta.prompt ?? l10n.mediaAiGenerated),
      items: [
        if (first != null && edit != null) (AppIcons.mediaEdit, l10n.mediaEdit, 'edit'),
        if (first != null && makeVideo != null) (AppIcons.generateVideo, l10n.mediaMakeVideo, 'video'),
        if (prompt != null && prompt.isNotEmpty) (AppIcons.copy, l10n.mediaCopyPrompt, 'copy'),
        if (meta.items.isNotEmpty) (AppIcons.folderOpen, l10n.mediaShowInFiles, 'files'),
        if (meta.items.any((i) => i.isVideo)) (AppIcons.openWith, l10n.mediaOpenElsewhere, 'open'),
        (AppIcons.mediaDetails, l10n.commonDetails, 'details'),
      ],
    );
    if (picked == null || !mounted) return;
    switch (picked) {
      case 'edit':
        edit!(meta, first!);
      case 'video':
        makeVideo!(meta, first!);
      case 'copy':
        await copyMessage(context, prompt!);
      case 'files':
        await Navigator.of(context).push(
          ArtifactPreviewPage.route(
            sessionId: widget.sessionId,
            artifact: Artifact(path: meta.items.first.path, origin: ArtifactOrigin.linked, turn: 0),
          ),
        );
      case 'open':
        await openMediaElsewhere(context, ref, widget.sessionId, meta.items.firstWhere((i) => i.isVideo));
      case 'details':
        await showMediaDetails(context, sessionId: widget.sessionId, meta: meta, item: meta.items.firstOrNull);
    }
  }
}

/// The original bytes of [item] (a picture), read where the host keeps it.
Future<Uint8List> mediaItemBytes(
  WidgetRef ref,
  String sessionId,
  MediaItem item, {
  WorkspaceImageReader? reader,
}) async {
  final image = await (reader ?? ref.read<CachedImageReader>(workspaceImageReaderProvider)).read(sessionId, item.path);
  return switch (image) {
    RasterImage(:final provider) => imageProviderBytes(provider),
    SvgImageBytes(:final bytes) => bytes,
  };
}

/// 「保存到相册」 for a batch: one says 「已保存到相册」 as usual; several say
/// how many. Videos stream from local materialized files into the gallery.
Future<void> saveMediaItems(BuildContext context, WidgetRef ref, String sessionId, List<MediaItem> items) async {
  final pictures = items.where((i) => !i.isVideo).toList();
  final videos = items.where((i) => i.isVideo).toList();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  if (pictures.length == 1 && videos.isEmpty) {
    await saveImageToGallery(
      context,
      () => mediaItemBytes(ref, sessionId, pictures.single),
      name: pictures.single.name,
    );
    return;
  }
  final media = ref.read(mediaChannelProvider);
  final files = ref.read(artifactFilesProvider);
  var saved = 0;
  var backedOut = false;
  String? failure;
  for (final item in pictures) {
    try {
      await saveToGallery(media, await mediaItemBytes(ref, sessionId, item), name: item.name);
      saved++;
    } on GallerySaveException catch (e) {
      // Backed out of the system's window: stop asking, and nothing to report for it.
      backedOut = e.code == 'cancelled';
      if (backedOut) break;
      failure ??= e.code;
    } catch (_) {
      failure ??= 'failed';
    }
  }
  for (final item in videos) {
    if (backedOut) break;
    try {
      final file = await files.materialize(
        sessionId,
        Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0),
      );
      await media.saveVideoFile(file.path, name: item.name);
      saved++;
    } on PlatformException catch (error) {
      // Backed out of HarmonyOS's album window: stop asking, nothing to report.
      if (saveWindowDismissed(error)) break;
      failure ??= error.code;
    } catch (_) {
      failure ??= 'failed';
    }
  }
  if (saved > 0) {
    HapticFeedback.lightImpact();
    messenger?.showBriefNotice(videos.isEmpty ? l10n.mediaSavedCount(saved) : l10n.mediaSavedFilesCount(saved));
  }
  if (failure != null) {
    messenger?.showSnackBar(SnackBar(content: Text(gallerySaveErrorText(failure))));
  }
}

/// 「分享」 a batch: the share sheet with every file of it, as stored.
Future<void> shareMediaItems(BuildContext context, WidgetRef ref, String sessionId, List<MediaItem> items) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final files = <XFile>[];
    final names = <String>[];
    for (final item in items) {
      if (item.isVideo) {
        final file = await ref
            .read(artifactFilesProvider)
            .materialize(sessionId, Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0));
        files.add(XFile(file.path, mimeType: item.mime, name: item.name));
        names.add(item.name);
        continue;
      }
      final image = await galleryImage(await mediaItemBytes(ref, sessionId, item));
      final name = galleryFileName(item.name, image.mime);
      files.add(XFile.fromData(image.bytes, mimeType: image.mime, name: name));
      names.add(name);
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files, fileNameOverrides: names));
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.chatShareFailed)));
  }
}

/// 「在其他应用中打开」: a video until the app plays them itself.
Future<void> openMediaElsewhere(BuildContext context, WidgetRef ref, String sessionId, MediaItem item) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(artifactFilesProvider)
        .open(sessionId, Artifact(path: item.path, origin: ArtifactOrigin.linked, turn: 0), chooser: true);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(artifactErrorText(e))));
  }
}
