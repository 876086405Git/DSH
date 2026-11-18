import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart' show ImageAttachment;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/l10n.dart';
import 'attachment_files_ohos.dart';
import 'connection_state.dart';

/// Something picked in the composer and not sent yet.
///
/// Images DSH takes inline (png, jpeg, webp, gif) ride in the prompt itself;
/// anything else is staged first (`fileUploads/upload`, or a streamed binary
/// upload on hosts that support it) and referenced by its receipt. Which one
/// is decided from the bytes, not the file name.
class DraftAttachment {
  DraftAttachment({required this.name, required this.bytes, this.mediaType}) : id = _nextId++;

  factory DraftAttachment.sniff(String name, Uint8List bytes) =>
      DraftAttachment(name: name, bytes: bytes, mediaType: inlineImageType(bytes));

  static int _nextId = 0;

  /// Stable within the app run; keys the tray and the optimistic bubble.
  final int id;
  final String name;
  final Uint8List bytes;

  /// Set for inline images; null for files.
  final String? mediaType;

  bool get isImage => mediaType != null;
  int get size => bytes.length;
}

/// Valid file picks plus the first rejected item, so an unreadable or oversized
/// file does not discard the rest of a multi-selection.
class PickedAttachments {
  const PickedAttachments(this.attachments, {this.problem});

  final List<DraftAttachment> attachments;
  final String? problem;
}

/// DSH's inline image limit (`SessionProjections.imageLimits` default).
const maxImageBytes = 20 * 1024 * 1024;

/// Files stream to the engine (`/api/session/uploadFileBinary`), so the
/// transfer holds about one copy of the file; the picker still keeps the
/// staged bytes (about two while assembling), so one message also has
/// [maxMessageBytes]. On a host without that route the client falls back to
/// base64 and refuses what one RPC frame can't hold.
const maxFileBytes = 200 * 1024 * 1024;

/// At most this many attachments per message (DSH allows 20 images).
const maxAttachments = 9;

/// Bytes one message's attachments may hold. The picker and the tray keep
/// every file in memory until the message is sent, so the ceiling is the
/// phone's heap rather than the Host; the share path's Kotlin budget
/// (`MAX_TOTAL_BYTES`) matches this.
const maxMessageBytes = 400 * 1024 * 1024;

/// Media type when [bytes] is an image DSH accepts inline, else null.
String? inlineImageType(Uint8List bytes) {
  bool at(int offset, List<int> sig) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return null;
}

/// "1.2 MB", "860 KB", "12 B".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}

/// Why [a] can't be attached, or null when it can.
String? attachmentProblem(DraftAttachment a) {
  if (a.size == 0) return appL10n.stateAttachmentEmpty(a.name);
  if (a.isImage && a.size > maxImageBytes) {
    return appL10n.stateAttachmentImageLimit(a.name);
  }
  if (!a.isImage && a.size > maxFileBytes) {
    return appL10n.stateAttachmentFileLimit(a.name);
  }
  return null;
}

/// Bytes held by [attachments], counted against [maxMessageBytes].
int totalAttachmentBytes(Iterable<DraftAttachment> attachments) {
  var total = 0;
  for (final a in attachments) {
    total += a.size;
  }
  return total;
}

/// Why [a] can't join a message already holding [heldBytes], or null when it
/// fits. Checked in every path that grows the tray, so repeated picks cannot
/// pile past [maxMessageBytes] (or [limit], a smaller carrier such as the web
/// page's composer).
String? attachmentBudgetProblem(int heldBytes, DraftAttachment a, {int limit = maxMessageBytes}) =>
    heldBytes + a.size > limit ? appL10n.stateAttachmentTotalLimit : null;

/// The system pickers behind the composer's ＋ menu. Tests swap in a fake.
abstract class AttachmentPicker {
  Future<List<DraftAttachment>> pickImages({required int limit});
  Future<DraftAttachment?> takePhoto();

  /// [heldBytes] is what the tray already holds: the picker refuses to retain
  /// more once the message's byte budget is spent, before opening a file.
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0});

  /// A small text file (an SSH private key); null when cancelled.
  Future<String?> pickTextFile({int maxBytes = 64 * 1024});
}

class DeviceAttachmentPicker implements AttachmentPicker {
  const DeviceAttachmentPicker();

