import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart' show imageProviderBytes;
import '../../../state/attachments.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'image_actions.dart';
import 'image_gallery.dart';
import 'plus_panel.dart';
import 'stream_motion.dart';

export 'plus_panel.dart' show AttachSource;

/// The ＋ panel's tiles alone: without [files] (DSH Remote stages no files)
/// the two photo ones. The chat page opens the whole panel ([showPlusPanel]).
Future<AttachSource?> showAttachMenu(BuildContext context, {bool files = true}) async {
  final choice = await showPlusPanel(context, files: files);
  return choice is AttachChoice ? choice.source : null;
}

/// 40dp round ＋ at the composer's leading edge.
class AttachButton extends StatelessWidget {
  const AttachButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    // The same key shape as the send key beside it.
    final keyShape = DshThemeStyle.of(context).keyShape;
    final fill = scheme.onSurface.withValues(alpha: 0.06);
    return Semantics(
      button: true,
      enabled: enabled,
      label: l10n.chatAddAttachment,
      child: Tooltip(
        message: l10n.chatAddAttachment,
        child: InkResponse(
          onTap: onPressed == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onPressed!();
                },
          radius: 20,
          child: Container(
            width: 36,
            height: 36,
            decoration: keyShape == null
                ? BoxDecoration(color: fill, shape: BoxShape.circle)
                : ShapeDecoration(color: fill, shape: keyShape),
            child: Icon(
              AppIcons.add,
              size: 22,
              color: enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38),
            ),
          ),
        ),
      ),
    );
  }
}

/// Picked-but-unsent attachments, in a strip above the composer's text.
class ComposerTray extends StatelessWidget {
  const ComposerTray({super.key, required this.items, required this.onRemove, this.labels = const []});

  final List<DraftAttachment> items;
  final ValueChanged<DraftAttachment> onRemove;

  /// A small label on the tile at the same position (generation mode's
  /// 首帧 / 尾帧), 6 in from its bottom-left corner.
  final List<Widget?> labels;

