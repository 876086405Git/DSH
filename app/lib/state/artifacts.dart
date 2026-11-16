// Chat artifacts: a turn's deliverables as the official Web client reads them
// (`@deepseek-ai/dsh-client-ui-deliverables`: `present` declarations at the
// end of a finished turn), and fallback rules for turns without them.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../runtime/local_paths.dart';
import 'chat_state.dart';
import 'connection_state.dart';
import 'settings_state.dart';

/// What sort of file an artifact is (icon, label, preview, MIME type).
enum ArtifactKind {
  image,
  pdf,
  document,
  spreadsheet,
  slides,
  archive,
  audio,
  video,
  web,
  markdown,
  text,
  other;

  String get label => switch (this) {
    image => appL10n.stateArtifactImage,
    pdf => 'PDF',
    document => appL10n.stateArtifactDocument,
    spreadsheet => appL10n.stateArtifactSheet,
    slides => appL10n.stateArtifactSlides,
    archive => appL10n.stateArtifactArchive,
    audio => appL10n.stateArtifactAudio,
    video => appL10n.stateArtifactVideo,
    web => appL10n.stateArtifactWeb,
    markdown => 'Markdown',
    text => appL10n.stateArtifactText,
    other => appL10n.stateArtifactFile,
  };
}

final _kinds = <String, ArtifactKind>{
  for (final e in ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'tif', 'tiff', 'ico', 'svg'])
    e: ArtifactKind.image,
  'pdf': ArtifactKind.pdf,
  for (final e in ['doc', 'docx', 'odt', 'rtf', 'pages', 'wps', 'epub']) e: ArtifactKind.document,
  for (final e in ['xls', 'xlsx', 'ods', 'csv', 'tsv', 'numbers', 'et']) e: ArtifactKind.spreadsheet,
  for (final e in ['ppt', 'pptx', 'odp', 'key', 'dps']) e: ArtifactKind.slides,
  for (final e in ['zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'zst', 'apk']) e: ArtifactKind.archive,
  for (final e in ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'amr', 'mid', 'midi']) e: ArtifactKind.audio,
  for (final e in ['mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v', '3gp']) e: ArtifactKind.video,
  for (final e in ['html', 'htm', 'mhtml']) e: ArtifactKind.web,
  for (final e in ['md', 'markdown']) e: ArtifactKind.markdown,
  for (final e in ['txt', 'log']) e: ArtifactKind.text,
};

/// Calendar / contact files count as made-for-the-user too.
const _otherArtifacts = {'ics', 'vcf'};

const _mimes = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'odt': 'application/vnd.oasis.opendocument.text',
  'rtf': 'application/rtf',
  'epub': 'application/epub+zip',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ods': 'application/vnd.oasis.opendocument.spreadsheet',
  'csv': 'text/csv',
  'tsv': 'text/tab-separated-values',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odp': 'application/vnd.oasis.opendocument.presentation',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tgz': 'application/gzip',
  'tar': 'application/x-tar',
  'bz2': 'application/x-bzip2',
  'xz': 'application/x-xz',
  '7z': 'application/x-7z-compressed',
  'rar': 'application/vnd.rar',
  'apk': 'application/vnd.android.package-archive',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'amr': 'audio/amr',
  'mid': 'audio/midi',
  'midi': 'audio/midi',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'm4v': 'video/x-m4v',
  '3gp': 'video/3gpp',
  'html': 'text/html',
  'htm': 'text/html',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'txt': 'text/plain',
  'log': 'text/plain',
  'json': 'application/json',
  'xml': 'text/xml',
  'ics': 'text/calendar',
  'vcf': 'text/x-vcard',
};

