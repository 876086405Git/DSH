import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'authoring_text.dart' show decodeAuthoringText;
import 'card_codec.dart' show isSafeCardAssetPath;

/// Internal payload owned by one admitted import. No live directory is opened.
final class DecodedGameplayPack {
  const DecodedGameplayPack({
    required this.manifestRaw,
    required this.manifest,
    required this.files,
    required this.originalZip,
    required this.digest,
  });

  final String manifestRaw;
  final Map<String, Object?> manifest;
  final Map<String, Uint8List> files;
  final Uint8List originalZip;
  final String digest;

  String get externalPackId => manifest['packId']! as String;
  String get packVersion => manifest['packVersion']! as String;
}

/// The same UTF-8/JSON decoding is used for a new manifest and saved raw text.
/// This does not normalize opaque identities or run resource validation.
({String rawText, Map<String, Object?> manifest}) decodeGameplayPackManifest(List<int> bytes) {
  final text = decodeAuthoringText(bytes);
  final value = jsonDecode(text.text);
  if (value is! Map<String, Object?>) {
    throw const FormatException('A gameplay pack manifest must be an object.');
  }
  return (rawText: text.rawText, manifest: value);
}

/// Reads declarations that already passed the import boundary.
Iterable<Map<String, Object?>> gameplayPackResources(Map<String, Object?> manifest) sync* {
  for (final item in manifest['resources'] as List<Object?>? ?? const <Object?>[]) {
    yield item as Map<String, Object?>;
  }
}

const _maxGameplayPackEntries = 4096;
const _maxGameplayPackBytes = 128 * 1024 * 1024;

