import 'dart:io';

import 'package:flutter/services.dart';

/// Metadata from an owned native cache batch, never a document-provider URI.
class OhosAttachmentFile {
  OhosAttachmentFile._(this.name, this.path, this.size, this.problem);
  final String name;
  final String? path;
  final int size;
  final String? problem;

  factory OhosAttachmentFile.parse(Object? value) {
    if (value is! Map) throw const FormatException('Invalid attachment selection');
    final name = value['name'], path = value['path'], size = value['size'], problem = value['problem'];
    if (name is! String ||
        size is! int ||
        size < 0 ||
        (problem != null && problem is! String) ||
        (problem == null && (path is! String || !path.startsWith('/'))) ||
        (problem != null && path != null)) {
      throw const FormatException('Invalid attachment selection');
    }
    return OhosAttachmentFile._(name, path as String?, size, problem as String?);
  }

  Stream<Uint8List> readAsByteStream() =>
      File(path!).openRead().map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
}

/// The private files live only through [consume]. The native side also owns
/// cleanup when an engine/Ability retires before it can deliver the batch.
class OhosAttachmentFiles {
  const OhosAttachmentFiles();
  static const channel = MethodChannel('dsh/attachment-files');
  static int _serial = 0;

  Future<T> consume<T>({
    required int limit,
    required int maxFileBytes,
    required int maxTotalBytes,
    required int maxImageBytes,
    required bool allowEmpty,
    required Future<T> Function(List<OhosAttachmentFile>) use,
  }) async {
    final owner = 'dart-${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
    try {
      final values = await channel.invokeListMethod<Object?>('pick', {
        'owner': owner,
        'limit': limit,
        'maxFileBytes': maxFileBytes,
        'maxTotalBytes': maxTotalBytes,
        'maxImageBytes': maxImageBytes,
        'allowEmpty': allowEmpty,
      });
      return await use((values ?? []).map(OhosAttachmentFile.parse).toList(growable: false));
    } finally {
      // Also runs for a malformed reply, stream failure, limit rejection and
      // cancellation. Only an owner token is accepted; Dart cannot delete an
      // arbitrary path through this channel.
      try {
        await channel.invokeMethod<void>('release', {'owner': owner});
      } catch (_) {
        // Native retains cleanup ownership. A cleanup error must not replace
        // either consumed data or the original selection/read failure.
      }
    }
  }
}
