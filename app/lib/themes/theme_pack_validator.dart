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

class ValidatedThemePack {
  const ValidatedThemePack({
    required this.json,
    required this.pack,
    required this.assets,
  });

  final Map<String, Object?> json;
  final ThemePack pack;
  final Map<String, Uint8List> assets;
}

class ThemePackValidator {
  ThemePackValidator._();

  static ValidatedThemePack validateArchive(
    Uint8List bytes, {
    bool market = false,
  }) {
    final PetArchive archive;
    try {
      archive = PetArchive.read(bytes);
    } on PetValidationException catch (error) {
      throw ThemeValidationException(error.code, error.path);
    }
    return validateThemeArchive(archive, market: market);
  }

  static ValidatedThemePack validateThemeArchive(
    PetArchive archive, {
    bool market = false,
  }) {
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
        pack.author != null &&
            pack.license != null &&
            workshopLicenses.contains(pack.license) &&
            pack.source != null,
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
      final size = pngSize(bytes);
      _need(size != null, 'theme-png-header', name);
      final (w, h) = size!;
      _need(
        w >= 1 &&
            h >= 1 &&
            w <= themeImageSideCap &&
            h <= themeImageSideCap &&
            w * h * 4 <= themeImageDecodedCap,
        'theme-png-dimensions',
        name,
      );
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
    return ValidatedThemePack(
      json: normalized,
      pack: pack,
      assets: Map.unmodifiable(kept),
    );
  }
}
