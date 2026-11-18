// In-app previews of chat artifacts and workspace files: text and code page by
// page with syntax colours, Markdown rendered (front matter as fields), images
// zoomable, PDFs and the Office documents the Host converts as natively
// rendered pages, CSV / TSV / XLSX as tables. The preview follows its file
// (`workspaceFiles/changes`) and reloads when it changes. Anything else opens
// in an Android app.

import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../media/gallery.dart' show imageProviderBytes;
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/sheet_files.dart';
import '../../state/workspace_state.dart';
import '../common/capsule_chip.dart';
import '../files/file_glyph.dart';
import '../files/table_view.dart';
import '../session/workspace_files.dart' show formatBytes;
import '../share/share_entry.dart' show shareArtifact;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'render/code_block.dart';
import 'render/markdown_body.dart';
import 'render/markdown_image.dart' show MarkdownImageScope;
import 'widgets/artifact_card.dart' show ArtifactAction, showArtifactMenu;
import 'widgets/change_card.dart' show copyPath;
import 'widgets/image_actions.dart' show GallerySaveButton;
import 'widgets/image_gallery.dart' show ImagePager, ViewerImage, ZoomableImage;
import '../common/brief_notice.dart';

/// Lines per text page, and the most a preview holds.
const previewPageLines = 500;
const previewMaxLines = 3000;

/// CSV / TSV: one byte window (the Host's largest), at most this many rows.
const _tableWindow = 2 * 1024 * 1024;
const _tableRows = 5000;

/// XLSX parsed on the phone up to this size (the official preview's limit).
const _workbookBytes = 16 * 1024 * 1024;

/// Remote images and PDFs are fetched for a preview up to these sizes.
const _remoteImageBytes = 32 * 1024 * 1024;
const _remotePdfBytes = 64 * 1024 * 1024;

/// [path] 所在的目录;没有目录部分时为 null(交给会话的工作目录)。
String? _folderOf(String path) {
  final cut = path.lastIndexOf('/');
  if (cut < 0) return null;
  return cut == 0 ? '/' : path.substring(0, cut);
}

String _extensionOf(String path) {
  final name = baseName(path).toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1);
}

/// How a file is shown.
enum PreviewMode {
  image,
  pdf,

  /// Converted to PDF by the Host.
  office,

  /// XLSX, read on the phone.
  workbook,

  /// CSV / TSV.
  table,
  markdown,
  text,

  /// Opened in another app instead.
  unsupported,
}

/// [path]'s preview; Office documents need [officeToPdf] (the Host converts).
/// Unknown types try text: a binary file then says it can't be previewed.
PreviewMode previewModeOf(String path, {bool officeToPdf = false}) {
  final ext = _extensionOf(path);
  if (ext == 'xlsx' || ext == 'xlsm') return PreviewMode.workbook;
  if (ext == 'csv' || ext == 'tsv') return PreviewMode.table;
  if (isOfficePath(path)) {
    return officeToPdf ? PreviewMode.office : PreviewMode.unsupported;
  }
  return switch (artifactKindOf(path)) {
    ArtifactKind.image => ext == 'svg' ? PreviewMode.text : PreviewMode.image,
    ArtifactKind.pdf => PreviewMode.pdf,
    ArtifactKind.markdown => PreviewMode.markdown,
    ArtifactKind.text || ArtifactKind.web || ArtifactKind.other => PreviewMode.text,
    _ => PreviewMode.unsupported,
  };
}

const _textNames = {
  'readme',
  'license',
  'licence',
  'changelog',
  'authors',
  'notice',
  'dockerfile',
  'makefile',
  '.gitignore',
  '.gitattributes',
  '.editorconfig',
  '.env',
};

const _textExtensions = {'txt', 'log', 'text', 'rst', 'adoc', 'lock', 'svg'};

/// Code, configuration and plain text, by name.
bool isTextLikePath(String path) {
  final name = baseName(path).toLowerCase();
  if (_textNames.contains(name)) return true;
  if (_textExtensions.contains(_extensionOf(path))) return true;
  return languageForPath(path) != null;
}

/// App 里能直接预览的:位图、PDF、Markdown、文本与代码、CSV / TSV / XLSX;
/// [officeToPdf](Host 能转换)时还有 Office 文档(转成 PDF 再看)。
bool artifactPreviewable(Artifact artifact, {bool officeToPdf = false}) {
  final mode = previewModeOf(artifact.path, officeToPdf: officeToPdf);
  if (mode == PreviewMode.unsupported) return false;
  // A web page or a drawing made for the user reads better in an app that
  // renders it than as its source.
  if (artifact.kind == ArtifactKind.web || artifact.kind == ArtifactKind.image && mode == PreviewMode.text) {
    return false;
  }
  if (mode == PreviewMode.text && artifact.kind == ArtifactKind.other) {
    return isTextLikePath(artifact.path);
  }
  return true;
}

