import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_app/pets/pet_name_alias.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_pack_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pet_library_test.dart' show packJson, png;

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/pets/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;
Map<String, Object?> animation(Map<String, Object?> pack) {
  // The older fixture's nested literal infers Map<String,Object>. Clone before
  // mutating so adding nullable-typed test data does not trip Dart covariance.
  final animations = Map<String, Object?>.from(pack['animations'] as Map);
  final result = Map<String, Object?>.from(animations['idle'] as Map);
  animations['idle'] = result;
  pack['animations'] = animations;
  return result;
}

Uint8List zipFiles(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Matcher denied([String? code]) =>
    throwsA(isA<PetValidationException>().having((e) => e.code, 'code', code ?? isNotEmpty));

Uint8List chunk(String type, List<int> payload) {
  final body = [...ascii.encode(type), ...payload];
  return Uint8List.fromList([
    ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
    ...body,
    ...(ByteData(4)..setUint32(0, getCrc32(body))).buffer.asUint8List(),
  ]);
}

Uint8List insertChunk(Uint8List original, String type, List<int> payload) =>
    Uint8List.fromList([...original.sublist(0, 33), ...chunk(type, payload), ...original.sublist(33)]);

Map<String, Object?> onePixelPack() {
  final pack = packJson(frames: 1);
  animation(pack).addAll({
    'frameW': 1,
    'frameH': 1,
    'cols': 1,
    'box': {'x': 0, 'y': 0, 'w': 1, 'h': 1},
  });
  return pack;
}

void main() {
  test('generated limits pin the exact common rules bytes', () {
    final raw = File('tool/pet-pack.rules.json').readAsBytesSync();
    expect(sha256.convert(raw).toString(), petPackRulesSha256);
    final limits = (jsonDecode(utf8.decode(raw)) as Map)['limits'] as Map;
    expect(
      [
        petJsonCap,
        petSheetByteCap,
        petSheetCountCap,
        petTotalSheetByteCap,
        petSheetSideCap,
        petSheetDecodedCap,
        petSheetNameCap,
        petArchiveByteCap,
        petArchiveExpandedCap,
        petArchiveEntryCap,
        petJsonDepthCap,
        petPngMetadataChunkCap,
        petPngMetadataTotalCap,
      ],
      [
        for (final key in [
          'packJsonBytes',
          'sheetBytes',
          'sheetCount',
          'totalSheetBytes',
          'sheetSide',
          'sheetDecodedBytes',
          'sheetNameCharacters',
          'archiveBytes',
          'archiveExpandedBytes',
          'archiveEntries',
          'jsonDepth',
          'pngMetadataChunkBytes',
          'pngMetadataTotalBytes',
        ])
          limits[key],
      ],
    );
  });

  for (final testCase in fixture('pet-pack-local-v1.json')['cases'] as List) {
    test('shared parser and App import: ${testCase['name']}', () {
      final json = (testCase['pack'] as Map).cast<String, Object?>();
      bool parseAccepted;
      try {
        PetPack.parse(json);
        parseAccepted = true;
      } on FormatException {
        parseAccepted = false;
      }
      expect(parseAccepted, testCase['parserValid']);
      // Shared parser fixtures use cat.png and fit a generous tiny atlas.
      if (testCase['appImportValid'] == true) {
        final result = PetPackValidator.validateParts(json, {'cat.png': png(16, 16)});
        final baseline = PetPack.parse(json);
        expect(result.pack.scale, baseline.scale);
        expect(result.pack.pixelArt, baseline.pixelArt);
        expect(result.pack.name, baseline.name);
        expect(result.pack.author, baseline.author);
        expect(result.pack.source, baseline.source);
        for (final entry in baseline.animations.entries) {
          final got = result.pack.animations[entry.key]!;
          expect(
            (got.frameWidth, got.frameHeight, got.cols),
            (entry.value.frameWidth, entry.value.frameHeight, entry.value.cols),
          );
          expect([for (final f in got.frames) (f.i, f.ms)], [for (final f in entry.value.frames) (f.i, f.ms)]);
        }
      } else {
        expect(
          () => PetPackValidator.validateParts(json, {'cat.png': png(16, 16)}),
          denied(parseAccepted ? 'pack-overlay' : 'pack-schema'),
        );
      }
      ValidatedPetPack checkMarket() =>
          PetPackValidator.validateParts(json, {'cat.png': png(16, 16)}, profile: PetValidationProfile.market);
      expect(checkMarket, testCase['marketValid'] == true ? returnsNormally : denied());
    });
  }

  for (final testCase in fixture('pet-validation-small.json')['json'] as List) {
    test('strict JSON: ${testCase['name']}', () {
      final bytes = Uint8List.fromList(utf8.encode(testCase['raw'] as String));
      if (testCase['ciAccepted'] == true) {
        expect(() => decodePetJson(bytes), returnsNormally);
      } else {
        expect(() => decodePetJson(bytes), denied());
      }
    });
  }

  test('JSON rejects malformed UTF8 and enforces the real raw byte cap', () {
    expect(() => decodePetJson(Uint8List.fromList([0x80])), denied('json-syntax'));
    expect(() => decodePetJson(Uint8List(petJsonCap + 1)), denied('pack-size'));
    expect(
      () => PetPackValidator.validateParts({...packJson(), 'extra': double.nan}, {'idle.png': png(32, 16)}),
      denied('json-number'),
    );
  });

  test('local metadata remains optional, with current overlay validation', () {
    final pack = packJson()
      ..remove('name')
      ..remove('author')
      ..remove('license');
    pack['source'] = '作者原创说明';
    final result = PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)});
    expect(
      (result.pack.name, result.pack.scale, result.pack.author, result.pack.license, result.pack.source),
      ('cat', 1, null, null, '作者原创说明'),
    );
    expect(
      () => PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)}, profile: PetValidationProfile.market),
      denied('metadata-author'),
    );
  });

  test('local import rejects parser rounding and dropped frames; market emits a valid normalized pack', () {
    final pack = packJson()..addAll({'author': 'A', 'license': 'CC0', 'source': 'art'});
    pack['scale'] = 'not numeric';
    final anim = animation(pack)
      ..['frameW'] = 15.5
      ..['frameH'] = 15.5
      ..['cols'] = 1.5;
    anim['frames'] = [
      {'i': -0.49999999999999994, 'ms': 0.5},
      {'i': 'skip', 'ms': 20},
    ];
    expect(() => PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)}), denied('pack-overlay'));
    expect(
      () => PetPackValidator.validateArchive(
        zipFiles({'pack.json': utf8.encode(jsonEncode(pack)), 'idle.png': png(32, 16)}),
      ),
      denied('pack-overlay'),
    );
    final normalized = PetPackValidator.validateParts(pack, {
      'idle.png': png(32, 16),
    }, profile: PetValidationProfile.market);
    expect(overlayPackProblem(normalized.json), isNull);
    expect(() => PetPackValidator.validateParts(normalized.json, normalized.sheets), returnsNormally);
    final a = normalized.pack.animations['idle']!;
    expect((a.frameWidth, a.frameHeight, a.cols, a.frames.single.i, a.frames.single.ms), (16, 16, 2, 0, 1));
  });

  test('market normalization downgrades reaction arrays to numbered string keys', () {
    final pack = packJson()..addAll({'source': 'original art'});
    final animations = Map<String, Object?>.from(pack['animations'] as Map);
    animations['look'] = {
      ...Map<String, Object?>.from(animations['idle'] as Map),
      'frames': [{'i': 1, 'ms': 200}],
    };
    pack['animations'] = animations;
    pack['reactions'] = {
      'tickle': ['look', 'idle'],
    };
    final checked = PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)}, profile: PetValidationProfile.market);
    // A shared pack must stay readable by older apps, which reject arrays.
    expect(checked.json['reactions'], {'tickle': 'look', 'tickle2': 'idle'});
    expect((checked.json['reactions']! as Map).values, everyElement(isA<String>()), reason: 'no array left in the normalized pack');
    final back = PetPackValidator.validateParts(checked.json, checked.sheets);
    expect(back.pack.reactions['tickle'], ['look', 'idle'], reason: 'the numbered keys merge back');
    expect(back.json['reactions'], {'tickle': 'look', 'tickle2': 'idle'}, reason: 'a plain schema-1 import keeps them');
  });

  test('market canonicalization and Float32 operands match Android', () {
    final pack = onePixelPack()..addAll({'author': 'A', 'license': 'CC0', 'source': 'original art', 'scale': 16777219});
    animation(pack).addAll({
      'frameW': 3,
      'frameH': 3,
      'box': {'x': 0, 'y': 0, 'w': 1.7881389169360773e-7, 'h': 1.7881389169360773e-7},
    });
    expect(
      () => PetPackValidator.validateParts(pack, {'idle.png': png(3, 3)}, profile: PetValidationProfile.market),
      denied('pack-overlay'),
    );
    pack['scale'] = 5;
    animation(pack)['box'] = {'x': 0, 'y': 0, 'w': 0.6, 'h': 0.6};
    final result = PetPackValidator.validateParts(pack, {'idle.png': png(3, 3)}, profile: PetValidationProfile.market);
    expect(result.json['scale'], 5);
    expect(result.json['pixelArt'], true);
    expect(animation(result.json)['frameW'], 3);
    // Rect.fromLTWH loses width under cancellation, but Android's PetBox
    // stores the authored w/h directly and the CI rule uses those same fields.
    final shifted = onePixelPack()..addAll({'author': 'A', 'license': 'CC0', 'source': 'art'});
    animation(shifted)['box'] = {'x': 1e100, 'y': 1e100, 'w': 1, 'h': 1};
    expect(
      () => PetPackValidator.validateParts(shifted, {'idle.png': png(1, 1)}, profile: PetValidationProfile.market),
      returnsNormally,
    );
  });

  test('frame cell multiplication cannot wrap around int64', () {
    final pack = packJson();
    animation(pack)['frameW'] = 9223372036854775807;
    expect(() => PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)}), denied('pack-overlay'));
    expect(
      () => PetPackValidator.validateParts(pack, {'idle.png': png(32, 16)}, profile: PetValidationProfile.market),
      denied('sheet-frame-bounds'),
    );
  });

  test('market metadata rejects Python whitespace U001C', () {
    final pack = onePixelPack()..addAll({'author': 'A', 'license': 'CC0', 'source': '\u001c'});
    expect(
      () => PetPackValidator.validateParts(pack, {'idle.png': png(1, 1)}, profile: PetValidationProfile.market),
      denied('metadata-source'),
    );
  });

  test('market metadata retains a nonempty UFEFF string exactly', () {
    final pack = onePixelPack()..addAll({'author': 'A', 'license': 'CC0', 'source': '\uFEFF'});
    final checked = PetPackValidator.validateParts(pack, {'idle.png': png(1, 1)}, profile: PetValidationProfile.market);
    expect(checked.json['source'], '\uFEFF');
  });

  test('ASCII aliases change only uppercase letters', () {
    final units = List.generate(128, (i) => i);
    final expected = String.fromCharCodes([for (final i in units) i >= 65 && i <= 90 ? i + 32 : i]);
    expect(petNameAlias(String.fromCharCodes(units)), expected);
  });

  test('UTF16 sheet length and Unicode15 NFC/full casefold aliases', () {
    expect(petNameAlias('Straße'), petNameAlias('STRASSE'));
    expect(petNameAlias('ς'), petNameAlias('σ'));
    expect(petNameAlias('e\u0301'), petNameAlias('é'));
    expect(petNameAlias('\u1100\u1161\u11a8'), petNameAlias('각'));
    final good = '${'😀' * 58}.png', bad = '${'😀' * 59}.png';
    expect(() => PetPackValidator.validateParts(packJson(sheet: good), {good: png(32, 16)}), returnsNormally);
    expect(() => PetPackValidator.validateParts(packJson(sheet: bad), {bad: png(32, 16)}), denied('sheet-name'));
    for (final pair in [('ß.png', 'ss.png'), ('ς.png', 'σ.png'), ('é.png', 'e\u0301.png')]) {
      expect(
        () => PetArchive.read(
          zipFiles({
            pair.$1: [0],
            pair.$2: [0],
          }),
        ),
        denied('archive-duplicate'),
      );
    }
  });

  test('C907 sheet names must fit the UTF8 filesystem component byte limit', () {
    final good = '${'界' * 83}xx.png', bad = '${'界' * 84}.png';
    expect(utf8.encode(good), hasLength(255));
    expect(utf8.encode(bad), hasLength(256));
    final pixels = png(32, 16);
    for (final profile in PetValidationProfile.values) {
      final allowed = packJson(sheet: good)..addAll({'author': 'A', 'license': 'CC0', 'source': 'fixture'});
      final rejected = packJson(sheet: bad)..addAll({'author': 'A', 'license': 'CC0', 'source': 'fixture'});
      expect(() => PetPackValidator.validateParts(allowed, {good: pixels}, profile: profile), returnsNormally);
      expect(() => PetPackValidator.validateParts(rejected, {bad: pixels}, profile: profile), denied('sheet-name'));
    }
  });

  test('C907 unreferenced stored members cannot overlap referenced local records', () {
    final bytes = zipFiles({
      'extra.bin': [1, 2, 3],
      'pack.json': utf8.encode(jsonEncode(packJson())),
      'idle.png': png(32, 16),
    });
    final data = ByteData.sublistView(bytes);
    final eocd = bytes.length - 22;
    expect(data.getUint32(eocd, Endian.little), 0x06054b50);
    final central = data.getUint32(eocd + 16, Endian.little);
    expect(data.getUint32(central, Endian.little), 0x02014b50);
    final local = data.getUint32(central + 42, Endian.little);
    final start = local + 30 + data.getUint16(local + 26, Endian.little) + data.getUint16(local + 28, Endian.little);
    // The first entry's payload now spans the two subsequent local records.
    // Neither pack.json nor its PNG references it, so no readFile of extra.bin occurs.
    final size = central - start;
    data.setUint16(central + 10, 0, Endian.little);
    data.setUint16(local + 8, 0, Endian.little);
    data.setUint32(central + 20, size, Endian.little);
    data.setUint32(central + 24, size, Endian.little);
    data.setUint32(local + 18, size, Endian.little);
    data.setUint32(local + 22, size, Endian.little);
    expect(() => PetArchive.read(bytes), denied('archive-member-range'));
    expect(() => PetPackValidator.validateArchive(bytes), denied('archive-member-range'));
  });

  test('C907 unreferenced file headers and directory payloads are range checked', () {
    final malformed = zipFiles({
      'extra.bin': [1],
      'pack.json': utf8.encode(jsonEncode(packJson())),
      'idle.png': png(32, 16),
    });
    final fileData = ByteData.sublistView(malformed);
    fileData.setUint16(28, 0xffff, Endian.little);
    expect(() => PetArchive.read(malformed), denied('archive-member-range'));

    final files = Archive()
      ..add(ArchiveFile.directory('extra/'))
      ..add(ArchiveFile.bytes('pack.json', utf8.encode(jsonEncode(packJson()))))
      ..add(ArchiveFile.bytes('idle.png', png(32, 16)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(files));
    expect(() => PetPackValidator.validateArchive(bytes), returnsNormally);
    final data = ByteData.sublistView(bytes);
    final central = data.getUint32(bytes.length - 22 + 16, Endian.little);
    final local = data.getUint32(central + 42, Endian.little);
    final start = local + 30 + data.getUint16(local + 26, Endian.little) + data.getUint16(local + 28, Endian.little);
    final size = central - start;
    data.setUint16(central + 10, 0, Endian.little);
    data.setUint16(local + 8, 0, Endian.little);
    data.setUint32(central + 20, size, Endian.little);
    data.setUint32(central + 24, size, Endian.little);
    data.setUint32(local + 18, size, Endian.little);
    data.setUint32(local + 22, size, Endian.little);
    expect(() => PetArchive.read(bytes), denied('archive-member-range'));
  });

  final archiveCases = {
    for (final item in fixture('pet-validation-small.json')['archive'] as List) item['name'] as String: item,
  };
  for (final name in ['complete', 'missing-bfinal', 'trailing-bytes', 'crc-mismatch', 'actual-inflate-budget']) {
    test('bounded actual ZIP member: $name', () {
      final archive = PetArchive.read(base64Decode(archiveCases[name]['zip'] as String));
      if (name == 'complete') {
        expect(utf8.decode(archive.readFile('a.txt', maxBytes: 3)), 'abc');
        expect(() => archive.readFile('a.txt', maxBytes: 2), denied('archive-member-size'));
      } else {
        expect(() => archive.readFile('a.txt', maxBytes: 3), denied());
      }
    });
  }
  test('duplicate and nonregular ZIP members fail before any inflate', () {
    expect(
      () => PetArchive.read(base64Decode(archiveCases['duplicate-last-wins']['zip'] as String)),
      denied('archive-duplicate'),
    );
    expect(
      () => PetArchive.read(base64Decode(archiveCases['bad-symlink-before-callback']['zip'] as String)),
      denied('archive-type'),
    );
  });
  test('ZIP names retain a leading BOM and use legacy CP437', () {
    final bom = PetArchive.read(base64Decode(archiveCases['utf8-bom-name']['zip'] as String));
    expect(bom.fileNames, {'\uFEFFpack.json'});
    expect(bom.manifestPaths('pack.json'), isEmpty);
    final legacy = PetArchive.read(base64Decode(archiveCases['cp437-name']['zip'] as String));
    expect(legacy.fileNames, {'é.txt'});
    expect(utf8.decode(legacy.readFile('é.txt', maxBytes: 3)), 'abc');
  });
  test('raw central directory count is limited, and candidate names are exact', () {
    expect(
      PetArchive.read(zipFiles({for (var n = 0; n < petArchiveEntryCap; n++) '$n.txt': []})).fileNames.length,
      petArchiveEntryCap,
    );
    expect(
      () => PetArchive.read(zipFiles({for (var n = 0; n <= petArchiveEntryCap; n++) '$n.txt': []})),
      denied('archive-entries'),
    );
    final names = PetArchive.read(zipFiles({'a/pack.json\n': [], 'a/b/pack.json': [], 'top/pack.json': []}));
    expect(names.manifestPaths('pack.json'), ['top/pack.json']);
  });
  test('archive validation drops extras and rejects ambiguous manifests', () {
    final bytes = png(32, 16);
    final archive = zipFiles({
      'top/pack.json': utf8.encode(jsonEncode(packJson())),
      'top/idle.png': bytes,
      'run.js': [1, 2],
    });
    final result = PetPackValidator.validateArchive(archive);
    expect(result.dropped, ['run.js']);
    expect(result.sheets['idle.png'], bytes);
    expect(
      () => PetPackValidator.validateArchive(
        zipFiles({
          'pack.json': [1],
          'a/pack.json': [1],
        }),
      ),
      denied('archive-pack-count'),
    );
  });

  for (final testCase in fixture('pet-validation-small.json')['png'] as List) {
    test('PNG real EOF: ${testCase['name']}', () {
      final bytes = base64Decode(testCase['png'] as String);
      if (testCase['valid'] == true) {
        expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': bytes}), returnsNormally);
      } else {
        expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': bytes}), denied());
      }
    });
  }
  for (final testCase in fixture('pet-png-v2.json')['cases'] as List) {
    test('shared PNG revision2: ${testCase['name']}', () {
      final bytes = base64Decode(testCase['base64'] as String);
      if (testCase['accepted'] == true) {
        expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': bytes}), returnsNormally);
      } else {
        expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': bytes}), denied());
      }
    });
  }
  test('PNG checks all CRCs, APNG and declared decoded size', () {
    final good = png(1, 1);
    final crc = Uint8List.fromList(good)..[29] ^= 1;
    expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': crc}), denied('png-crc'));
    final apng = insertChunk(good, 'acTL', [0, 0, 0, 1, 0, 0, 0, 0]);
    expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': apng}), denied('png-animated'));
    final hugeHeader = Uint8List.fromList(good);
    ByteData.sublistView(hugeHeader).setUint32(16, petSheetSideCap + 1);
    expect(
      () => PetPackValidator.validateParts(onePixelPack(), {'idle.png': hugeHeader}),
      denied('sheet-decoded-size'),
    );
  });
  test('compressed metadata is bounded before decoding and original PNG stays intact', () {
    final good = png(1, 1);
    for (final kind in ['iCCP', 'zTXt', 'iTXt']) {
      final prefix = kind == 'iTXt' ? [65, 0, 1, 0, 0, 0] : [65, 0, 0];
      final normal = insertChunk(good, kind, [
        ...prefix,
        ...ZLibCodec().encode([65, 66, 67]),
      ]);
      final checked = PetPackValidator.validateParts(onePixelPack(), {'idle.png': normal});
      expect(checked.sheets['idle.png'], normal);
      final oversized = insertChunk(good, kind, [
        ...prefix,
        ...ZLibCodec().encode(Uint8List(petPngMetadataChunkCap + 1)),
      ]);
      expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': oversized}), denied());
      final trailing = insertChunk(good, kind, [
        ...prefix,
        ...ZLibCodec().encode([65]),
        1,
      ]);
      expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': trailing}), denied());
    }
    // The per-chunk cap is specifically for compressed metadata.
    final text = insertChunk(good, 'tEXt', [65, 0, ...Uint8List(petPngMetadataChunkCap + 1)]);
    expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': text}), returnsNormally);
    var manyEmpty = good;
    for (var i = 0; i < 64; i++) {
      manyEmpty = insertChunk(manyEmpty, 'zTXt', [65, 0, 0, ...ZLibCodec().encode([])]);
    }
    expect(() => PetPackValidator.validateParts(onePixelPack(), {'idle.png': manyEmpty}), returnsNormally);
  });
}
