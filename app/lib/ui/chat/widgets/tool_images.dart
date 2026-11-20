import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/artifact_files.dart';
import '../../../state/artifacts.dart';
import '../../../state/attachments.dart';
import '../../../state/chat_state.dart';
import '../../../state/sessions_state.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../artifact_preview.dart' show ArtifactPreviewPage, ImageViewerPage;
import '../render/markdown_image.dart' show MarkdownImageScope, workspaceImagePath;
import '../tool_view.dart';
import 'image_gallery.dart' show ViewerImage;

/// Tool results use the same session scope as replies, including subagent chats.
/// Providers are watched only while the details subtree is expanded.
class ToolImages extends ConsumerWidget {
  const ToolImages({super.key, required this.view});

  final ToolView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = MarkdownImageScope.maybeOf(context);
    final sessionId = scope?.sessionId ?? ref.watch(currentSessionProvider);
    final turn = scope?.turn;
    final sources = <({String name, ImageProvider? image, String? path})>[];
    for (final attachment in view.images) {
      ImageProvider? image;
      if (sessionId != null && attachment.attachmentId.isNotEmpty && (attachment.bytes ?? 0) <= maxThumbnailBytes) {
        final bytes = ref.watch(sessionImageProvider((sessionId, attachment))).value;
        if (bytes != null && bytes.length <= maxThumbnailBytes) image = MemoryImage(bytes);
      }
      sources.add((name: attachment.name ?? context.l10n.chatFile, image: image, path: null));
    }
    if (view.imagePath case final rawPath?) {
      final chat = sessionId == null ? null : chatProvider(sessionId);
      final header = chat != null && ref.exists(chat) ? ref.read(chat.notifier).header : null;
      final knownSessions = ref.exists(sessionsProvider) ? ref.read(sessionsProvider).value : null;
      final cwd = header?.cwd ?? knownSessions?.where((s) => s.sessionId == sessionId).firstOrNull?.cwd;
      final path = workspaceImagePath(
        rawPath,
        baseDir: scope?.baseDir,
        cwd: cwd,
        local: ref.read(artifactFilesProvider).isLocal,
      );
      final image = sessionId == null
          ? null
          : turn == null
          ? ref.watch(artifactThumbnailProvider((sessionId, path))).value
          : ref.watch(turnArtifactThumbnailProvider((sessionId, path, turn))).value;
      sources.add((name: path.split('/').last, image: image, path: path));
    }
    final gallery = [
      for (final source in sources)
        if (source.image != null && source.path == null) ViewerImage(name: source.name, image: source.image!),
    ];
    void open(int index) {
      final source = sources[index];
      if (source.path case final path?) {
        if (sessionId == null) return;
        Navigator.of(context).push(
          ArtifactPreviewPage.route(
            sessionId: sessionId,
            artifact: Artifact(path: path, origin: ArtifactOrigin.linked, turn: turn ?? 0, snapshotImage: turn != null),
          ),
        );
        return;
      }
      final initial = sources.take(index).where((source) => source.image != null && source.path == null).length;
      Navigator.of(context).push(ImageViewerPage.galleryRoute(images: gallery, initial: initial));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cellWidth = sources.length > 1 ? (width - 8) / 2 : width;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < sources.length; index++)
              SizedBox(
                width: cellWidth,
                height: 144,
                child: _Thumbnail(name: sources[index].name, image: sources[index].image, onTap: () => open(index)),
              ),
          ],
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.name, required this.image, required this.onTap});

  final String name;
  final ImageProvider? image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    Widget placeholder() => Center(child: Icon(AppIcons.image, size: 24, color: dsh.textTertiary));
    final provider = image;
    return Semantics(
      image: true,
      label: name,
      // A framed tile one step off the well, so letterboxed and missing
      // images keep the same geometry as loaded ones.
      child: DecoratedBox(
        decoration: ShapeDecoration(color: dsh.codeWellHeader, shape: Squircle.border(AppShape.sm)),
        position: DecorationPosition.background,
        child: DecoratedBox(
          decoration: ShapeDecoration(shape: AppShape.outlined(dsh.codeWellBorder, radius: AppShape.sm, width: 0.5)),
          position: DecorationPosition.foreground,
          child: Squircle.clip(
            radius: AppShape.sm,
            child: provider == null
                ? placeholder()
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final dpr = MediaQuery.devicePixelRatioOf(context);
                      return Center(
                        child: Squircle.clip(
                          radius: AppShape.sm,
                          child: Image(
                            image: ResizeImage(
                              provider,
                              width: (constraints.maxWidth * dpr).ceil().clamp(1, 1024),
                              height: (constraints.maxHeight * dpr).ceil().clamp(1, 1024),
                              policy: ResizeImagePolicy.fit,
                              allowUpscaling: false,
                            ),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => placeholder(),
                            frameBuilder: (context, child, frame, synchronous) {
                              if (frame == null && !synchronous) return placeholder();
                              return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child);
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}
