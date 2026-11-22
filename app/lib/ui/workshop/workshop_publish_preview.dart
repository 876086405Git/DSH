// The picture a submission shows in the workshop, on the 投稿 form.
//
// A pixel pet's is cut by the workshop from the first frame of its idle
// animation, so the form only asks whether to have one. Companion and theme
// covers are picked and normalized locally before being handed to the state layer
// at once (setPreview): it drops the packed result and takes the rights tick
// back, because the picture is part of what is sent. The form's text is not
// touched by it.
//
// The state layer keeps a cover's bytes to itself, so the page holds its own
// copy just to draw the thumbnail ([WorkshopCover]); that copy is only shown
// while it is the one the state layer has.

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/attachments.dart' show formatBytes;
import '../../state/workshop_auth_state.dart';
import '../../state/workshop_publish_sources.dart';
import '../../state/workshop_publish_state.dart';
import '../../workshop/workshop_models.dart';
import '../../workshop/workshop_preview.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../settings/settings_widgets.dart' show SettingsSection;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'workshop_publish_text.dart';

/// A cover the person picked: what the state layer was given, and the same
/// bytes for the thumbnail.
typedef WorkshopCover = ({WorkshopPreviewInput input, Uint8List bytes});

/// Picks an image and returns its upload-ready PNG, or null on cancellation.
final workshopCoverPickerProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return null;
    return workshopReadCover(picked.readAsByteStream(), length: await picked.length());
  },
);

/// Whether this workshop takes a picture with a submission of [kind].
bool workshopTakesPreview(WorkshopAccessState access, String kind) =>
    access.capabilities?.preview?.sources.contains(workshopPreviewSources[kind]) ?? false;

/// Hands [preview] (null: no picture) to the state layer. A refusal leaves
/// everything as it was and is said once, in a notice.
bool workshopPublishSetPreview(BuildContext context, WidgetRef ref, WorkshopPreviewInput? preview) {
  if (ref.read(workshopPublishProvider.notifier).setPreview(preview)) return true;
  final l10n = context.l10n;
  final refusal = ref.read(workshopPublishProvider).error;
  showBriefNotice(context, refusal == null ? l10n.workshopErrorBusy : workshopPublishErrorText(l10n, refusal));
  return false;
}

