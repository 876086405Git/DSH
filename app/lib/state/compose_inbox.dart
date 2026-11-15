// What waits for the new-chat composer from outside the chat screen — a
// share from another app, a file opened with the app, a launcher shortcut,
// the Quick Settings tile (routed by lib/ui/shell/system_entry_host.dart).
//
// The chat screen takes the head of the queue once its saved drafts are in
// ([readyComposeProvider]), switches to 新对话 and fills the composer with
// [mergeIntoDraft]. Nothing is sent: the person reads it and adds a question.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../links/share_intake.dart';
import 'attachments.dart';
import 'connection_state.dart';
import 'draft_store.dart';
import 'hosts_state.dart';

/// Longest shared text put in the composer as text; longer text goes in as a
/// `.txt` attachment (or is cut, where files can't be sent).
const maxComposerShareChars = 20000;

/// Name of the attachment a long shared text becomes.
String get sharedTextFileName => appL10n.fileSharedText;

/// One fill of the new-chat composer.
class ComposeRequest {
  const ComposeRequest({
    this.text = '',
    this.attachments = const [],
    this.problems = const [],
    this.voice = false,
    this.note,
  });

  /// 新对话 from the launcher or the tile: an empty composer, focused — or
  /// listening, with [voice].
  const ComposeRequest.newChat({this.voice = false})
    : text = '',
      attachments = const [],
      problems = const [],
      note = null;

  final String text;
  final List<DraftAttachment> attachments;

  /// What didn't come through, one short line each; the first is shown.
  final List<String> problems;

  /// One line shown above the composer once it is filled, when nothing went
  /// wrong (「问 AI」 on a host without the guide).
  final String? note;

  /// Start dictation instead of showing the keyboard.
  final bool voice;

  /// Reads a share's files (copied into the app cache by the native side)
  /// into attachments, then deletes the copies: the bytes live in the draft.
  ///
  /// [heldBytes] is what the target draft already holds and [maxBytes] is the
  /// budget of the composer it lands in (the web page takes far less than a
  /// chat message): both are checked before a file is read, so a share cannot
  /// buffer bytes that the merge below would refuse anyway.
  static Future<ComposeRequest> fromShare(
    IncomingShare share, {
    Future<Uint8List> Function(String path)? read,
    int heldBytes = 0,
    int maxBytes = maxMessageBytes,
  }) async {
    final load = read ?? (path) => File(path).readAsBytes();
    final attachments = <DraftAttachment>[];
    final problems = [for (final s in share.skipped) skippedText(s)];
    var used = heldBytes;
    for (final file in share.files) {
      // Metadata can refuse a file before it is read; content providers may
      // omit it, so the post-read check below still applies.
      final length = read == null ? _fileLength(file.path) : null;
      if (length != null && used + length > maxBytes) {
        problems.add(appL10n.stateAttachmentTotalLimit);
        if (read == null) _discard(file.path);
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await load(file.path);
      } catch (_) {
        problems.add(appL10n.stateShareReadFailed(file.name));
        continue;
      } finally {
        if (read == null) _discard(file.path);
      }
      final attachment = DraftAttachment.sniff(file.name, bytes);
      final problem =
          attachmentProblem(attachment) ?? attachmentBudgetProblem(used, attachment, limit: maxBytes);
      if (problem != null) {
        problems.add(problem);
      } else {
        attachments.add(attachment);
        used += attachment.size;
      }
    }
    return ComposeRequest(text: share.composedText, attachments: attachments, problems: problems);
  }

  /// Deletes a share's cached copies unread, when nothing will take them.
  static void discardShare(IncomingShare share) {
    for (final file in share.files) {
      _discard(file.path);
    }
  }

  /// A file opened with the app (not a share code), already in the cache.
  static Future<ComposeRequest> fromFile(
    String path, {
    Future<Uint8List> Function(String path)? read,
    int heldBytes = 0,
    int maxBytes = maxMessageBytes,
  }) async {
    final name = path.split('/').last;
    final length = read == null ? _fileLength(path) : null;
    if (length != null && heldBytes + length > maxBytes) {
      return ComposeRequest(problems: [appL10n.stateAttachmentTotalLimit]);
    }
    try {
      final bytes = await (read ?? (p) => File(p).readAsBytes())(path);
      final attachment = DraftAttachment.sniff(name, bytes);
      final problem =
          attachmentProblem(attachment) ?? attachmentBudgetProblem(heldBytes, attachment, limit: maxBytes);
      return problem == null ? ComposeRequest(attachments: [attachment]) : ComposeRequest(problems: [problem]);
    } catch (_) {
      return ComposeRequest(problems: [appL10n.stateShareReadFailed(name)]);
    }
  }