/// Runs a file action (artifact menus, the 文件 page's long press); errors
/// become a snack bar. A workspace-relative path is made absolute first.
Future<void> runArtifactAction(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required Artifact artifact,
  required ArtifactAction action,
}) async {
  final l10n = context.l10n;
  if (action == ArtifactAction.preview) {
    await Navigator.of(context).push(ArtifactPreviewPage.route(sessionId: sessionId, artifact: artifact));
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final target = await _absolute(ref, sessionId, artifact);
    if (action == ArtifactAction.copyPath) {
      if (context.mounted) await copyPath(context, target.path);
      return;
    }
    final files = ref.read(artifactFilesProvider);
    switch (action) {
      case ArtifactAction.open:
        await files.open(sessionId, target);
      case ArtifactAction.openWith:
        await files.open(sessionId, target, chooser: true);
      case ArtifactAction.share:
        if (context.mounted) await shareArtifact(context, sessionId: sessionId, artifact: target);
      case ArtifactAction.save:
        final where = await files.saveToDownloads(sessionId, target);
        messenger?.showBriefNotice(
          savedInChosenPlace(where)
              ? l10n.harmonySaved
              : l10n.viewArtifactSaved(where.replaceFirst(RegExp(r'^Download/'), l10n.viewDownloadFolder)),
        );
      case ArtifactAction.preview || ArtifactAction.copyPath:
        break;
    }
  } catch (e) {
    if (action == ArtifactAction.save && saveWindowDismissed(e)) return;
    messenger?.showSnackBar(SnackBar(content: Text(artifactErrorText(e))));
  }
}

/// [artifact] with an absolute path (the Host resolves a relative one).
Future<Artifact> _absolute(WidgetRef ref, String sessionId, Artifact artifact) async {
  if (artifact.path.startsWith('/')) return artifact;
  final source = ref.read(workspaceSourceProvider(sessionId));
  if (source == null) throw const ArtifactError('offline');
  final stat = await source.stat(artifact.path);
  if (stat.absolutePath.isEmpty) return artifact;
  return Artifact(
    path: stat.absolutePath,
    origin: artifact.origin,
    turn: artifact.turn,
    description: artifact.description,
    seq: artifact.seq,
    bytes: stat.bytes ?? artifact.bytes,
  );
}

/// A preview failure in words, and whether it is about the file itself.
({String title, String? message, _Fix fix}) _problemOf(Object error) {
  final code = switch (error) {
    DshRemoteException(:final code) => code,
    ArtifactError(:final code) => code,
    SheetFormatException() => 'sheet',
    _ => '',
  };
  return switch (code) {
    'sheet' => (title: appL10n.viewArtifactNoPreview, message: null, fix: _Fix.open),
    'workspace-file/not-text' => (
      title: appL10n.viewArtifactNoPreview,
      message: appL10n.viewArtifactNotText,
      fix: _Fix.open,
    ),
    'workspace-file/too-large' => (title: appL10n.viewArtifactLarge, message: null, fix: _Fix.open),
    'workspace-file/not-found' || 'missing' => (title: appL10n.viewArtifactMissing, message: null, fix: _Fix.none),
    'workspace-file/not-regular-file' => (title: appL10n.viewArtifactNotFile, message: null, fix: _Fix.none),
    _ => (title: appL10n.viewArtifactOpenFailed, message: artifactErrorText(error), fix: _Fix.retry),
  };
}

enum _Fix { none, retry, open }

/// 一个文件的预览页:图片可缩放,PDF 逐页显示,Markdown 排版显示,文本带行号,
/// 表格固定表头。右上角:分享和更多操作(打开、存到「下载」、复制路径)。
/// 文件变了自动刷新。
class ArtifactPreviewPage extends ConsumerStatefulWidget {
  const ArtifactPreviewPage({
    super.key,
    required this.sessionId,
    required this.artifact,
    this.gallery,
    this.initial = 0,
  }) : assert(gallery == null || gallery.length > 0),
       assert(initial >= 0),
       assert(gallery == null ? initial == 0 : initial < gallery.length);

  final String sessionId;
  final Artifact artifact;

  /// Bitmap workspace files only. File actions and the watch follow the current page.
  final List<Artifact>? gallery;
  final int initial;

  static Route<void> route({
    required String sessionId,
    required Artifact artifact,
    List<Artifact>? gallery,
    int initial = 0,
  }) => MaterialPageRoute<void>(
    builder: (_) => ArtifactPreviewPage(sessionId: sessionId, artifact: artifact, gallery: gallery, initial: initial),
  );

  @override
  ConsumerState<ArtifactPreviewPage> createState() => _ArtifactPreviewPageState();
}

class _ArtifactPreviewPageState extends ConsumerState<ArtifactPreviewPage> {
  bool _busy = false;

  /// Bumped when the file changes: the content reloads.
  int _revision = 0;

  /// Deleted while open.
  bool _gone = false;

  /// CSV that is not a table after all (bad quoting): shown as text.
  bool _asText = false;

  /// XLSX this phone could not read: the Host's PDF of it instead.
  bool _asPdf = false;

  StreamSubscription<DshWorkspaceWatchFrame>? _watch;
  Timer? _debounce;
  bool _ready = false;
  int _watchEpoch = 0;
  int _selectionEpoch = 0;
  late int _index = widget.initial;

  List<Artifact> get _images => widget.gallery ?? [widget.artifact];
  Artifact get _artifact => _images[_index];

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void dispose() {
    _stopFollowing();
    super.dispose();
  }

  void _stopFollowing() {
    _debounce?.cancel();
    _debounce = null;
    _stopWatch();
  }

  void _stopWatch() {
    _watchEpoch++;
    unawaited(_watch?.cancel());
    _watch = null;
    _ready = false;
  }

  void _select(int index) {
    if (index == _index) return;
    _selectionEpoch++;
    _stopFollowing();
    setState(() {
      _index = index;
      _revision = 0;
      _gone = false;
      _asText = false;
      _asPdf = false;
      _busy = false;
    });
    _follow();
  }