  // Phone photos are 12–50 MP; the model gains nothing past ~2.5k on the long
  // side and the upload shrinks tenfold. Re-encoding also turns HEIC into JPEG.
  static const _maxSide = 2560.0;
  static const _quality = 88;

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) async {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
      limit: limit,
      // No location/EXIF access needed: skips the media-location permission.
      requestFullMetadata: false,
    );
    return [for (final x in picked.take(limit)) DraftAttachment.sniff(x.name, await x.readAsBytes())];
  }

  @override
  Future<DraftAttachment?> takePhoto() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
      requestFullMetadata: false,
    );
    if (x == null) return null;
    return DraftAttachment.sniff(x.name, await x.readAsBytes());
  }

  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0}) async => _readAttachmentFiles(
    (await FilePicker.pickFiles()).map(_AttachmentFileInput.platform),
    limit: limit,
    heldBytes: heldBytes,
  );

  @override
  Future<String?> pickTextFile({int maxBytes = 64 * 1024}) async {
    final file = await FilePicker.pickFile();
    return file == null ? null : _readAttachmentText(_AttachmentFileInput.platform(file), maxBytes: maxBytes);
  }
}

// Both backends use the same bounded Dart reader. Android's FilePicker source
// and its metadata/stream behavior remain unchanged.
class _AttachmentFileInput {
  _AttachmentFileInput(this.name, this.lengthSync, this.readAsByteStream);
  _AttachmentFileInput.platform(PlatformFile file) : this(file.name, file.lengthSync, file.readAsByteStream);
  final String name;
  final int? Function() lengthSync;
  final Stream<Uint8List> Function() readAsByteStream;
}

Future<PickedAttachments> _readAttachmentFiles(
  Iterable<_AttachmentFileInput> picked, {
  required int limit,
  required int heldBytes,
}) async {
  final accepted = <DraftAttachment>[];
  // Bytes already in the tray plus what this pick has retained so far: the
  // budget covers the whole message, not one picker invocation.
  var usedBytes = heldBytes;
  String? problem;
  for (final file in picked) {
    if (accepted.length >= limit) {
      problem ??= appL10n.chatAttachmentLimit(maxAttachments);
      break;
    }
    // Metadata can reject an oversized file without opening it, but cannot
    // authorize a read: content providers may omit it or report a stale size.
    final length = file.lengthSync();
    if (length != null && length > maxFileBytes) {
      problem ??= appL10n.stateAttachmentFileLimit(file.name);
      continue;
    }
    if (length != null && usedBytes + length > maxMessageBytes) {
      problem ??= appL10n.stateAttachmentTotalLimit;
      continue;
    }
    final bytes = BytesBuilder(copy: false);
    final prefix = Uint8List(12);
    var prefixLength = 0;
    String? mediaType;
    var tooLarge = false;
    var overMessageBudget = false;
    try {
      await for (final chunk in file.readAsByteStream()) {
        // Signatures may span chunks. Inspect only the small prefix before
        // retaining a chunk, and use image limits even with a misleading name.
        final take = (prefix.length - prefixLength).clamp(0, chunk.length);
        prefix.setRange(prefixLength, prefixLength + take, chunk);
        prefixLength += take;
        mediaType = inlineImageType(Uint8List.sublistView(prefix, 0, prefixLength));
        final budget = mediaType == null ? maxFileBytes : maxImageBytes;
        if ((length != null && length > budget) || chunk.length > budget - bytes.length) {
          tooLarge = true;
          break; // Cancels the stream without retaining the excess chunk.
        }
        if (chunk.length > maxMessageBytes - usedBytes - bytes.length) {
          tooLarge = true;
          overMessageBudget = true;
          break;
        }
        bytes.add(chunk);
      }
    } on Exception {
      // Partial bytes are not an attachment and have not consumed usedBytes.
      problem ??= appL10n.stateShareReadFailed(file.name);
      continue;
    }
    if (tooLarge) {
      problem ??= overMessageBudget
          ? appL10n.stateAttachmentTotalLimit
          : (mediaType == null
                ? appL10n.stateAttachmentFileLimit(file.name)
                : appL10n.stateAttachmentImageLimit(file.name));
      continue;
    }
    final attachment = DraftAttachment(name: file.name, bytes: bytes.takeBytes(), mediaType: mediaType);
    final issue = attachmentProblem(attachment) ?? attachmentBudgetProblem(usedBytes, attachment);
    if (issue != null) {
      problem ??= issue;
    } else {
      accepted.add(attachment);
      usedBytes += attachment.size;
    }
  }
  return PickedAttachments(accepted, problem: problem);
}