  static const height = 56 + _overhang;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final images = items.where((a) => a.isImage).toList();
    final gallery = _draftGallery(images);
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = items[i];
          final tile = a.isImage
              ? _Thumb(
                  size: const Size.square(56),
                  heroTag: 'draft-${a.id}',
                  image: MemoryImage(a.bytes),
                  onTap: () => openAttachmentGallery(context, gallery, initialPage: images.indexOf(a)),
                )
              : FileCard(name: a.name, bytes: a.size, height: 56, tinted: true);
          final label = i < labels.length ? labels[i] : null;
          return _Removable(
            onRemove: () => onRemove(a),
            label: l10n.chatRemoveAttachment(a.name),
            child: label == null
                ? tile
                : Stack(
                    children: [
                      tile,
                      Positioned(left: 6, bottom: 6, child: label),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

List<ViewerImage> _draftGallery(Iterable<DraftAttachment> images) => [
  for (final image in images)
    ViewerImage(name: image.name, image: MemoryImage(image.bytes), heroTag: 'draft-${image.id}'),
];

/// How far the remove badge sticks out past a tray tile's corner.
const _overhang = 8.0;

class _Removable extends StatelessWidget {
  const _Removable({required this.child, required this.onRemove, required this.label});

  final Widget child;
  final VoidCallback onRemove;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The badge overhangs the tile's corner; the inset keeps all of it inside
    // the stack, so the whole circle is tappable.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: _overhang, right: _overhang),
          child: child,
        ),
        Positioned(
          top: 0,
          right: 0,
          child: Semantics(
            container: true,
            button: true,
            label: label,
            child: GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.72),
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                  child: Icon(AppIcons.close, size: 13, color: scheme.surface),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Attachments of one user message, right-aligned above its bubble: local
/// bytes while the message is in flight, then the session's stored copies.
class SentAttachments extends StatelessWidget {
  const SentAttachments.pending(this.drafts, {super.key}) : sessionId = null, images = const [], files = const [];

  const SentAttachments.echoed({super.key, required String this.sessionId, required this.images, required this.files})
    : drafts = const [];

  final List<DraftAttachment> drafts;
  final String? sessionId;
  final List<ImageAttachment> images;
  final List<FileAttachment> files;

  bool get isEmpty => drafts.isEmpty && images.isEmpty && files.isEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final draftImages = drafts.where((d) => d.isImage).toList();
    final gallery = _draftGallery(draftImages);
    // One image shows large at its own aspect; several become a grid of squares.
    final single = draftImages.length + images.length == 1;
    final children = <Widget>[
      for (var i = 0; i < draftImages.length; i++)
        _Thumb(
          size: single ? null : const Size.square(88),
          heroTag: 'draft-${draftImages[i].id}',
          image: MemoryImage(draftImages[i].bytes),
          onTap: () => openAttachmentGallery(context, gallery, initialPage: i),
        ),
      for (var i = 0; i < images.length; i++)
        _SessionImage(sessionId: sessionId!, images: images, index: i, single: single),
      for (final d in drafts)
        if (!d.isImage) FileCard(name: d.name, bytes: d.size),
      for (final f in files) FileCard(name: f.name ?? l10n.chatFile, bytes: f.bytes),
    ];
    return Wrap(alignment: WrapAlignment.end, spacing: 4, runSpacing: 4, children: children);
  }
}

/// Largest side of a lone image in a message.
const _singleMax = 208.0;

class _Thumb extends StatelessWidget {
  const _Thumb({required this.image, required this.heroTag, this.size, this.aspect, this.onTap, this.onLongPress});

  final ImageProvider image;
  final Object heroTag;

  /// Fixed box (cover); null = natural aspect within [_singleMax].
  final Size? size;

  /// Known width / height when [size] is null, so the box doesn't jump on load.
  final double? aspect;
  final VoidCallback? onTap;

  /// 「保存到相册」 / 「分享」 (sent images).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final placeholder = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth = ((size?.width ?? _singleMax) * dpr).round();
    Widget picture = Image(
      image: ResizeImage(image, width: decodeWidth, policy: ResizeImagePolicy.fit),
      fit: size == null ? BoxFit.contain : BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) =>
          frame == null && !sync ? ColoredBox(color: placeholder, child: const SizedBox.expand()) : child,
    );
    if (size case final s?) {
      picture = SizedBox.fromSize(size: s, child: picture);
    } else if (aspect case final a? when a > 0) {
      final w = a >= 1 ? _singleMax : _singleMax * a;
      picture = SizedBox(width: w, height: w / a, child: picture);
    } else {
      picture = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _singleMax, maxHeight: _singleMax, minWidth: 48, minHeight: 48),
        child: picture,
      );
    }
    return Semantics(
      image: true,
      button: onTap != null,
      label: l10n.chatImage,
      child: StreamPress(
        enabled: onTap != null,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Hero(
            tag: heroTag,
            child: Squircle.clip(radius: AppShape.md, child: picture),
          ),
        ),
      ),
    );
  }
}

class _SessionImage extends ConsumerWidget {
  const _SessionImage({required this.sessionId, required this.images, required this.index, required this.single});

  final String sessionId;
  final List<ImageAttachment> images;
  final int index;
  final bool single;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attachment = images[index];
    final bytes = ref.watch(sessionImageProvider((sessionId, attachment)));
    final w = attachment.width, h = attachment.height;
    final aspect = (w != null && h != null && h > 0) ? w / h : 1.0;
    final box = single ? null : const Size.square(88);
    final tag = 'img-$sessionId-${attachment.attachmentId}';
    void open() {
      // The bubble may unmount while the viewer is open. Its lazy pages must
      // read through the captured container, never a disposed WidgetRef.
      final container = ProviderScope.containerOf(context, listen: false);
      final gallery = [
        for (final image in images)
          ViewerImage.lazy(
            name: image.name ?? '',
            heroTag: 'img-$sessionId-${image.attachmentId}',
            load: () async =>
                MemoryImage(await container.read(sessionImageProvider((sessionId, image)).future)),
          ),
      ];
      openAttachmentGallery(context, gallery, initialPage: index);
    }