  /// Watches the file: a new version reloads, deletion says so.
  void _follow() {
    final epoch = _watchEpoch;
    final source = ref.read(workspaceSourceProvider(widget.sessionId));
    if (source == null) return;
    _watch = source
        .watch(_artifact.path)
        .listen(
          (frame) {
            if (!mounted || epoch != _watchEpoch) return;
            switch (frame) {
              case DshWorkspaceWatchReady():
                // The first one only says the watch is on; later ones follow
                // a reconnect, when changes may have been missed.
                if (_ready) _changed();
                _ready = true;
              case DshWorkspaceWatchChange(absent: true):
                _debounce?.cancel();
                if (mounted && !_gone) setState(() => _gone = true);
              case DshWorkspaceWatchChange():
                _changed();
            }
          },
          onError: (Object _) {},
          cancelOnError: true,
        );
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() {
        _gone = false;
        _revision++;
      });
    });
  }

  Future<void> _act(ArtifactAction action) async {
    if (_busy) return;
    if (action == ArtifactAction.preview) return;
    setState(() => _busy = true);
    final epoch = _selectionEpoch;
    try {
      await runArtifactAction(context, ref, sessionId: widget.sessionId, artifact: _artifact, action: action);
    } finally {
      if (mounted && epoch == _selectionEpoch) setState(() => _busy = false);
    }
  }

  Future<void> _menu() async {
    final epoch = _selectionEpoch;
    final files = ref.read(artifactFilesProvider);
    final action = await showArtifactMenu(
      context,
      artifact: _artifact,
      canFetch: files.canFetch,
      officeToPdf: files.canConvertOffice,
    );
    if (action != null && mounted && epoch == _selectionEpoch) await _act(action);
  }

  List<Widget> get _actions => [
    GlassIconButton(
      icon: ArtifactAction.share.icon,
      tooltip: context.l10n.commonShare,
      onPressed: _busy ? null : () => _act(ArtifactAction.share),
    ),
    GlassIconButton(icon: AppIcons.more, tooltip: context.l10n.viewArtifactMore, onPressed: _busy ? null : _menu),
  ];

  VoidCallback? get _openElsewhere => _busy ? null : () => _act(ArtifactAction.open);

  /// The folder the file is in: relative to the workspace when it is in it
  /// (「工作区」 at its top), else as the Host names it.
  String _where() {
    final root = ref.watch(workspaceRootProvider(widget.sessionId));
    final path = _artifact.path;
    if (root != null && path.startsWith('$root/')) {
      return _folderOf(path.substring(root.length + 1)) ?? context.l10n.viewWorkspace;
    }
    if (!path.startsWith('/')) return _folderOf(path) ?? context.l10n.viewWorkspace;
    return _folderOf(path) ?? path;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(workspaceSourceProvider(widget.sessionId), (_, _) {
      // Keep a pending refresh for the selected file.
      _stopWatch();
      _follow();
    });
    final l10n = context.l10n;
    // Only Office files depend on the connection (can the Host convert?).
    final office = isOfficePath(_artifact.path);
    final convert = office && ref.watch(artifactFilesProvider).canConvertOffice;
    var mode = previewModeOf(_artifact.path, officeToPdf: convert);
    if (mode == PreviewMode.table && _asText) mode = PreviewMode.text;
    if (mode == PreviewMode.workbook && _asPdf) mode = PreviewMode.office;

    if (mode == PreviewMode.image && (!_gone || _images.length > 1)) {
      final artifact = _artifact;
      Widget currentImage({bool zoomable = true}) => _gone
          ? _ImageViewerFrame.message(l10n.viewArtifactMissing)
          : _ImagePreview(
              key: ValueKey((_index, artifact.path)),
              sessionId: widget.sessionId,
              artifact: artifact,
              revision: _revision,
              onOpen: _openElsewhere,
              zoomable: zoomable,
            );
      return _ImageViewerFrame(
        title: artifact.name,
        page: _index,
        itemCount: _images.length,
        actions: [
          // Capture the selected file, including across an asynchronous save.
          GallerySaveButton(
            key: ValueKey((_index, artifact.path)),
            name: artifact.name,
            load: () async {
              final file = await ref
                  .read(artifactFilesProvider)
                  .materialize(widget.sessionId, await _absolute(ref, widget.sessionId, artifact));
              return file.readAsBytes();
            },
          ),
          ..._actions,
        ],
        child: _images.length == 1
            ? currentImage()
            : ImagePager(
                itemCount: _images.length,
                initialPage: widget.initial,
                onPageChanged: _select,
                // Only the selected file is read. Changing pages resets its
                // preview and binds the watch before loading the new pixels.
                itemBuilder: (_, index) =>
                    index == _index ? currentImage(zoomable: false) : const _Spinner(color: Colors.white70),
              ),
      );
    }
    if (mode == PreviewMode.text || mode == PreviewMode.markdown) {
      return _TextPreview(
        sessionId: widget.sessionId,
        artifact: _artifact,
        markdown: mode == PreviewMode.markdown,
        revision: _revision,
        gone: _gone,
        where: _where(),
        actions: _actions,
        onOpen: _openElsewhere,
      );
    }
    final Widget body;
    if (_gone) {
      body = PreviewNotice(icon: AppIcons.delete, title: l10n.viewArtifactMissing);
    } else {
      body = switch (mode) {
        PreviewMode.pdf || PreviewMode.office => _PdfPreview(
          key: ValueKey(mode),
          sessionId: widget.sessionId,
          artifact: _artifact,
          office: mode == PreviewMode.office,
          revision: _revision,
          onOpen: _openElsewhere,
        ),
        PreviewMode.workbook || PreviewMode.table => _TablePreview(
          sessionId: widget.sessionId,
          artifact: _artifact,
          workbook: mode == PreviewMode.workbook,
          revision: _revision,
          onOpen: _openElsewhere,
          onNotTable: () {
            if (mode == PreviewMode.workbook && !convert) return false;
            setState(() {
              if (mode == PreviewMode.table) {
                _asText = true;
              } else {
                _asPdf = true;
              }
            });
            return true;
          },
        ),
        _ => PreviewNotice(
          glyph: FileGlyph(name: _artifact.name, size: 56),
          title: l10n.viewArtifactNoPreview,
          message: _artifact.typeLabel,
          actionLabel: l10n.commonOpenWith,
          onAction: _openElsewhere,
        ),
      };
    }
    return _FramePage(
      title: _artifact.name,
      metaIsPath: _artifact.description == null,
      meta: [_artifact.description ?? _where(), if (_artifact.bytes != null) formatBytes(_artifact.bytes!)].join(' · '),
      actions: _actions,
      child: body,
    );
  }
}

