import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../pets/pet_name_alias.dart';
import '../pets/pet_pack.dart';
import '../pets/pet_pack_validator.dart';
import 'workshop_models.dart';

/// Explicit local input, with no path or credential in page state. The PNG
/// snapshot is private; later changes to the caller's byte array cannot alter it.
final class WorkshopPreviewInput {
  const WorkshopPreviewInput.petIdle()
      : source = 'pet-idle', _png = null, width = null, height = null;

  WorkshopPreviewInput._companion(this._png, this.width, this.height)
      : source = 'companion-preview';

  WorkshopPreviewInput._theme(this._png, this.width, this.height)
      : source = 'theme-preview';

  static (Uint8List, int, int) _validateCoverPng(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > workshopPreviewBytes) {
      workshopInvalid('workshop_preview_size');
    }
    final snapshot = Uint8List.fromList(bytes);
    final size = pngSize(snapshot);
    if (size == null) {
      workshopInvalid('workshop_preview_png');
    }
    final (width, height) = size;
    if (width < 1 || height < 1 || width > workshopPreviewSide || height > workshopPreviewSide ||
        width * height > workshopPreviewPixels) {
      workshopInvalid('workshop_preview_dimensions');
    }
    // The smaller image bounds above precede IDAT/metadata inflation.
    if (!pngIntact(snapshot)) {
      workshopInvalid('workshop_preview_png');
    }
    return (snapshot, width, height);
  }

  factory WorkshopPreviewInput.companionPng(Uint8List bytes) {
    final (snapshot, width, height) = _validateCoverPng(bytes);
    return WorkshopPreviewInput._companion(snapshot, width, height);
  }

  factory WorkshopPreviewInput.themePng(Uint8List bytes) {
    final (snapshot, width, height) = _validateCoverPng(bytes);
    return WorkshopPreviewInput._theme(snapshot, width, height);
  }

  final String source;
  final int? width, height;
  final Uint8List? _png;
  int? get size => _png?.length;
}

/// The export already passed its full pet gate. Here only the requested preview
/// domain is narrower: the main idle cell, not the sheet or authored canvas.
void workshopCheckPetPreview(Archive archive) {
  final member = archive.files.where((file) => file.isFile && file.name == 'pack.json').single;
  if (member.size > petJsonCap) {
    workshopInvalid('workshop_body_too_large');
  }
  final output = OutputMemoryStream();
  member.writeContent(output);
  final json = decodePetJson(output.getBytes());
  if (json is! Map<String, Object?>) {
    workshopInvalid('workshop_bad_metadata');
  }
  final pack = PetPack.parse(json);
  final idle = pack.animations[pack.states['idle']!.first]!;
  if (idle.frameWidth > workshopPreviewSide || idle.frameHeight > workshopPreviewSide ||
      idle.frameWidth * idle.frameHeight > workshopPreviewPixels) {
    workshopInvalid('workshop_preview_dimensions');
  }
}

/// Works only on the freshly exported model snapshot. It never reads a live
/// character directory or overwrites a model texture at the reserved path.
Uint8List workshopCompanionPreviewZip((Uint8List, WorkshopPreviewInput) input) {
  final (bytes, preview) = input;
  if (preview.source != 'companion-preview') {
    workshopInvalid('workshop_bad_metadata');
  }
  final png = preview._png!;
  final archive = ZipDecoder().decodeBytes(bytes);
  const name = 'character/preview.png';
  final alias = petNameAlias(name);
  var expanded = png.length;
  for (final member in archive.files) {
    final existing = petNameAlias(member.name);
    if (existing == alias || existing.startsWith('$alias/')) {
      workshopInvalid('workshop_preview_conflict');
    }
    expanded += member.size;
  }
  if (archive.files.length >= 1000 || expanded > workshopExpandedBytes) {
    workshopInvalid('workshop_body_too_large');
  }
  archive.add(ArchiveFile.bytes(name, png));
  final encoded = ZipEncoder().encode(archive);
  if (encoded.length > workshopArchiveBytes) {
    workshopInvalid('workshop_body_too_large');
  }
  return Uint8List.fromList(encoded);
}

Uint8List workshopThemePreviewZip((Uint8List, WorkshopPreviewInput) input) {
  final (bytes, preview) = input;
  if (preview.source != 'theme-preview') {
    workshopInvalid('workshop_bad_metadata');
  }
  final png = preview._png!;
  final archive = ZipDecoder().decodeBytes(bytes);
  const name = 'preview.png';
  final alias = petNameAlias(name);
  var expanded = png.length;
  for (final member in archive.files) {
    final existing = petNameAlias(member.name);
    if (existing == alias || existing.startsWith('$alias/')) {
      workshopInvalid('workshop_preview_conflict');
    }
    expanded += member.size;
  }
  if (archive.files.length >= 256 || expanded > workshopExpandedBytes) {
    workshopInvalid('workshop_body_too_large');
  }
  archive.add(ArchiveFile.bytes(name, png));
  final encoded = ZipEncoder().encode(archive);
  if (encoded.length > workshopArchiveBytes) {
    workshopInvalid('workshop_body_too_large');
  }
  return Uint8List.fromList(encoded);
}