    return switch (bytes) {
      AsyncData(:final value) => _Thumb(
        size: box,
        aspect: aspect,
        heroTag: tag,
        image: sessionThumbnail(value, ((box?.width ?? _singleMax) * MediaQuery.devicePixelRatioOf(context)).round()),
        onTap: open,
        onLongPress: () =>
            showImageActions(context, image: MemoryImage(value), load: () async => value, name: attachment.name),
      ),
      _ => Semantics(
        image: true,
        button: true,
        label: context.l10n.chatImage,
        child: GestureDetector(
          onTap: open,
          behavior: HitTestBehavior.opaque,
          child: _ImagePlaceholder(size: box, aspect: aspect, failed: bytes.hasError),
        ),
      ),
    };
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.size, required this.aspect, this.failed = false});

  final Size? size;
  final double aspect;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = size?.width ?? (aspect >= 1 ? _singleMax : _singleMax * aspect);
    final h = size?.height ?? w / aspect;
    return Container(
      width: w,
      height: h,
      decoration: ShapeDecoration(color: scheme.onSurface.withValues(alpha: 0.06), shape: AppShape.card),
      child: failed ? Icon(AppIcons.imageBroken, size: 22, color: DshColors.of(context).textTertiary) : null,
    );
  }
}

/// A file attachment: type badge, name, "PDF · 1.2 MB".
class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.name, this.bytes, this.height = 56, this.tinted = false});

  final String name;
  final int? bytes;
  final double height;

  /// On the composer's glass (a faint fill) rather than a bubble-coloured card.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final dsh = DshColors.of(context);
    final ext = _extension(name);
    final (icon, tint) = _iconFor(ext);
    final badge = dsh.identity[tint % dsh.identity.length];
    final onBadge = dsh.onIdentity[tint % dsh.onIdentity.length];
    final meta = [if (ext != null) ext.toUpperCase(), if (bytes != null) formatBytes(bytes!)].join(' · ');
    // 外圆角 16、内边距 8、类型块圆角 8:内外同心(16 − 8)。
    return Container(
      height: height,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      decoration: ShapeDecoration(
        color: tinted ? theme.colorScheme.onSurface.withValues(alpha: 0.05) : surfaces.userBubble,
        shape: Squircle.border(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: height - 16,
            height: height - 16,
            decoration: ShapeDecoration(color: badge, shape: Squircle.border(8)),
            child: Icon(icon, size: 20, color: onBadge),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    maxLines: 1,
                    style: AppType.tabular(
                      theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String? _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1);
    return ext.length > 6 ? null : ext.toLowerCase();
  }

  static (IconData, int) _iconFor(String? ext) => switch (ext) {
    'pdf' => (AppIcons.pdf, 1),
    'doc' || 'docx' || 'odt' || 'rtf' => (AppIcons.document, 0),
    'xls' || 'xlsx' || 'csv' || 'tsv' || 'ods' => (AppIcons.spreadsheet, 3),
    'ppt' || 'pptx' || 'key' => (AppIcons.slides, 2),
    'zip' || 'tar' || 'gz' || 'tgz' || 'xz' || '7z' || 'rar' => (AppIcons.zip, 5),
    'md' || 'txt' || 'log' => (AppIcons.plainText, 0),
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'heic' || 'bmp' || 'svg' => (AppIcons.image, 2),
    'mp3' || 'wav' || 'm4a' || 'flac' || 'ogg' => (AppIcons.audio, 4),
    'mp4' || 'mov' || 'mkv' || 'webm' => (AppIcons.video, 4),
    'py' ||
    'js' ||
    'ts' ||
    'dart' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'sh' ||
    'java' ||
    'kt' ||
    'c' ||
    'cpp' ||
    'h' ||
    'go' ||
    'rs' ||
    'html' ||
    'css' ||
    'sql' ||
    'toml' ||
    'xml' => (AppIcons.code, 3),
    _ => (AppIcons.file, 5),
  };
}

/// Backwards-compatible entry point for a single full-resolution picture.
Future<void> openImageViewer(BuildContext context, ImageProvider image, {required Object heroTag, String? name}) =>
    openAttachmentGallery(context, [ViewerImage(name: name ?? '', image: image, heroTag: heroTag)]);

/// Pictures of one draft/message, including stored pictures not loaded yet.
Future<void> openAttachmentGallery(BuildContext context, List<ViewerImage> images, {int initialPage = 0}) {
  if (images.isEmpty) return Future.value();
  // Returning from a picture must not restore the composer's hidden keyboard.
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: _ImageViewer(images: List.unmodifiable(images), initialPage: initialPage.clamp(0, images.length - 1)),
      ),
    ),
  );
}

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.images, required this.initialPage});

  final List<ViewerImage> images;
  final int initialPage;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late int _page = widget.initialPage;
  final _loads = <int, Future<ImageProvider>>{};

  Future<ImageProvider> _image(int index) => _loads.putIfAbsent(index, () async {
    final item = widget.images[index];
    return item.image ?? await item.load!();
  });

  Future<Uint8List> _bytes(int index) async => imageProviderBytes(await _image(index));

  Future<void> _menu(int index) async {
    final ImageProvider image;
    try {
      image = await _image(index);
    } catch (_) {
      return; // A failed page keeps its placeholder, without an unhandled error.
    }
    if (!mounted || _page != index) return;
    final name = widget.images[index].name;
    await showImageActions(context, image: image, load: () => _bytes(index), name: name.isEmpty ? null : name);
  }

  Widget _placeholder(int index, {bool failed = false}) => Center(
    child: failed
        ? Icon(AppIcons.imageBroken, key: ValueKey('attachment-gallery-error-$index'), size: 36, color: Colors.white54)
        : const CircularProgressIndicator(color: Colors.white70),
  );

  Widget _picture(BuildContext context, int index) {
    Widget picture = FutureBuilder<ImageProvider>(
      future: _image(index),
      initialData: widget.images[index].image,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _placeholder(index, failed: true);
        final image = snapshot.data;
        if (image == null) return _placeholder(index);
        return Center(
          child: Image(
            key: ValueKey('attachment-gallery-image-$index'),
            image: image,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _placeholder(index, failed: true),
          ),
        );
      },
    );
    if (widget.images[index].heroTag case final tag?) {
      picture = Hero(tag: tag, child: picture);
    }
    return picture;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    final index = _page;
    final name = widget.images[index].name;
    // Its own (see-through) Scaffold keeps save notices above the dark veil.
    return Theme(
      data: buildDarkTheme(accent: DshSurfaces.of(context).accent, glassBlur: DshSurfaces.of(context).blurEnabled),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ImagePager(
                  itemCount: widget.images.length,
                  initialPage: widget.initialPage,
                  itemBuilder: _picture,
                  onPageChanged: (page) => setState(() => _page = page),
                  onTap: () => Navigator.of(context).maybePop(),
                  onLongPress: _menu,
                ),
              ),
              Positioned(
                top: padding.top + 6,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    GlassIconButton(
                      icon: AppIcons.close,
                      tooltip: l10n.commonClose,
                      grouped: false,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.images.length > 1)
                            Text(
                              '${index + 1} / ${widget.images.length}',
                              key: const ValueKey('attachment-gallery-page'),
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          if (name.isNotEmpty)
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GallerySaveButton(
                      key: ValueKey(index),
                      load: () => _bytes(index),
                      name: name.isEmpty ? null : name,
                      grouped: false,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