String _extension(String path) {
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Last path segment (`/` or `\` separated).
String baseName(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

ArtifactKind artifactKindOf(String path) => _kinds[_extension(path)] ?? ArtifactKind.other;

/// MIME type from the extension; `application/octet-stream` when unknown.
String mimeTypeOf(String path) => _mimes[_extension(path)] ?? 'application/octet-stream';

/// Office formats the Host can convert to PDF for a preview
/// (`@deepseek-ai/dsh-office-to-pdf`).
bool isOfficePath(String path) => const {'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'}.contains(_extension(path));

/// Whether a file the agent merely wrote or linked counts as made for the
/// user: documents, images, sheets, slides, archives, media, web pages.
/// Code, configuration, Markdown and plain text do not (the change card
/// already shows code; a README is not a deliverable).
bool isArtifactPath(String path) {
  final ext = _extension(path);
  if (_otherArtifacts.contains(ext)) return true;
  return switch (_kinds[ext]) {
    null || ArtifactKind.markdown || ArtifactKind.text || ArtifactKind.other => false,
    _ => true,
  };
}

/// Where the phone's shared storage shows up in the local engine.
const phoneStorageGuestPath = '/sdcard';

/// The folder the local engine's instructions send output files to.
const phoneOutputDir = '$phoneStorageGuestPath/Download/DSH-Go';

/// How an artifact was found.
enum ArtifactOrigin {
  /// Declared with the `present` tool (the official deliverables).
  delivered,

  /// Created this turn by `write` / `str_replace_editor create`.
  written,

  /// Linked from the turn's final reply, and named by its tool calls.
  linked,

  /// Appeared in `/sdcard/Download/DSH-Go` (or the old `DSH`) while the turn ran (local engine).
  phoneOutput,
}

/// One file the agent made for the user.
class Artifact {
  const Artifact({
    required this.path,
    required this.origin,
    required this.turn,
    this.description,
    this.seq,
    this.bytes,
  });

  /// Absolute path in the Host's filesystem (as declared when it could not
  /// be resolved, e.g. a relative path without a known working directory).
  final String path;
  final ArtifactOrigin origin;
  final int turn;

  /// The model's description (deliverables only).
  final String? description;

  /// The event that named it (declaration, tool result), when there is one.
  final int? seq;

  /// Size, when known up front (phone outputs).
  final int? bytes;

  String get name => baseName(path);
  ArtifactKind get kind => artifactKindOf(path);
  String get mimeType => mimeTypeOf(path);
  bool get delivered => origin == ArtifactOrigin.delivered;

  /// Already in the phone's public Downloads (nothing to save).
  bool get inPhoneDownloads => path.startsWith('$phoneStorageGuestPath/Download/');

  /// `PDF`, `表格 · XLSX`: the kind, plus the extension when it adds something.
  String get typeLabel {
    final ext = _extension(path).toUpperCase();
    final label = kind.label;
    if (ext.isEmpty) return label;
    if (label == ext || kind == ArtifactKind.other) return ext;
    return '$label · $ext';
  }
}

/// The artifacts of one finished turn, shown after its content.
class TurnArtifacts {
  const TurnArtifacts({required this.turn, required this.endSeq, required this.files});

  final int turn;

  /// The turn's `turn/end` (places the card, keys the row).
  final int endSeq;

  /// Deliverables when the turn declared any (then nothing else), else the
  /// files the fallback rules found.
  final List<Artifact> files;

  bool get delivered => files.isNotEmpty && files.first.delivered;
}

/// A file in the phone's output folder (`listOutputs`).
class PhoneOutput {
  const PhoneOutput({required this.path, required this.modified, this.bytes});

  /// Guest path (`/sdcard/Download/DSH-Go/…`).
  final String path;
  final DateTime modified;
  final int? bytes;
}

/// Markdown link destinations: `](<path with spaces>)` or `](path "title")`.
final _linkTarget = RegExp(r'\]\(\s*(?:<([^>\n]+)>|([^)\s]+))');
final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:');
final _drive = RegExp(r'^[A-Za-z]:[\\/]');

/// A local Markdown destination, shared by artifact cards and inline links.
/// Decode the URI path once; query strings and fragments are not filenames.
String? resolveWorkspaceLink(String url, {String? baseDir}) {
  var target = url.trim();
  if (target.startsWith('<') && target.endsWith('>')) {
    target = target.substring(1, target.length - 1).trim();
  }
  if (target.isEmpty || target.startsWith('#') || target.startsWith('?') || target.startsWith('//')) return null;
  final uri = Uri.tryParse(target);
  if (uri == null) return null;
  if (uri.hasScheme) {
    if (uri.scheme.toLowerCase() != 'file' ||
        (uri.host.isNotEmpty && uri.host.toLowerCase() != 'localhost') ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
  } else if (uri.hasAuthority) {
    return null;
  }
  final String path;
  try {
    path = Uri.decodeComponent(uri.path);
  } on FormatException {
    return null;
  }
  // resolveSessionPath also accepts file:// input. Do not feed it a decoded
  // scheme and accidentally decode a literal percent escape a second time.
  if (path.isEmpty || _scheme.hasMatch(path)) return null;
  if (!path.startsWith('/') && baseDir != null && baseDir.isNotEmpty && !baseDir.startsWith('/')) {
    return '$baseDir/$path';
  }
  return resolveSessionPath(path, cwd: baseDir);
}

/// Local file paths a reply links to (`[a](<out/a.pdf>)`, `![b](chart.png)`),
/// in order, resolved against [cwd]; web links and anchors dropped.
List<String> linkedPaths(String text, {String? cwd}) {
  final out = <String>{};
  for (final match in _linkTarget.allMatches(text)) {
    var target = (match.group(1) ?? match.group(2) ?? '').trim();
    final String? path;
    if (_drive.hasMatch(target)) {
      // Preserve existing artifact support for remote Windows paths.
      final hash = target.indexOf('#');
      if (hash >= 0) target = target.substring(0, hash);
      if (match.group(1) == null) {
        try {
          target = Uri.decodeFull(target);
        } on ArgumentError {
          // Keep it as written.
        } on FormatException {
          continue;
        }
      }
      path = resolveSessionPath(target, cwd: cwd);
    } else {
      path = resolveWorkspaceLink(target, baseDir: cwd);
    }
    if (path != null) out.add(path);
  }
  return out.toList();
}

class _TurnScan {
  final calls = <String, ToolCallEvent>{};
  final results = <ToolResultEvent>[];
  final written = <(String, int)>[];
  String? reply;

  /// Whether a call's arguments or a successful result names [name]
  /// (checked only for the few files a reply links to).
  bool names(String name) =>
      calls.values.any((c) => c.arguments.contains(name)) || results.any((r) => r.message.text.contains(name));
}

/// Per finished turn: its deliverables, or else
/// - files it created with `write` / `str_replace_editor create`,
/// - files its final reply links to that its tool calls or results name
///   (the official prompt asks the model to link files it mentions),
/// - files that appeared in [phoneOutputDir] while it ran ([phoneOutputs]),
/// kept only when [isArtifactPath] (phone outputs: always). Turns still
/// running, or whose `turn/start` is not loaded, get nothing. Sorted by
/// `turn/end`.
List<TurnArtifacts> deriveArtifacts({
  required Iterable<SessionLogEvent> events,
  required List<TurnTrace> turns,
  String? cwd,
  List<PhoneOutput> phoneOutputs = const [],
}) {
  final finished = <int, TurnTrace>{
    for (final trace in turns)
      if (!trace.running && trace.endSeq != null) trace.turn: trace,
  };
  if (finished.isEmpty) return const [];
  final scans = <int, _TurnScan>{};
  for (final event in events) {
    switch (event) {
      case ToolCallEvent(:final turn, :final callId):
        if (!finished.containsKey(turn)) break;
        final scan = scans[turn] ??= _TurnScan();
        scan.calls[callId] = event;
      case ToolResultEvent(:final turn):
        if (!finished.containsKey(turn) || event.isError) break;
        final scan = scans[turn] ??= _TurnScan();
        scan.results.add(event);
        final call = scan.calls[event.callId];
        if (call == null) break;
        final created = _createdPath(call, event.meta, cwd);
        if (created != null) scan.written.add((created, event.seq));
      case AssistantMessageEvent(:final turn, :final message):
        if (!finished.containsKey(turn)) break;
        if (message.text.trim().isNotEmpty) {
          (scans[turn] ??= _TurnScan()).reply = message.text;
        }
      default:
        break;
    }
  }
  final delivered = presentedByTurn(events);
  final outputs = [...phoneOutputs]..sort((a, b) => a.modified.compareTo(b.modified));

  final out = <TurnArtifacts>[];
  for (final trace in finished.values) {
    final turn = trace.turn;
    final files = <String, Artifact>{};
    final declared = delivered[turn];
    if (declared != null) {
      for (final file in declared) {
        final path = resolveSessionPath(file.path, cwd: cwd);
        files[path] = Artifact(
          path: path,
          origin: ArtifactOrigin.delivered,
          turn: turn,
          description: file.description?.trim().isEmpty ?? true ? null : file.description!.trim(),
          seq: file.seq,
        );
      }
    } else {
      final scan = scans[turn];
      if (scan != null) {
        for (final (path, seq) in scan.written) {
          if (!isArtifactPath(path)) continue;
          files.putIfAbsent(path, () => Artifact(path: path, origin: ArtifactOrigin.written, turn: turn, seq: seq));
        }
        final reply = scan.reply;
        if (reply != null) {
          for (final path in linkedPaths(reply, cwd: cwd)) {
            if (!isArtifactPath(path) || !scan.names(baseName(path))) {
              continue;
            }
            files.putIfAbsent(path, () => Artifact(path: path, origin: ArtifactOrigin.linked, turn: turn));
          }
        }
      }
      final from = trace.start.subtract(const Duration(seconds: 1));
      final to = (trace.end ?? trace.start).add(const Duration(seconds: 2));
      for (final output in outputs) {
        if (output.modified.isBefore(from) || output.modified.isAfter(to)) {
          continue;
        }
        files.putIfAbsent(
          output.path,
          () => Artifact(path: output.path, origin: ArtifactOrigin.phoneOutput, turn: turn, bytes: output.bytes),
        );
      }
    }
    if (files.isEmpty) continue;
    out.add(TurnArtifacts(turn: turn, endSeq: trace.endSeq!, files: List.unmodifiable(files.values)));
  }
  out.sort((a, b) => a.endSeq.compareTo(b.endSeq));
  return List.unmodifiable(out);
}

/// The file a successful `write` / `str_replace_editor create` created
/// (null for edits, overwrites and other tools). The result's absolute
/// `meta.path` wins over the argument, as in the official client.
String? _createdPath(ToolCallEvent call, Object? meta, String? cwd) {
  // Runs for every tool call on each event: decide before decoding arguments.
  Map<String, Object?>? args;
  switch (call.name) {
    case 'write':
      if (meta is! Map || meta['operation'] != 'create') return null;
    case 'str_replace_editor':
      args = call.decodedArguments;
      if (args?['command'] != 'create') return null;
    default:
      return null;
  }
  final recorded = meta is Map ? meta['path'] : null;
  if (recorded is String && recorded.startsWith('/')) {
    return resolveSessionPath(recorded);
  }
  args ??= call.decodedArguments;
  final argument = args?['file_path'] ?? args?['path'];
  if (argument is! String || argument.trim().isEmpty) return null;
  return resolveSessionPath(argument, cwd: cwd);
}

// -----------------------------------------------------------------------------
// Providers

/// The native side of artifacts (`files/FilesPlugin.kt`).
class FilesChannel {
  const FilesChannel([this.channel = const MethodChannel('dsh/files')]);

  final MethodChannel channel;

  /// Android path of a local-engine file; null when it is not there.
  Future<String?> resolveGuest(String path) => channel.invokeMethod<String>('resolveGuest', {'path': path});

  /// Files under [phoneOutputDir] and the old `Download/DSH` (empty without phone
  /// storage access).
  Future<List<PhoneOutput>> listOutputs({int depth = 3}) async {
    final raw = await channel.invokeListMethod<Object?>('listOutputs', {'depth': depth}) ?? const [];
    return [
      for (final entry in raw)
        if (entry is Map && entry['path'] is String)
          PhoneOutput(
            path: entry['path'] as String,
            bytes: (entry['bytes'] as num?)?.toInt(),
            modified: DateTime.fromMillisecondsSinceEpoch((entry['modified'] as num?)?.toInt() ?? 0),
          ),
    ];
  }

  /// Opens an Android file with the app that handles [mime] ([chooser]: let
  /// the person pick one).
  Future<void> open(String hostPath, {required String name, required String mime, bool chooser = false}) =>
      channel.invokeMethod<void>('open', {'path': hostPath, 'name': name, 'mime': mime, 'chooser': chooser});

  /// Copies an Android file into the public Downloads (`Download/DSH-Go`);
  /// returns where it landed (`Download/DSH-Go/report.pdf`). On HarmonyOS the
  /// system's save window asks where: see [savedInChosenPlace] and
  /// [saveWindowDismissed].
  Future<String> saveToDownloads(String hostPath, {required String name, required String mime}) async =>
      await channel.invokeMethod<String>('saveToDownloads', {'path': hostPath, 'name': name, 'mime': mime}) ??
      'Download/DSH-Go/$name';

  /// Page sizes (PDF points) of a PDF on this phone.
  Future<List<({int width, int height})>> pdfInfo(String hostPath) async {
    final raw = await channel.invokeListMethod<Object?>('pdfInfo', {'path': hostPath}) ?? const [];
    return [
      for (final page in raw)
        if (page is Map) (width: (page['width'] as num?)?.toInt() ?? 1, height: (page['height'] as num?)?.toInt() ?? 1),
    ];
  }

  /// One PDF page as PNG, [width] pixels wide.
  Future<Uint8List> pdfPage(String hostPath, int page, int width) async =>
      await channel.invokeMethod<Uint8List>('pdfPage', {'path': hostPath, 'page': page, 'width': width}) ??
      Uint8List(0);

  /// Lets go of the open PDF.
  Future<void> pdfClose() => channel.invokeMethod<void>('pdfClose');
}

final filesChannelProvider = Provider<FilesChannel>((ref) => const FilesChannel());

/// Whether [where], from [FilesChannel.saveToDownloads], is the URI the system's
/// save window answered with (HarmonyOS): the person chose the place, and a
/// `file://…` means nothing to read, so a note only says it's saved.
bool savedInChosenPlace(String where) => where.contains('://');

