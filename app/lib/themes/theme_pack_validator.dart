// Strict validation for theme pack archives (theme.json + optional PNGs/fonts).
// Shares the ZIP structure, Unicode alias, strict UTF-8 JSON and PNG integrity
// gates with pet_pack_validator.dart and the Workshop Worker.

import 'dart:convert';
import 'dart:typed_data';

import '../pets/pet_name_alias.dart';
import '../pets/pet_pack_validator.dart';
import '../workshop/workshop_models.dart' show workshopLicenses;
import 'theme_pack.dart';

const themeJsonCap = 128 * 1024;
const themeImageByteCap = 8 * 1024 * 1024;
const themeFontByteCap = 16 * 1024 * 1024;
const themeTotalAssetByteCap = 32 * 1024 * 1024;
const themeImageSideCap = 4096;
const themeImageDecodedCap = 16 * 1024 * 1024;

class ThemeValidationException implements Exception {
  const ThemeValidationException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => 'ThemeValidationException($code${detail == null ? '' : ': $detail'})';
}

void _need(bool condition, String code, [String? detail]) {
  if (!condition) throw ThemeValidationException(code, detail);
}

bool isValidThemeFontBytes(Uint8List bytes) {
  if (bytes.length < 12 || bytes.length > themeFontByteCap) return false;
  if (bytes[0] == 0x00 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00) {
    return true;
  }
  final tag = String.fromCharCodes(bytes.sublist(0, 4));
  return tag == 'OTTO' || tag == 'true';
}

bool _hasMagic(Uint8List bytes, String magic, [int offset = 0]) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

bool _withinImageCaps(int w, int h) =>
    w >= 1 && h >= 1 && w <= themeImageSideCap && h <= themeImageSideCap && w * h * 4 <= themeImageDecodedCap;

/// The canvas a WebP or GIF decodes to (width, height), read from its header and, for a GIF,
/// its first frame; null when that is cut short, a GIF has no frame, or a WebP is not one of
/// the three layouts.
(int, int)? themeImageCanvas(Uint8List bytes) {
  int le16(int at) => bytes[at] | (bytes[at + 1] << 8);
  int le24(int at) => le16(at) | (bytes[at + 2] << 16);
  if (_hasMagic(bytes, 'GIF8')) {
    // The decoder grows the logical screen to hold a first frame that reaches past it.
    if (bytes.length < 13) return null;
    var at = 13 + (bytes[10] & 0x80 == 0 ? 0 : 3 << ((bytes[10] & 7) + 1));
    while (at + 9 < bytes.length) {
      if (bytes[at] == 0x2C) {
        final right = le16(at + 1) + le16(at + 5), bottom = le16(at + 3) + le16(at + 7);
        return (right > le16(6) ? right : le16(6), bottom > le16(8) ? bottom : le16(8));
      }
      if (bytes[at] != 0x21) return null;
      // An extension: its label, then sub-blocks up to an empty one.
      at += 2;
      while (at < bytes.length && bytes[at] != 0) {
        at += bytes[at] + 1;
      }
      at++;
    }
    return null;
  }
  if (!_hasMagic(bytes, 'RIFF') || !_hasMagic(bytes, 'WEBP', 8) || bytes.length < 30) return null;
  if (_hasMagic(bytes, 'VP8X', 12)) return (le24(24) + 1, le24(27) + 1);
  if (_hasMagic(bytes, 'VP8 ', 12)) return (le16(26) & 0x3FFF, le16(28) & 0x3FFF);
  if (_hasMagic(bytes, 'VP8L', 12)) {
    final bits = le16(21) | (le16(23) << 16);
    return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
  }
  return null;
}

/// Whether [bytes] open with the signature of the format that [name]'s
/// extension claims, so a renamed file cannot pass as another image type.
bool themeImageHeaderMatches(String name, Uint8List bytes) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return _hasMagic(bytes, '\x89PNG\r\n\x1a\n');
  if (lower.endsWith('.webp')) return _hasMagic(bytes, 'RIFF') && _hasMagic(bytes, 'WEBP', 8);
  if (lower.endsWith('.gif')) return _hasMagic(bytes, 'GIF87a') || _hasMagic(bytes, 'GIF89a');
  return false;
}

class ValidatedThemePack {
  const ValidatedThemePack({required this.json, required this.pack, required this.assets});

  final Map<String, Object?> json;
  final ThemePack pack;
  final Map<String, Uint8List> assets;
}

class ThemePackValidator {
  ThemePackValidator._();

  static ValidatedThemePack validateArchive(Uint8List bytes, {bool market = false}) {
    final PetArchive archive;
    try {
      archive = PetArchive.read(bytes);
    } on PetValidationException catch (error) {
      throw ThemeValidationException(error.code, error.path);
    }
    return validateThemeArchive(archive, market: market);
  }