/// A file that can't (or can no longer) be shown: a glyph, a line or two,
/// at most one way out.
class PreviewNotice extends StatelessWidget {
  const PreviewNotice({
    super.key,
    this.icon,
    this.glyph,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.busy = false,
  });

  final IconData? icon;
  final Widget? glyph;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// A quiet spinner above the text (a conversion running).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    Widget? graphic = glyph;
    if (graphic == null && icon != null) {
      graphic = SizedBox.square(
        dimension: 64,
        child: GlassSurface(
          tier: GlassTier.card,
          circle: true,
          child: Center(child: Icon(icon, size: 28, color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: dsh.textTertiary),
                ),
              )
            else if (graphic != null)
              Padding(padding: const EdgeInsets.only(bottom: 16), child: graphic),
            Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            if (message case final message?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary),
                ),
              ),
            if (actionLabel case final label?)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: FilledButton.tonal(onPressed: onAction, child: Text(label)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The notice for [error], with its way out wired to [onRetry] / [onOpen].
Widget _noticeFor(
  Object error, {
  required Artifact artifact,
  VoidCallback? onRetry,
  VoidCallback? onOpen,
  int? bytes,
  bool sized = true,
}) {
  final problem = _problemOf(error);
  final tooLarge = switch (error) {
    DshRemoteException(:final code) || ArtifactError(:final code) => code == 'workspace-file/too-large',
    _ => false,
  };
  final large = sized && tooLarge;
  return PreviewNotice(
    glyph: problem.fix == _Fix.open ? FileGlyph(name: artifact.name, size: 56) : null,
    icon: switch (problem.fix) {
      _Fix.none => AppIcons.deleted,
      _Fix.retry => AppIcons.error,
      _Fix.open => null,
    },
    title: problem.title,
    message: tooLarge
        ? !large || (bytes ?? artifact.bytes) == null
              ? null
              : formatBytes((bytes ?? artifact.bytes)!)
        : problem.message,
    actionLabel: switch (problem.fix) {
      _Fix.none => null,
      _Fix.retry => appL10n.commonRetry,
      _Fix.open => appL10n.commonOpenWith,
    },
    onAction: problem.fix == _Fix.retry ? onRetry : onOpen,
  );
}

// ── Frames ──────────────────────────────────────────────────────────────────

/// Bar (back, title, actions) over a full-height body: PDFs, tables,
/// notices.
class _FramePage extends StatelessWidget {
  const _FramePage({
    required this.title,
    this.meta,
    this.metaIsPath = true,
    required this.actions,
    required this.child,
  });

  final String title;
  final String? meta;

  /// [meta] starts with where the file is (mono, like any path); else it is
  /// the file's description, in the text face like [AppPage]'s (a size down:
  /// the bar keeps its one line of meta).
  final bool metaIsPath;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final padding = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            children: [
              SizedBox(height: padding.top),
              SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      GlassIconButton(
                        icon: AppIcons.back,
                        tooltip: l10n.commonBack,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              key: const ValueKey('preview-frame-title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(height: 1.25),
                            ),
                            if (meta != null)
                              Text(
                                meta!,
                                key: const ValueKey('preview-frame-meta'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: metaIsPath
                                    ? AppType.monoLabel(color: DshColors.of(context).textTertiary)
                                    : theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                        height: 1.35,
                                      ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions),
                    ],
                  ),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Text and Markdown ───────────────────────────────────────────────────────

class _TextPreview extends ConsumerStatefulWidget {
  const _TextPreview({
    required this.sessionId,
    required this.artifact,
    required this.markdown,
    required this.revision,
    required this.gone,
    required this.where,
    required this.actions,
    this.onOpen,
  });

  final String sessionId;
  final Artifact artifact;
  final bool markdown;
  final int revision;
  final bool gone;
  final String where;
  final List<Widget> actions;
  final VoidCallback? onOpen;

  @override
  ConsumerState<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends ConsumerState<_TextPreview> {
  String _text = '';
  int _lines = 0;
  bool _eof = false;
  String _version = '';
  int? _bytes;
  bool _loaded = false;
  bool _more = false;
  Object? _error;
  int _token = 0;

  WorkspaceSource? get _source => ref.read(workspaceSourceProvider(widget.sessionId));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_TextPreview old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_load(again: true));
  }

  /// From the top; [again] keeps as many lines as were shown.
  Future<void> _load({bool again = false}) async {
    final source = _source;
    if (source == null) {
      setState(() => _error = const ArtifactError('offline'));
      return;
    }
    // A page started during this read must keep its own busy state.
    final wasPaging = _more;
    final token = ++_token;
    final limit = again && _lines > previewPageLines
        ? _lines.clamp(previewPageLines, previewMaxLines)
        : previewPageLines;
    try {
      final page = await source.read(widget.artifact.path, offset: 1, limit: limit);
      if (!mounted || token != _token) return;
      setState(() {
        _text = page.text;
        _lines = page.lines;
        _eof = page.eof;
        _version = page.version;
        _bytes = page.bytes ?? _bytes;
        _loaded = true;
        if (wasPaging) _more = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || token != _token) return;
      // A reload that fails keeps what is on screen.
      setState(() {
        if (wasPaging) _more = false;
        if (!_loaded) _error = error;
      });
      // 文件较大 says how large.
      if (_bytes == null && widget.artifact.bytes == null) {
        try {
          final stat = await source.stat(widget.artifact.path);
          if (mounted && token == _token) setState(() => _bytes = stat.bytes);
        } catch (_) {}
      }
    }
  }

  Future<void> _loadMore() async {
    final source = _source;
    if (source == null || _eof || _more || !_loaded) return;
    if (_lines >= previewMaxLines) return;
    final token = _token;
    setState(() => _more = true);
    try {
      final page = await source.read(
        widget.artifact.path,
        offset: _lines + 1,
        limit: (previewMaxLines - _lines).clamp(1, previewPageLines),
      );
      if (!mounted || token != _token) return;
      if (page.version.isNotEmpty && _version.isNotEmpty && page.version != _version) {
        // The file changed between pages: start over rather than mix them.
        setState(() => _more = false);
        await _load(again: true);
        return;
      }
      setState(() {
        if (page.lines > 0) {
          _text = _lines == 0 ? page.text : '$_text\n${page.text}';
          _lines += page.lines;
        }
        _eof = page.eof || page.lines == 0;
        _more = false;
      });
    } catch (_) {
      if (mounted && token == _token) setState(() => _more = false);
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < 900) {
      unawaited(_loadMore());
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final artifact = widget.artifact;
    final bytes = _bytes ?? artifact.bytes;
    final subtitle = artifact.description ?? widget.where;
    final Widget content;
    if (widget.gone) {
      content = _InlineNotice(
        child: PreviewNotice(icon: AppIcons.delete, title: l10n.viewArtifactMissing),
      );
    } else if (_error case final error?) {
      content = _InlineNotice(
        child: _noticeFor(
          error,
          artifact: artifact,
          sized: false,
          onRetry: () {
            setState(() => _error = null);
            unawaited(_load());
          },
          onOpen: widget.onOpen,
        ),
      );
    } else if (!_loaded) {
      content = const _Spinner();
    } else if (_lines == 0) {
      content = _message(context, l10n.viewArtifactEmpty);
    } else {
      content = Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.markdown ? 20 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.markdown)
              _MarkdownDocument(sessionId: widget.sessionId, path: artifact.path, text: _text)
            else
              CodeBlock(code: _text, language: languageForPath(artifact.path), showLineNumbers: true),
            if (_more)
              const _Spinner(padding: EdgeInsets.all(16))
            else if (!_eof && _lines >= previewMaxLines)
              _MoreElsewhere(text: l10n.viewArtifactLines(previewMaxLines), onOpen: widget.onOpen),
          ],
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: AppPage(
        title: artifact.name,
        subtitle: Text(
          [subtitle, if (bytes != null) formatBytes(bytes)].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: artifact.description == null
              ? AppType.mono(size: 12.5, height: 1.4, color: theme.colorScheme.onSurfaceVariant)
              : theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        actions: widget.actions,
        slivers: [SliverToBoxAdapter(child: content)],
      ),
    );
  }

  Widget _message(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}

/// A notice placed in a page's flow rather than filling a frame.
class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.5, child: child);
}

/// The end of what the preview holds: one line and the way to the rest.
class _MoreElsewhere extends StatelessWidget {
  const _MoreElsewhere({required this.text, this.onOpen});

  final String text;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
          ),
          TextButton(onPressed: onOpen, child: Text(l10n.commonOpenWith)),
        ],
      ),
    );
  }
}