/// Check central-directory metadata before ZipDecoder can read any content,
/// including its eager symlink decoding. archive 4.6 also limits each actual
/// decode to that entry's declared uncompressed size.
void _checkGameplayPackSize(Uint8List bytes) {
  var count = 0;
  var remaining = _maxGameplayPackBytes;
  for (final header in ZipDirectory().headers(InputMemoryStream(bytes), verify: true, files: false)) {
    if (++count > _maxGameplayPackEntries) {
      throw const FormatException('A gameplay pack cannot contain more than 4096 ZIP entries.');
    }
    if (((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
      throw const FormatException('A gameplay pack cannot contain symbolic links.');
    }
    final size = header.uncompressedSize;
    if (size < 0 || size > remaining) {
      throw const FormatException('A gameplay pack exceeds the 128 MiB uncompressed limit.');
    }
    remaining -= size;
  }
}

/// dshpack v1: root pack.json plus exact relative-path files.
/// castCard resources are complete CCv3 JSON envelopes; images or other
/// containers can be retained as asset/opaque resources, without card import.
DecodedGameplayPack decodeGameplayPack(Uint8List bytes) {
  _checkGameplayPackSize(bytes);
  final names = <String>{};
  final archive = ZipDecoder().decodeBytes(
    bytes,
    verify: true,
    callback: (ArchiveFile file) {
      var path = file.name;
      if (!file.isFile && path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
      if (!isSafeCardAssetPath(path)) {
        throw const FormatException('A gameplay pack file requires a safe relative path.');
      }
      if (file.isSymbolicLink || file.mode & 0xf000 == 0xa000) {
        throw const FormatException('A gameplay pack cannot contain symbolic links.');
      }
      if (!names.add(file.name)) {
        throw const FormatException('A gameplay pack cannot contain duplicate ZIP names.');
      }
    },
  );
  final files = <String, Uint8List>{};
  for (final file in archive.files) {
    if (!file.isFile) {
      continue;
    }
    final content = file.readBytes();
    if (content == null || content.length != file.size) {
      throw const FormatException('A gameplay pack file is incomplete.');
    }
    files[file.name] = content;
  }
  final manifestBytes = files['pack.json'];
  if (manifestBytes == null) {
    throw const FormatException('A gameplay pack requires root pack.json.');
  }
  final decoded = decodeGameplayPackManifest(manifestBytes);
  validateGameplayPackParts(decoded.manifest, files);
  return DecodedGameplayPack(
    manifestRaw: decoded.rawText,
    manifest: decoded.manifest,
    files: files,
    originalZip: bytes,
    digest: _contentDigest(manifestBytes, files),
  );
}

/// The existing manifest boundary shared by intake and a new export plan.
/// [files] contains the actual files available to resource declarations.
void validateGameplayPackParts(Map<String, Object?> manifest, Map<String, Uint8List> files) {
  if (manifest['formatVersion'] is! int || manifest['formatVersion'] != 1) {
    throw const FormatException('A gameplay pack requires formatVersion 1.');
  }
  for (final field in const ['packId', 'packVersion']) {
    final value = manifest[field];
    if (value is! String || value.isEmpty) {
      throw FormatException('A gameplay pack requires a nonempty $field.');
    }
  }
  for (final field in const ['schemaPatches', 'resources', 'references']) {
    if (manifest.containsKey(field) && manifest[field] is! List<Object?>) {
      throw FormatException('Gameplay pack $field must be an array.');
    }
  }
  final resourceIds = <String>{};
  for (final item in manifest['resources'] as List<Object?>? ?? const <Object?>[]) {
    if (item is! Map<String, Object?>) {
      throw const FormatException('A gameplay pack resource must be an object.');
    }
    final localId = item['localId'];
    if (localId is! String || localId.isEmpty || !resourceIds.add(localId)) {
      throw const FormatException('Gameplay pack resources require unique nonempty localId values.');
    }
    final kind = item['kind'];
    if (kind is! String || !const {'lorebook', 'regex', 'castCard', 'quickReplies', 'asset', 'opaque'}.contains(kind)) {
      throw const FormatException('A gameplay pack resource has an unsupported kind.');
    }
    final path = item['path'];
    if (path is! String || !isSafeCardAssetPath(path) || !files.containsKey(path)) {
      throw const FormatException('A gameplay pack resource must reference an existing relative file.');
    }
    if (!item.containsKey('entries')) {
      continue;
    }
    final entries = item['entries'];
    if (entries is! List<Object?> || (kind != 'lorebook' && kind != 'regex')) {
      throw const FormatException('Entry mappings are arrays for lorebook or regex resources.');
    }
    final ids = <String>{};
    final pointers = <String>{};
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('A gameplay pack entry mapping must be an object.');
      }
      final id = entry['localId'];
      final pointer = entry['pointer'];
      if (id is! String || id.isEmpty || !ids.add(id) || pointer is! String || !pointers.add(pointer)) {
        throw const FormatException('Entry mappings require unique nonempty localId values and unique pointers.');
      }
    }
  }
}

/// Encodes a new pack from already-owned manifest and selected file bytes.
/// Import/export never reads a path or fetches a URI while encoding.
Uint8List encodeGameplayPack(Map<String, Object?> manifest, Map<String, Uint8List> files, {required DateTime at}) {
  for (final path in files.keys) {
    if (!isSafeCardAssetPath(path) || path == 'pack.json' || path.startsWith('\uFEFF')) {
      throw const FormatException(
        'A new gameplay pack file requires an exact roundtrippable path other than pack.json.',
      );
    }
  }
  validateGameplayPackParts(manifest, files);
  final archive = Archive()..addFile(ArchiveFile.string('pack.json', jsonEncode(manifest)));
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    final bytes = files[path]!;
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive, modified: at));
}

String _contentDigest(Uint8List manifest, Map<String, Uint8List> files) {
  final framed = BytesBuilder(copy: false);
  void frame(List<int> value) {
    final length = ByteData(8)..setUint64(0, value.length, Endian.big);
    framed.add(length.buffer.asUint8List());
    framed.add(value);
  }

  frame(utf8.encode('dshpack-content-v1'));
  frame(manifest);
  final paths = files.keys.where((path) => path != 'pack.json').toList()..sort();
  for (final path in paths) {
    frame(utf8.encode(path));
    frame(files[path]!);
  }
  return sha256.convert(framed.takeBytes()).toString();
}