  static ValidatedThemePack validateThemeArchive(PetArchive archive, {bool market = false}) {
    final candidates = archive.manifestPaths('theme.json');
    _need(candidates.length == 1, 'archive-theme-count');
    final manifestPath = candidates.single;
    final prefix = manifestPath.substring(0, manifestPath.length - 'theme.json'.length);

    final Object? decoded;
    try {
      decoded = decodePetJson(archive.readFile(manifestPath, maxBytes: themeJsonCap));
    } on PetValidationException catch (error) {
      throw ThemeValidationException(error.code, error.path);
    }
    _need(decoded is Map<String, Object?>, 'theme-json-object');
    final raw = decoded as Map<String, Object?>;

    final ThemePack pack;
    try {
      pack = ThemePack.parse(raw);
    } on FormatException catch (error) {
      throw ThemeValidationException('theme-schema', error.message);
    }

    final referenced = <String>{...pack.referencedImages, ...pack.referencedFonts};
    final aliases = <String>{};
    for (final asset in referenced) {
      final alias = petNameAlias(asset);
      _need(aliases.add(alias), 'theme-asset-alias', asset);
    }

    final assets = <String, Uint8List>{};
    var total = 0;
    for (final name in referenced) {
      final fullPath = '$prefix$name';
      _need(archive.fileNames.contains(fullPath), 'theme-asset-missing', name);
      final isImage = pack.referencedImages.contains(name);
      final cap = isImage ? themeImageByteCap : themeFontByteCap;
      final remaining = themeTotalAssetByteCap - total;
      final Uint8List data;
      try {
        data = archive.readFile(fullPath, maxBytes: cap < remaining ? cap : remaining);
      } on PetValidationException catch (error) {
        throw ThemeValidationException(
          error.code == 'archive-member-size' ? 'theme-asset-too-large' : error.code,
          name,
        );
      }
      total += data.length;
      assets[name] = data;
    }

    return validateParts(raw, assets, market: market);
  }

  static ValidatedThemePack validateParts(
    Map<String, Object?> raw,
    Map<String, Uint8List> assets, {
    bool market = false,
  }) {
    final ThemePack pack;
    try {
      pack = ThemePack.parse(raw);
    } on FormatException catch (error) {
      throw ThemeValidationException('theme-schema', error.message);
    }

    if (market) {
      _need(
        pack.author != null && pack.license != null && workshopLicenses.contains(pack.license) && pack.source != null,
        'theme-metadata',
      );
    }

    final referencedImages = pack.referencedImages;
    final referencedFonts = pack.referencedFonts;
    final allReferenced = <String>{...referencedImages, ...referencedFonts};
    final aliases = <String>{};
    for (final name in allReferenced) {
      _need(aliases.add(petNameAlias(name)), 'theme-asset-alias', name);
    }

    final kept = <String, Uint8List>{};
    var total = 0;
    for (final name in referencedImages) {
      final bytes = assets[name];
      _need(bytes != null, 'theme-asset-missing', name);
      _need(bytes!.isNotEmpty && bytes.length <= themeImageByteCap, 'theme-asset-too-large', name);
      total += bytes.length;
      _need(total <= themeTotalAssetByteCap, 'theme-asset-total-size');
      // WebP and GIF are left to the engine's decoder; only PNG is read in full. Their canvas is
      // still held to the PNG limits: a small file can declare one that takes hundreds of MB to decode.
      if (!name.toLowerCase().endsWith('.png')) {
        _need(themeImageHeaderMatches(name, bytes), 'theme-image-header', name);
        final canvas = themeImageCanvas(bytes);
        _need(canvas != null && _withinImageCaps(canvas.$1, canvas.$2), 'theme-image-dimensions', name);
        kept[name] = bytes;
        continue;
      }
      final size = pngSize(bytes);
      _need(size != null, 'theme-png-header', name);
      final (w, h) = size!;
      _need(_withinImageCaps(w, h), 'theme-png-dimensions', name);
      _need(pngIntact(bytes), 'theme-png-corrupt', name);
      kept[name] = bytes;
    }

    for (final name in referencedFonts) {
      final bytes = assets[name];
      _need(bytes != null, 'theme-asset-missing', name);
      _need(bytes!.isNotEmpty && bytes.length <= themeFontByteCap, 'theme-asset-too-large', name);
      total += bytes.length;
      _need(total <= themeTotalAssetByteCap, 'theme-asset-total-size');
      _need(isValidThemeFontBytes(bytes), 'theme-font-invalid', name);
      kept[name] = bytes;
    }

    final normalized = pack.toJson();
    _need(utf8.encode(jsonEncode(normalized)).length <= themeJsonCap, 'theme-size');
    return ValidatedThemePack(json: normalized, pack: pack, assets: Map.unmodifiable(kept));
  }
}