/// A leading YAML front matter block (`---` … `---`): its fields, then the
/// rest. Fields are the block's top-level `key: value` lines; a block with
/// anything else is kept as written.
({List<(String, String)>? fields, String? raw, String body}) splitFrontMatter(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    return (fields: null, raw: null, body: text);
  }
  final end = lines.indexWhere((l) => l.trimRight() == '---' || l.trimRight() == '...', 1);
  if (end < 0) return (fields: null, raw: null, body: text);
  final block = lines.sublist(1, end);
  final body = lines.sublist(end + 1).join('\n');
  if (block.every((l) => l.trim().isEmpty)) {
    return (fields: null, raw: null, body: body);
  }
  final pair = RegExp(r'^([A-Za-z0-9_][\w .-]*?)\s*:\s*(.*)$');
  final fields = <(String, String)>[];
  for (final line in block) {
    if (line.trim().isEmpty) continue;
    final m = pair.firstMatch(line);
    if (m == null || line.startsWith(' ') || line.startsWith('\t')) {
      return (fields: null, raw: block.join('\n'), body: body);
    }
    var value = m.group(2)!.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    fields.add((m.group(1)!, value));
  }
  return (fields: fields, raw: null, body: body);
}

class _MarkdownDocument extends StatelessWidget {
  const _MarkdownDocument({required this.sessionId, required this.path, required this.text});

  final String sessionId;
  final String path;
  final String text;