  static int? _fileLength(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return null;
    }
  }

  static void _discard(String path) {
    try {
      final file = File(path);
      final slot = file.parent;
      file.deleteSync();
      if (slot.listSync().isEmpty) slot.deleteSync();
    } catch (_) {
      // Pruned by the native side on the next share anyway.
    }
  }
}

/// One line for a shared item that didn't come through.
String skippedText(SkippedShare skipped) {
  final name = skipped.name;
  return switch (skipped.reason) {
    ShareSkipReason.tooMany => appL10n.stateShareAttachmentLimit(maxAttachments),
    ShareSkipReason.tooLarge =>
      name == null ? appL10n.stateShareFileTooLarge : appL10n.stateShareNamedFileTooLarge(name),
    ShareSkipReason.unreadable => name == null ? appL10n.stateShareFileUnreadable : appL10n.stateShareReadFailed(name),
  };
}

/// Fills for the new-chat composer, oldest first.
class ComposeInbox extends Notifier<List<ComposeRequest>> {
  @override
  List<ComposeRequest> build() => const [];

  void push(ComposeRequest request) => state = List.unmodifiable([...state, request]);

  /// The oldest fill, removed from the queue; null when there is none.
  ComposeRequest? take() {
    if (state.isEmpty) return null;
    final first = state.first;
    state = List.unmodifiable(state.skip(1));
    return first;
  }
}

final composeInboxProvider = NotifierProvider<ComposeInbox, List<ComposeRequest>>(ComposeInbox.new);

/// The next fill once the composer can take it: the saved drafts are in, so
/// their arrival can't overwrite what was put there.
final readyComposeProvider = Provider<ComposeRequest?>((ref) {
  final loaded = ref.watch(draftStoreProvider.select((s) => s.loaded));
  if (!loaded) return null;
  return ref.watch(composeInboxProvider).firstOrNull;
});

/// The active host can stage attachments or publish into its workspace.
/// Remote workspace uploads require a capability from the live connection.
bool canStageFiles(HostConnection? connection, HostRef host) =>
    connection?.client.supportsFileUpload ?? host.kind != HostKind.relay;

/// The composer after a fill.
class MergedDraft {
  const MergedDraft({required this.text, required this.attachments, this.problem});

  final String text;
  final List<DraftAttachment> attachments;

  /// The first thing that didn't come through, for a toast.
  final String? problem;
}

/// [request] added to what the new-chat composer already holds: the shared
/// text below the draft's, attachments after its own, up to the limits.
MergedDraft mergeIntoDraft({
  required String text,
  required List<DraftAttachment> attachments,
  required ComposeRequest request,
  required bool filesAllowed,
}) {
  final problems = [...request.problems];
  var incoming = request.attachments;
  if (!filesAllowed && incoming.any((a) => !a.isImage)) {
    incoming = [
      for (final a in incoming)
        if (a.isImage) a,
    ];
    problems.add(appL10n.stateShareImagesOnly);
  }

  // The tray keeps every attachment's bytes until send; do not let shares pile
  // one message past its byte budget.
  var held = totalAttachmentBytes(attachments);
  final budgeted = <DraftAttachment>[];
  for (final a in incoming) {
    final over = attachmentBudgetProblem(held, a);
    if (over != null) {
      problems.add(over);
      continue;
    }
    held += a.size;
    budgeted.add(a);
  }
  incoming = budgeted;

  var shared = request.text.trim();
  if (shared.length > maxComposerShareChars) {
    if (filesAllowed && attachments.length + incoming.length < maxAttachments) {
      final textFile = DraftAttachment.sniff(sharedTextFileName, Uint8List.fromList(utf8.encode(shared)));
      if (attachmentBudgetProblem(held, textFile) == null) {
        incoming = [textFile, ...incoming];
        held += textFile.size;
        shared = '';
      } else {
        shared = _cut(shared, maxComposerShareChars);
        problems.add(appL10n.stateShareTextTruncated(maxComposerShareChars));
      }
    } else {
      shared = _cut(shared, maxComposerShareChars);
      problems.add(appL10n.stateShareTextTruncated(maxComposerShareChars));
    }
  }

  final room = maxAttachments - attachments.length;
  final added = incoming.take(room < 0 ? 0 : room).toList();
  if (added.length < incoming.length) {
    problems.add(appL10n.stateShareAttachmentLimit(maxAttachments));
  }

  final kept = text.trimRight();
  final nextText = kept.isEmpty
      ? shared
      : shared.isEmpty
      ? text
      : '$kept\n\n$shared';
  return MergedDraft(
    text: nextText,
    attachments: added.isEmpty ? attachments : [...attachments, ...added],
    problem: problems.firstOrNull,
  );
}

/// The first [max] UTF-16 units of [text], never ending inside a surrogate
/// pair.
String _cut(String text, int max) {
  var end = max;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}