Future<String> _readAttachmentText(_AttachmentFileInput f, {required int maxBytes}) async {
  // Picker metadata can be absent or stale. It is only an early rejection;
  // enforce the byte budget on the stream before retaining each chunk.
  final length = f.lengthSync();
  if (length != null && length > maxBytes) {
    throw FormatException(appL10n.statePrivateKeyTooLarge);
  }
  final bytes = BytesBuilder();
  await for (final chunk in f.readAsByteStream()) {
    if (chunk.length > maxBytes - bytes.length) {
      // Leaving await-for cancels the source instead of reading the tail.
      throw FormatException(appL10n.statePrivateKeyTooLarge);
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

/// OH uses public ArkTS document grants and owned local cache files. Photos
/// keep the existing image-picker path; no URI is converted into a Dart path.
class OhosAttachmentPicker extends DeviceAttachmentPicker {
  const OhosAttachmentPicker();
  static const _files = OhosAttachmentFiles();

  @override
  Future<PickedAttachments> pickFiles({int limit = maxAttachments, int heldBytes = 0}) async {
    if (limit <= 0) return PickedAttachments(const [], problem: appL10n.chatAttachmentLimit(maxAttachments));
    if (heldBytes >= maxMessageBytes) return PickedAttachments(const [], problem: appL10n.stateAttachmentTotalLimit);
    return _files.consume(
      limit: limit.clamp(1, maxAttachments),
      maxFileBytes: maxFileBytes,
      maxTotalBytes: (maxMessageBytes - heldBytes).clamp(0, maxMessageBytes),
      maxImageBytes: maxImageBytes,
      allowEmpty: false,
      use: (entries) async {
        final accepted = <DraftAttachment>[];
        String? problem;
        var used = heldBytes;
        for (final entry in entries) {
          if (accepted.length >= limit) {
            problem ??= appL10n.chatAttachmentLimit(maxAttachments);
            break;
          }
          if (entry.problem != null) {
            problem ??= _nativeAttachmentProblem(entry);
            continue;
          }
          final selected = await _readAttachmentFiles(
            [_AttachmentFileInput(entry.name, () => entry.size, entry.readAsByteStream)],
            limit: 1,
            heldBytes: used,
          );
          problem ??= selected.problem;
          accepted.addAll(selected.attachments);
          used += totalAttachmentBytes(selected.attachments);
        }
        return PickedAttachments(accepted, problem: problem);
      },
    );
  }

  @override
  Future<String?> pickTextFile({int maxBytes = 64 * 1024}) async => _files.consume(
    limit: 1,
    maxFileBytes: maxBytes.clamp(0, maxFileBytes),
    maxTotalBytes: maxBytes.clamp(0, maxFileBytes),
    maxImageBytes: 0,
    allowEmpty: true,
    use: (entries) async {
      if (entries.isEmpty) return null;
      final entry = entries.first;
      if (entry.problem == 'file_too_large' || entry.problem == 'total_too_large') {
        throw FormatException(appL10n.statePrivateKeyTooLarge);
      }
      if (entry.problem != null) {
        throw PlatformException(code: 'ohos_attachment_io', message: appL10n.chatOpenAttachmentFailed);
      }
      return _readAttachmentText(
        _AttachmentFileInput(entry.name, () => entry.size, entry.readAsByteStream),
        maxBytes: maxBytes,
      );
    },
  );
}

String _nativeAttachmentProblem(OhosAttachmentFile file) => switch (file.problem) {
  'file_too_large' => appL10n.stateAttachmentFileLimit(file.name),
  'image_too_large' => appL10n.stateAttachmentImageLimit(file.name),
  'total_too_large' => appL10n.stateAttachmentTotalLimit,
  'too_many' => appL10n.chatAttachmentLimit(maxAttachments),
  'empty' => appL10n.stateAttachmentEmpty(file.name),
  _ => appL10n.chatOpenAttachmentFailed,
};

AttachmentPicker createAttachmentPicker({String? operatingSystem}) =>
    (operatingSystem ?? (kIsWeb ? 'web' : Platform.operatingSystem)) == 'ohos'
    ? const OhosAttachmentPicker()
    : const DeviceAttachmentPicker();

final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => createAttachmentPicker());

/// Bytes of an image a session's log refers to (`session/attachment`), for
/// thumbnails of sent messages. Dropped once no bubble shows it.
final sessionImageProvider = FutureProvider.autoDispose.family<Uint8List, (String, ImageAttachment)>((ref, key) async {
  final (sessionId, attachment) = key;
  final client = ref.watch(activeConnectionProvider.select((c) => c.value?.client));
  if (client == null) throw StateError(appL10n.commonNotConnected);
  // Scrolling a bubble out and back shouldn't refetch; let it go a bit later.
  final link = ref.keepAlive();
  Timer? release;
  ref.onCancel(() => release = Timer(const Duration(seconds: 30), link.close));
  ref.onResume(() => release?.cancel());
  ref.onDispose(() => release?.cancel());
  return (await client.attachment(sessionId, attachment)).bytes;
});