  @override
  Widget build(BuildContext context) {
    final front = splitFrontMatter(text);
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (front.fields case final fields?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassSurface(
              tier: GlassTier.card,
              borderRadius: AppShape.radiusMd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (key, value) in fields)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            SizedBox(
                              width: 96,
                              child: Text(
                                key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.monoLabel(color: dsh.textTertiary),
                              ),
                            ),
                            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          )
        else if (front.raw case final raw?)
          CodeBlock(code: raw, language: 'yaml'),
        // 文档里的相对图片路径从它自己的目录算起。
        MarkdownImageScope(
          sessionId: sessionId,
          baseDir: _folderOf(path),
          child: MarkdownBody(text: front.body),
        ),
      ],
    );
  }
}

// ── Tables ──────────────────────────────────────────────────────────────────

/// Parses off the UI isolate.
List<SheetGrid> _readWorkbook(Uint8List bytes) => parseXlsx(bytes, maxRows: _tableRows);

class _TablePreview extends ConsumerStatefulWidget {
  const _TablePreview({
    required this.sessionId,
    required this.artifact,
    required this.workbook,
    required this.revision,
    required this.onNotTable,
    this.onOpen,
  });

  final String sessionId;
  final Artifact artifact;
  final bool workbook;
  final int revision;

  /// The content isn't a table this view can read: false when the page has
  /// no other way to show it.
  final bool Function() onNotTable;
  final VoidCallback? onOpen;

  @override
  ConsumerState<_TablePreview> createState() => _TablePreviewState();
}

class _TablePreviewState extends ConsumerState<_TablePreview> {
  List<SheetGrid>? _sheets;
  Object? _error;
  int? _bytes;
  int _sheet = 0;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_TablePreview old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_load());
  }

  Future<void> _load() async {
    final token = ++_token;
    try {
      final sheets = widget.workbook ? await _workbook() : await _delimited();
      if (!mounted || token != _token) return;
      setState(() {
        _sheets = sheets;
        _error = null;
        if (_sheet >= sheets.length) _sheet = 0;
      });
    } on SheetFormatException catch (error) {
      if (!mounted || token != _token) return;
      if (!widget.onNotTable()) setState(() => _error = error);
    } catch (error) {
      if (!mounted || token != _token) return;
      if (_sheets == null) setState(() => _error = error);
    }
  }

  Future<List<SheetGrid>> _delimited() async {
    final source = ref.read(workspaceSourceProvider(widget.sessionId));
    if (source == null) throw const ArtifactError('offline');
    final window = await source.readWindow(widget.artifact.path, length: _tableWindow);
    _bytes = window.bytes;
    final text = decodeTableText(window.data);
    final tsv = _extensionOf(widget.artifact.path) == 'tsv';
    return [parseDelimited(text, delimiter: tsv ? '\t' : ',', maxRows: _tableRows, partial: !window.eof)];
  }

  Future<List<SheetGrid>> _workbook() async {
    final files = ref.read(artifactFilesProvider);
    if (!files.isLocal) {
      final source = ref.read(workspaceSourceProvider(widget.sessionId));
      final stat = await source?.stat(widget.artifact.path);
      _bytes = stat?.bytes;
      if ((stat?.bytes ?? 0) > _workbookBytes) {
        throw DshRemoteException('workspace-file/too-large', 'workbook', {});
      }
    }
    final file = await files.materialize(widget.sessionId, await _absolute(ref, widget.sessionId, widget.artifact));
    final size = await file.length();
    _bytes = size;
    if (size > _workbookBytes) {
      throw DshRemoteException('workspace-file/too-large', 'workbook', {});
    }
    final bytes = await file.readAsBytes();
    return compute(_readWorkbook, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_error case final error?) {
      return _noticeFor(
        error,
        artifact: widget.artifact,
        bytes: _bytes,
        onRetry: () {
          setState(() => _error = null);
          unawaited(_load());
        },
        onOpen: widget.onOpen,
      );
    }
    final sheets = _sheets;
    if (sheets == null) return const _Spinner();
    final grid = sheets[_sheet];
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final note = [
      if (grid.truncated) l10n.viewArtifactRows(grid.rows.length),
      if (grid.columns > 200) l10n.viewArtifactColumns,
    ].join(context.l10n.viewListSeparator);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sheets.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              children: [
                for (final (i, sheet) in sheets.indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CapsuleChoiceChip(
                      label: sheet.name.isEmpty ? l10n.viewArtifactWorksheet(i + 1) : sheet.name,
                      selected: i == _sheet,
                      onSelected: () => setState(() => _sheet = i),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: grid.isEmpty
              ? PreviewNotice(
                  icon: AppIcons.spreadsheet,
                  title: sheets.length > 1 ? l10n.viewArtifactEmptySheet : l10n.viewArtifactEmptyTable,
                )
              : Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    sheets.length > 1 ? 0 : 8,
                    12,
                    note.isEmpty ? MediaQuery.paddingOf(context).bottom + 12 : 0,
                  ),
                  child: GlassSurface(
                    tier: GlassTier.card,
                    borderRadius: AppShape.radiusMd,
                    child: ClipRSuperellipse(
                      borderRadius: AppShape.radiusMd,
                      child: SheetTable(key: ValueKey(_sheet), grid: grid),
                    ),
                  ),
                ),
        ),
        if (note.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(24, 10, 24, MediaQuery.paddingOf(context).bottom + 12),
            child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
          ),
      ],
    );
  }
}

// ── PDF and Office ──────────────────────────────────────────────────────────