/// Whether [error], from [FilesChannel.saveToDownloads], is the person backing
/// out of the system's save window (HarmonyOS): nothing saved and nothing wrong,
/// so nothing to say. Android has no such window and never answers this.
bool saveWindowDismissed(Object error) => error is PlatformException && error.code == 'cancelled';

/// The local engine's output folder ([phoneOutputDir]); empty unless the
/// engine is on this phone with "访问手机文件" on (on HarmonyOS the folder is in
/// the app's own files and needs no such access). Scanned when first needed and
/// again whenever a turn ends ([refresh]).
class PhoneOutputsController extends Notifier<List<PhoneOutput>> {
  bool _enabled = false;

  @override
  List<PhoneOutput> build() {
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? false));
    final storage = ref.watch(settingsProvider.select((s) => s.phoneStorage));
    _enabled = local && (storage || LocalPaths.noGuest);
    if (_enabled) unawaited(refresh());
    return const [];
  }

  Future<void> refresh() async {
    if (!_enabled) return;
    try {
      final files = await ref.read(filesChannelProvider).listOutputs();
      if (!ref.mounted || !_enabled) return;
      if (_same(files, state)) return;
      state = List.unmodifiable(files);
    } catch (_) {
      // No channel (tests) or no access: nothing to add.
    }
  }

  static bool _same(List<PhoneOutput> a, List<PhoneOutput> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path || a[i].modified != b[i].modified || a[i].bytes != b[i].bytes) {
        return false;
      }
    }
    return true;
  }
}

final phoneOutputsProvider = NotifierProvider<PhoneOutputsController, List<PhoneOutput>>(PhoneOutputsController.new);

/// Every finished turn's artifacts in one session ([deriveArtifacts]).
final sessionArtifactsProvider = Provider.autoDispose.family<List<TurnArtifacts>, String>((ref, sessionId) {
  final turns = ref.watch(chatProvider(sessionId).select((s) => s.turns));
  ref.listen(chatProvider(sessionId).select((s) => s.running), (was, running) {
    if (was == true && !running) {
      unawaited(ref.read(phoneOutputsProvider.notifier).refresh());
    }
  });
  final outputs = ref.watch(phoneOutputsProvider);
  final chat = ref.read(chatProvider(sessionId).notifier);
  return deriveArtifacts(events: chat.events, turns: turns, cwd: chat.header?.cwd, phoneOutputs: outputs);
});