/// A cover in the item's square (the shape of `WorkshopEntryAvatar`). Without
/// [bytes] — the page was opened again and no longer has them — or when they
/// cannot be drawn, a picture glyph stands in.
class WorkshopCoverThumb extends StatelessWidget {
  const WorkshopCoverThumb({super.key, required this.bytes, this.size = 64});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = Center(
      child: Icon(AppIcons.image, size: size * 0.4, color: DshColors.of(context).textTertiary),
    );
    return Semantics(
      image: true,
      label: context.l10n.workshopPublishCoverChosen,
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: scheme.onSurface.withValues(alpha: 0.05),
            shape: Squircle.border(size * 0.25),
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: Squircle.border(size * 0.25)),
            child: bytes == null
                ? glyph
                : Image.memory(
                    bytes!,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    errorBuilder: (context, error, stack) => glyph,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The form's 「预览图」 (a pet) or 「封面」 (a companion) group. Absent when
/// the workshop takes no picture for this kind — unless one is already set,
/// which must stay removable.
class WorkshopPublishPreviewGroup extends ConsumerStatefulWidget {
  const WorkshopPublishPreviewGroup({
    super.key,
    required this.source,
    required this.cover,
    required this.onCover,
    this.enabled = true,
  });

  /// The source as the state layer has it now, with its picture.
  final WorkshopPublishSource source;

  /// The page's copy of the cover in [source], when it has one.
  final WorkshopCover? cover;

  /// The state layer took another cover, or none.
  final ValueChanged<WorkshopCover?> onCover;
  final bool enabled;

  @override
  ConsumerState<WorkshopPublishPreviewGroup> createState() => _WorkshopPublishPreviewGroupState();
}

class _WorkshopPublishPreviewGroupState extends ConsumerState<WorkshopPublishPreviewGroup> {
  /// Why the last picked file was not taken, as a stable code ('' when it
  /// could not be read at all).
  String? _problem;
  bool _picking = false;

  Future<void> _choose() async {
    if (_picking) return;
    _picking = true;
    WorkshopCover? cover;
    String? problem;
    try {
      final bytes = await ref.read(workshopCoverPickerProvider)();
      if (bytes != null) {
        final input = widget.source.kind == 'theme'
            ? WorkshopPreviewInput.themePng(bytes)
            : WorkshopPreviewInput.companionPng(bytes);
        cover = (input: input, bytes: bytes);
      }
    } on WorkshopException catch (error) {
      problem = error.code;
    } on Object {
      problem = '';
    } finally {
      _picking = false;
    }
    if (!mounted) return;
    if (cover == null) {
      // Closed without picking: what was said before still stands.
      if (problem != null) setState(() => _problem = problem);
      return;
    }
    setState(() => _problem = null);
    if (workshopPublishSetPreview(context, ref, cover.input)) widget.onCover(cover);
  }

  void _remove() {
    if (!workshopPublishSetPreview(context, ref, null)) return;
    setState(() => _problem = null);
    widget.onCover(null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = widget.source;
    final preview = source.preview;
    if (preview == null && !workshopTakesPreview(ref.watch(workshopAccessProvider), source.kind)) {
      return const SizedBox.shrink();
    }
    return switch (source.kind) {
      'pet' => _pet(l10n, preview != null),
      'companion' || 'theme' => _companion(l10n, preview),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _pet(L10n l10n, bool on) {
    void set(bool next) => workshopPublishSetPreview(context, ref, next ? const WorkshopPreviewInput.petIdle() : null);
    return SettingsSection(
      title: l10n.workshopPublishSectionPreview,
      children: [
        MergeSemantics(
          child: ListPageRow(
            title: l10n.workshopPublishPreviewSwitch,
            titleMaxLines: 2,
            subtitle: l10n.workshopPublishPreviewIdle,
            subtitleMaxLines: 2,
            onTap: widget.enabled ? () => set(!on) : null,
            trailing: Switch(
              key: const ValueKey('workshop-publish-preview-switch'),
              value: on,
              onChanged: widget.enabled ? set : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _companion(L10n l10n, WorkshopPreviewInput? preview) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final problem = _problem == null ? null : workshopCoverProblemText(l10n, _problem!);
    final line = problem ?? (preview == null ? l10n.workshopPublishCoverHelper : null);
    final action = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: const Size(44, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    return SettingsSection(
      title: l10n.workshopPublishSectionCover,
      footer: line == null
          ? null
          : Semantics(
              liveRegion: problem != null,
              child: Text(line, style: problem == null ? null : TextStyle(color: colors.danger)),
            ),
      children: [
        if (preview == null)
          ListPageRow(
            key: const ValueKey('workshop-publish-cover-pick'),
            icon: AppIcons.addImage,
            title: l10n.workshopPublishCoverPick,
            titleMaxLines: 2,
            onTap: widget.enabled ? () => unawaited(_choose()) : null,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(ListPageRow.horizontal, 10, 8, 10),
            child: Row(
              children: [
                WorkshopCoverThumb(bytes: widget.cover?.bytes),
                const SizedBox(width: ListPageRow.gap - 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '${preview.width}×${preview.height} · ${formatBytes(preview.size ?? 0)}',
                          style: AppType.tabular(
                            theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        children: [
                          TextButton(
                            style: action,
                            onPressed: widget.enabled ? () => unawaited(_choose()) : null,
                            child: Text(l10n.workshopPublishCoverReplace),
                          ),
                          TextButton(
                            style: action,
                            onPressed: widget.enabled ? _remove : null,
                            child: Text(l10n.workshopPublishCoverRemove),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The packed result's 「预览图」 row: what picture, if any, will be public
/// with it. [source] is the prepared metadata's preview source.
class WorkshopPublishPreviewRow extends StatelessWidget {
  const WorkshopPublishPreviewRow({super.key, required this.source, this.cover});

  final String? source;

  /// The page's copy of the cover that was packed, when it has one.
  final WorkshopCover? cover;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = l10n.workshopPublishSectionPreview;
    if (source == null) return ListPageRow(title: title, value: l10n.workshopPublishReviewPreviewNone);
    if (source == workshopPreviewSources['pet']) {
      return ListPageRow(title: title, value: l10n.workshopPublishReviewPreviewIdle);
    }
    if (cover == null) return ListPageRow(title: title, value: l10n.workshopPublishCoverChosen);
    return ListPageRow(title: title, trailing: WorkshopCoverThumb(bytes: cover!.bytes, size: 40));
  }
}