class _PdfPreview extends ConsumerStatefulWidget {
  const _PdfPreview({
    super.key,
    required this.sessionId,
    required this.artifact,
    required this.office,
    required this.revision,
    this.onOpen,
  });

  final String sessionId;
  final Artifact artifact;
  final bool office;
  final int revision;
  final VoidCallback? onOpen;

  @override
  ConsumerState<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends ConsumerState<_PdfPreview> {
  File? _file;
  Object? _error;
  int? _bytes;
  int _token = 0;

  /// Bumped with every new file, so the pages render again.
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_PdfPreview old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_load());
  }

  Future<void> _load() async {
    final token = ++_token;
    final files = ref.read(artifactFilesProvider);
    try {
      final File file;
      if (widget.office) {
        file = await files.officePdf(widget.sessionId, widget.artifact);
      } else {
        if (!files.isLocal) {
          final stat = await ref.read(workspaceSourceProvider(widget.sessionId))?.stat(widget.artifact.path);
          _bytes = stat?.bytes;
          if ((stat?.bytes ?? 0) > _remotePdfBytes) {
            throw DshRemoteException('workspace-file/too-large', 'pdf', {});
          }
        }
        file = await files.materialize(widget.sessionId, await _absolute(ref, widget.sessionId, widget.artifact));
      }
      if (!mounted || token != _token) return;
      if (_file != null) {
        // The renderer keeps the old document open by path.
        await ref.read(filesChannelProvider).pdfClose().catchError((Object _) {});
      }
      if (!mounted || token != _token) return;
      setState(() {
        _file = file;
        _error = null;
        _shown++;
      });
    } catch (error) {
      if (!mounted || token != _token) return;
      if (_file == null) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final file = _file;
    if (file != null) {
      return _PdfPages(key: ValueKey(_shown), path: file.path);
    }
    if (_error case final error?) {
      if (widget.office && _problemOf(error).fix == _Fix.retry) {
        // Conversion failed: the phone's own apps stay one tap away.
        return PreviewNotice(
          glyph: FileGlyph(name: widget.artifact.name, size: 56),
          title: l10n.viewArtifactConvertFailed,
          message: artifactErrorText(error),
          actionLabel: l10n.commonOpenWith,
          onAction: widget.onOpen,
        );
      }
      return _noticeFor(
        error,
        artifact: widget.artifact,
        bytes: _bytes,
        onRetry: () {
          setState(() => _error = null);
          unawaited(_load());
        },
        onOpen: widget.onOpen,
      );
    }
    if (!widget.office) return const _Spinner();
    return _Waiting(text: l10n.viewArtifactConverting, busy: true, onOpen: widget.onOpen);
  }
}

// ── Images ──────────────────────────────────────────────────────────────────

class _ImagePreview extends ConsumerStatefulWidget {
  const _ImagePreview({
    super.key,
    required this.sessionId,
    required this.artifact,
    required this.revision,
    this.onOpen,
    this.zoomable = true,
  });

  final String sessionId;
  final Artifact artifact;
  final int revision;
  final VoidCallback? onOpen;
  final bool zoomable;

  @override
  ConsumerState<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends ConsumerState<_ImagePreview> {
  File? _file;
  Object? _error;
  int? _bytes;
  int _token = 0;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_ImagePreview old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_load());
  }

  Future<void> _load() async {
    final token = ++_token;
    final files = ref.read(artifactFilesProvider);
    try {
      if (!files.isLocal) {
        final stat = await ref.read(workspaceSourceProvider(widget.sessionId))?.stat(widget.artifact.path);
        _bytes = stat?.bytes;
        if ((stat?.bytes ?? 0) > _remoteImageBytes) {
          throw DshRemoteException('workspace-file/too-large', 'image', {});
        }
      }
      final file = await files.materialize(widget.sessionId, await _absolute(ref, widget.sessionId, widget.artifact));
      if (!mounted || token != _token) return;
      // A gallery revisit may have missed changes while another file was watched.
      await FileImage(file).evict();
      if (!mounted || token != _token) return;
      setState(() {
        _file = file;
        _error = null;
        _shown++;
      });
    } catch (error) {
      if (!mounted || token != _token) return;
      if (_file == null) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final file = _file;
    if (file != null) {
      final image = _viewerImage(context, FileImage(file), widget.artifact.description ?? widget.artifact.name);
      return widget.zoomable ? ZoomableImage(key: ValueKey(_shown), child: image) : image;
    }
    if (_error case final error?) {
      final problem = _problemOf(error);
      final size = _bytes ?? widget.artifact.bytes;
      return _ImageViewerFrame.message(
        problem.message ?? [problem.title, if (size != null) formatBytes(size)].join(' · '),
        actionLabel: problem.fix == _Fix.open ? l10n.commonOpenWith : null,
        onAction: widget.onOpen,
      );
    }
    return const _Spinner(color: Colors.white70);
  }
}

/// 全屏看一张不在工作区里的图片(回复里的网页图片、`data:` 图片):和产物
/// 预览的图片页同一个样子,文件操作只有「保存到相册」。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required String this._title, required ImageProvider this._image})
    : images = null,
      initial = 0;

  const ImageViewerPage.gallery({super.key, required List<ViewerImage> images, this.initial = 0})
    : assert(images.length > 0),
      assert(initial >= 0 && initial < images.length),
      images = images,
      _title = null,
      _image = null;

  final String? _title;
  final ImageProvider? _image;
  final List<ViewerImage>? images;
  final int initial;

  String get title => _title ?? images![initial].name;
  ImageProvider? get image => _image ?? images![initial].image;

  static Route<void> route({required String title, required ImageProvider image}) => MaterialPageRoute<void>(
    builder: (_) => ImageViewerPage(title: title, image: image),
  );

  static Route<void> galleryRoute({required List<ViewerImage> images, int initial = 0}) => MaterialPageRoute<void>(
    builder: (_) => ImageViewerPage.gallery(images: images, initial: initial),
  );

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final List<ViewerImage> _images = widget.images ?? [ViewerImage(name: widget.title, image: widget.image!)];
  late int _index = widget.initial;
  final _pending = <int, Future<ImageProvider>>{};

  Future<ImageProvider> _resolve(int index) => _pending.putIfAbsent(index, () {
    final source = _images[index];
    final image = source.image;
    return image == null ? Future<ImageProvider>.sync(source.load!) : SynchronousFuture(image);
  });

  Widget _page(BuildContext context, int index) {
    final source = _images[index];
    Widget imageWidget(ImageProvider image) {
      final child = _viewerImage(context, image, source.name);
      return source.heroTag == null ? child : Hero(tag: source.heroTag!, child: child);
    }

    if (source.image case final image?) return imageWidget(image);
    return FutureBuilder<ImageProvider>(
      future: _resolve(index),
      builder: (context, snapshot) {
        if (snapshot.data case final image?) return imageWidget(image);
        if (snapshot.hasError) return _ImageViewerFrame.message(context.l10n.viewArtifactImageFailed);
        return const _Spinner(color: Colors.white70);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final source = _images[index];
    return _ImageViewerFrame(
      title: source.name,
      page: index,
      itemCount: _images.length,
      actions: [
        GallerySaveButton(
          key: ValueKey(index),
          load: () async => imageProviderBytes(await _resolve(index)),
          name: source.name,
        ),
      ],
      child: ImagePager(
        itemCount: _images.length,
        initialPage: widget.initial,
        itemBuilder: _page,
        onPageChanged: (index) => setState(() => _index = index),
      ),
    );
  }
}

/// 图片预览的外框:黑底全屏,左上返回 + 标题,右上操作。
class _ImageViewerFrame extends StatelessWidget {
  const _ImageViewerFrame({
    required this.title,
    required this.child,
    this.actions = const [],
    this.page = 0,
    this.itemCount = 1,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final int page;
  final int itemCount;

  static Widget message(String text, {String? actionLabel, VoidCallback? onAction}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: Text(actionLabel),
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(child: child),
            if (itemCount > 1)
              Positioned(
                bottom: padding.bottom + 16,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Text(
                    '${page + 1} / $itemCount',
                    key: const ValueKey('image-gallery-page'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            Positioned(
              top: padding.top + 6,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  GlassIconButton(
                    icon: AppIcons.back,
                    tooltip: l10n.commonBack,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _viewerImage(BuildContext context, ImageProvider image, String semanticLabel) => Center(
  child: Image(
    image: image,
    fit: BoxFit.contain,
    semanticLabel: semanticLabel,
    errorBuilder: (_, _, _) => _ImageViewerFrame.message(context.l10n.viewArtifactImageFailed),
  ),
);

/// A conversion in progress or failed, with "open with an app" instead.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.text, required this.busy, this.onOpen});

  final String text;
  final bool busy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(AppIcons.openExternal, size: 18),
              label: Text(l10n.viewArtifactPhoneOpen),
            ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({this.color, this.padding = const EdgeInsets.all(32)});
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Center(
      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
    ),
  );
}

/// A PDF's pages, rendered natively one by one as they scroll in; pinch to
/// zoom.
class _PdfPages extends ConsumerStatefulWidget {
  const _PdfPages({super.key, required this.path});

  final String path;

  @override
  ConsumerState<_PdfPages> createState() => _PdfPagesState();
}

class _PdfPagesState extends ConsumerState<_PdfPages> {
  late final FilesChannel _channel = ref.read(filesChannelProvider);
  late final Future<List<({int width, int height})>> _pages = _channel.pdfInfo(widget.path);

  @override
  void dispose() {
    unawaited(_channel.pdfClose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    return FutureBuilder(
      future: _pages,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                l10n.viewArtifactPdfFailed,
                textAlign: TextAlign.center,
                style: TextStyle(color: dsh.textTertiary),
              ),
            ),
          );
        }
        final pages = snapshot.data;
        if (pages == null) return const _Spinner();
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - 24;
            final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round();
            return InteractiveViewer(
              maxScale: 4,
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(12, 4, 12, MediaQuery.paddingOf(context).bottom + 24),
                itemCount: pages.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (i == pages.length) {
                    return Center(
                      child: Text(
                        l10n.viewArtifactPages(pages.length),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    );
                  }
                  final page = pages[i];
                  return AspectRatio(
                    aspectRatio: page.width / (page.height == 0 ? 1 : page.height),
                    child: _PdfPage(channel: _channel, path: widget.path, index: i, pixels: pixels),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _PdfPage extends StatefulWidget {
  const _PdfPage({required this.channel, required this.path, required this.index, required this.pixels});

  final FilesChannel channel;
  final String path;
  final int index;
  final int pixels;

  @override
  State<_PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<_PdfPage> {
  late final Future<Uint8List> _png = widget.channel.pdfPage(widget.path, widget.index, widget.pixels);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: FutureBuilder<Uint8List>(
        future: _png,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return snapshot.hasError ? const Center(child: Icon(AppIcons.imageBroken)) : const SizedBox.expand();
          }
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: l10n.viewArtifactPage(widget.index + 1),
          );
        },
      ),
    );
  }
}
