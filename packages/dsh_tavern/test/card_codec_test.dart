import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/io/card_codec.dart';
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

void main() {
  const codec = CardCodec();
  final exportedAt = DateTime.utc(2026, 11, 10, 1, 2, 3);

  test('V1 upgrades fields without losing the legacy object', () {
    final source = _fixture('card-v1.json');
    final legacy = _json(source);
    final card = codec.decode(source);
    expect(card.json['spec'], 'chara_card_v3');
    expect(card.json['spec_version'], '3.0');
    expect(card.data['name'], legacy['name']);
    expect(card.data['creator_notes'], legacy['creatorcomment']);
    expect(card.data['group_only_greetings'], isEmpty);
    expect(card.data['creation_date'], 0);
    expect(card.json['unknown_v1'], legacy['unknown_v1']);
    expect(card.data['unknown_v1'], legacy['unknown_v1']);
    expect((card.data['extensions'] as Map<String, Object?>)['talkativeness'], 0);
    expect(card.originalBytes, orderedEquals(source));
  });

  test('V2 upgrade retains every extension and unknown root field', () {
    final bytes = _fixture('card-v2.json');
    final before = _json(bytes);
    final card = codec.decode(bytes);
    expect(card.json['unknown_root'], before['unknown_root']);
    expect(card.data['extensions'], (before['data'] as Map<String, Object?>)['extensions']);
    final book = card.data['character_book'] as Map<String, Object?>;
    final entry = (book['entries'] as List<Object?>).single as Map<String, Object?>;
    expect(entry['use_regex'], false);
    final summary = card.toCharacter('one');
    expect(summary.regexCount, 1);
    expect(summary.scriptCount, 1);
    expect(summary.greetings, ['第一句', '第二句']);
    expect(summary.hasLorebook, true);
  });

  test('future V3 version and unknown nested fields survive JSON export', () {
    final input = _json(_fixture('card-v3.json'))..['spec_version'] = '3.7';
    final card = codec.decode(_bytes(input));
    final encoded = codec.encode(card, format: TavernCardFormat.json, modifiedAt: exportedAt);
    final output = _json(encoded);
    final outputData = output['data'] as Map<String, Object?>;
    final originalData = input['data'] as Map<String, Object?>;
    expect(output['spec_version'], '3.7');
    expect(output['unknown_root'], input['unknown_root']);
    expect(outputData['extensions'], originalData['extensions']);
    expect(outputData['source'], originalData['source']);
    expect(outputData['creation_date'], 1234567890);
    expect(outputData['modification_date'], exportedAt.millisecondsSinceEpoch ~/ 1000);
    expect(card.data['modification_date'], 0, reason: 'Export must not mutate the stored object');
  });

  test('nickname and language projection do not overwrite raw card fields', () {
    final card = codec.decode(_fixture('card-v3.json'));
    expect(card.promptName, '小知');
    expect(card.toCharacter('one', language: 'zh-CN').creatorNotes, '中文说明');
    expect(card.toCharacter('one', language: 'ja').creatorNotes, 'English fallback');
    expect(card.toCharacter('one', language: 'en-US').creatorNotes, 'English note');
    expect(card.data['creator_notes'], 'English fallback');
    card.data['nickname'] = '';
    expect(card.promptName, '知更');
  });

  test('JSON accepts BOM, CRLF, CJK and emoji', () {
    final bytes = _fixture('card-v1.json');
    final text = '\ufeff${utf8.decode(bytes).replaceAll('\n', '\r\n')}';
    final card = codec.decode(Uint8List.fromList(utf8.encode(text)));
    expect(card.name, '灯塔守望者 🐳');
    expect(card.data['description'], contains('🌊'));
  });

  test('worldbooks are classified independently from bad cards', () {
    for (final input in [
      {'entries': <String, Object?>{}},
      {'name': '独立世界书', 'entries': <Object?>[]},
      {'spec': 'lorebook_v3', 'data': <String, Object?>{}},
    ]) {
      expect(
        () => codec.decode(_bytes(input)),
        throwsA(isA<TavernImportError>().having((error) => error.isLorebook, 'isLorebook', true)),
      );
    }
    final card = codec.decode(
      _bytes({
        'name': '卡',
        'first_mes': '问候',
        'entries': {'unknown': 1},
      }),
    );
    expect(card.json['entries'], {'unknown': 1}, reason: 'An unknown V1 field is not a worldbook');
  });

  test('non-card JSON and unsupported explicit spec fail', () {
    for (final input in [
      <String, Object?>{},
      {
        'spec': 'something_else',
        'data': {'name': 'x'},
      },
      {'spec': 'chara_card_v2', 'data': 'bad'},
    ]) {
      expect(() => codec.decode(_bytes(input)), throwsA(isA<TavernImportError>()));
    }
    expect(() => codec.decode(Uint8List.fromList(utf8.encode('[]'))), throwsA(isA<TavernImportError>()));
  });

  test('PNG ccv3 wins even when chara appears first and casing differs', () {
    final card = codec.decode(_fixture('card-both.png'));
    expect(card.name, '知更');
    expect(card.sourceFormat, TavernCardFormat.png);
    expect(card.png, orderedEquals(_fixture('card-both.png')));
  });

  test('PNG chara-only input upgrades V2', () {
    final source = _fixture('card-both.png');
    final card = codec.decode(_removeText(source, 'ccv3'));
    expect(card.name, '不应选中的旧名字');
    expect(card.json['spec'], 'chara_card_v3');
  });

  test('a broken preferred ccv3 does not silently fall back to stale chara', () {
    final without = _removeText(_fixture('card-both.png'), 'ccv3');
    final corrupt = _insertText(without, 'ccv3', base64Encode(utf8.encode('{broken')));
    expect(() => codec.decode(corrupt), throwsA(isA<TavernImportError>()));
  });

  test('PNG export writes one V3 and one V2 block and keeps image chunks', () {
    final original = _fixture('card-both.png');
    final card = codec.decode(original);
    final exported = codec.encode(card, modifiedAt: exportedAt);
    final chunks = _chunks(exported);
    final metadata = _textChunks(exported);
    expect(metadata.where((part) => part.$1 == 'ccv3'), hasLength(1));
    expect(metadata.where((part) => part.$1 == 'chara'), hasLength(1));
    expect(metadata.where((part) => part.$1 == 'Comment').single.$2, 'Self-authored fixture');
    expect(
      chunks.where((chunk) => chunk.$1 == 'IDAT').map((chunk) => chunk.$2),
      _chunks(original).where((chunk) => chunk.$1 == 'IDAT').map((chunk) => chunk.$2),
    );
    final v3 = _json(base64Decode(metadata.singleWhere((part) => part.$1 == 'ccv3').$2));
    final v2 = _json(base64Decode(metadata.singleWhere((part) => part.$1 == 'chara').$2));
    expect(v3['spec'], 'chara_card_v3');
    expect(v2['spec'], 'chara_card_v2');
    expect(v2['unknown_root'], v3['unknown_root']);
    final v2Data = v2['data'] as Map<String, Object?>;
    final v2Book = v2Data['character_book'] as Map<String, Object?>;
    final v2Entry = (v2Book['entries'] as List<Object?>).single as Map<String, Object?>;
    expect(v2Entry['content'], '世界书正文\n第二行');
    expect(v2Entry.containsKey('use_regex'), false);
    expect((v3['data'] as Map<String, Object?>)['character_book'], card.data['character_book']);
    expect(codec.decode(exported).name, '知更');
  });

  test('truncated PNG or corrupt chunk CRC fails rather than returning a partial card', () {
    final bytes = _fixture('card-both.png');
    expect(() => codec.decode(Uint8List.sublistView(bytes, 0, bytes.length - 2)), throwsA(isA<TavernImportError>()));
    final corrupted = Uint8List.fromList(bytes)..[20] ^= 1;
    expect(() => codec.decode(corrupted), throwsA(isA<TavernImportError>()));
  });

  test('legacy PNG asset chunks decode, then export as data URIs without writing legacy chunks', () {
    final json = _json(_fixture('card-v3.json'));
    (json['data'] as Map<String, Object?>)['assets'] = [
      {'type': 'x_custom', 'uri': '__asset:assets/unknown.bin', 'name': 'opaque', 'ext': 'bin'},
    ];
    var png = _removeText(_removeText(_fixture('card-both.png'), 'ccv3'), 'chara');
    png = _insertText(png, 'ccv3', base64Encode(_bytes(json)));
    png = _insertText(png, 'chara-ext-asset_:assets/unknown.bin', base64Encode([0, 1, 127, 255]));
    final card = codec.decode(png);
    expect(card.assets['assets/unknown.bin'], [0, 1, 127, 255]);
    final output = codec.encode(card, modifiedAt: exportedAt);
    expect(_textChunks(output).any((part) => part.$1.startsWith('chara-ext-asset_:')), false);
    final reread = codec.decode(output);
    final asset = (reread.data['assets'] as List<Object?>).single as Map<String, Object?>;
    expect(reread.assetBytes(asset['uri'] as String), [0, 1, 127, 255]);
  });

  test('CHARX retains unknown root files, binary bytes, paths and extension fields', () {
    final original = codec.decode(_fixture('card-assets.charx'));
    final output = codec.encode(original, format: TavernCardFormat.charx, modifiedAt: exportedAt);
    final reloaded = codec.decode(output);
    expect(reloaded.assets.keys.toSet(), original.assets.keys.toSet());
    for (final path in original.assets.keys) {
      expect(reloaded.assets[path], orderedEquals(original.assets[path]!), reason: path);
    }
    expect(reloaded.data['assets'], original.data['assets']);
    expect(reloaded.data['extensions'], original.data['extensions']);
    expect(reloaded.json['unknown_root'], original.json['unknown_root']);
    expect(reloaded.assetBytes('embeded://state.json'), original.assets['state.json']);
    expect(reloaded.assetBytes('https://example.invalid/avatar.png'), isNull);
  });

  test('CHARX rejects truncated archives and missing root card.json', () {
    final bytes = _fixture('card-assets.charx');
    expect(() => codec.decode(Uint8List.sublistView(bytes, 0, bytes.length - 12)), throwsA(isA<TavernImportError>()));
    final archive = Archive()..addFile(ArchiveFile.string('nested/card.json', '{}'));
    expect(() => codec.decode(Uint8List.fromList(ZipEncoder().encode(archive))), throwsA(isA<TavernImportError>()));
  });

  test('CHARX rejects duplicate names instead of silently discarding one', () {
    expect(() => codec.decode(_fixture('card-duplicate.charx')), throwsA(isA<TavernImportError>()));
  });

  test('CHARX refuses extraction paths outside the card and symbolic links', () {
    for (final name in ['../outside', '/absolute', 'C:/absolute', 'assets/./file']) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('card.json', utf8.decode(_fixture('card-v3.json'))))
        ..addFile(ArchiveFile.string(name, 'x'));
      expect(() => codec.decode(Uint8List.fromList(ZipEncoder().encode(archive))), throwsA(isA<TavernImportError>()));
    }
    final archive = Archive()
      ..addFile(ArchiveFile.string('card.json', utf8.decode(_fixture('card-v3.json'))))
      ..addFile(ArchiveFile.symlink('assets/link', '../somewhere'));
    expect(() => codec.decode(Uint8List.fromList(ZipEncoder().encode(archive))), throwsA(isA<TavernImportError>()));
  });

  test('CHARX rejects a raw backslash path without rejecting normal nested resources', () {
    // ZipEncoder normalizes backslashes. This self-authored ZIP instead keeps
    // the actual 0x5c byte in both its local and central-directory filename.
    final bytes = _fixture('card-backslash-path.charx');
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    expect(archive.files.map((file) => file.name), ['card.json', r'assets\file']);
    expect(() => codec.decode(bytes), throwsA(isA<TavernImportError>()));

    final valid = Archive()
      ..addFile(ArchiveFile.string('card.json', utf8.decode(_fixture('card-v3.json'))))
      ..addFile(ArchiveFile.string('assets/file', 'x'));
    final card = codec.decode(Uint8List.fromList(ZipEncoder().encode(valid)));
    expect(card.assets['assets/file'], utf8.encode('x'));
  });

  test('PNG to JSON carries the implicit portrait as a data URI', () {
    final card = codec.decode(_fixture('card-both.png'));
    final output = codec.decode(codec.encode(card, format: TavernCardFormat.json, modifiedAt: exportedAt));
    final icon = (output.data['assets'] as List<Object?>).single as Map<String, Object?>;
    expect(icon['uri'], startsWith('data:image/png;base64,'));
    expect(output.iconBytes, orderedEquals(card.png!));
  });

  test('PNG to CHARX carries default portrait and does not overwrite an existing resource', () {
    final decoded = codec.decode(_fixture('card-both.png'));
    final card = TavernCard(
      json: decoded.json,
      png: decoded.png,
      assets: {
        'assets/icon/images/main.png': Uint8List.fromList([7, 8, 9]),
      },
    );
    final output = codec.decode(codec.encode(card, format: TavernCardFormat.charx, modifiedAt: exportedAt));
    expect(output.assets['assets/icon/images/main.png'], [7, 8, 9]);
    expect(output.iconBytes, orderedEquals(decoded.png!));
  });

  test('replacing a PNG cover preserves other default portrait resource bytes', () {
    final decoded = codec.decode(_fixture('card-both.png'));
    decoded.data['assets'] = [
      {'type': 'icon', 'name': 'main', 'ext': 'png', 'uri': 'ccdefault:'},
      {'type': 'icon', 'name': 'archive', 'ext': 'png', 'uri': 'ccdefault:'},
    ];
    final originalJson = jsonEncode(decoded.json);
    final avatar = Uint8List.fromList(image.encodePng(image.Image(width: 3, height: 1)));
    final card = TavernCard(json: decoded.json, png: decoded.png, avatar: avatar);
    final bytes = codec.encode(card, modifiedAt: exportedAt);
    final output = codec.decode(bytes);
    final assets = (output.data['assets']! as List<Object?>).cast<Map<String, Object?>>();
    final archive = assets.singleWhere((asset) => asset['name'] == 'archive');
    expect(output.iconBytes, orderedEquals(avatar));
    expect(image.decodePng(bytes)!.width, 3);
    expect(output.assetBytes(archive['uri']! as String), orderedEquals(decoded.png!));
    expect(jsonEncode(decoded.json), originalJson);
  });

  test('JPEG main icon produces a valid PNG and keeps its original bytes inline', () {
    final json = _json(_fixture('card-v3.json'));
    final jpeg = Uint8List.fromList(image.encodeJpg(image.Image(width: 2, height: 3)));
    (json['data'] as Map<String, Object?>)['assets'] = [
      {'type': 'icon', 'name': 'main', 'ext': 'jpg', 'uri': 'embeded://portrait.jpg'},
    ];
    final card = TavernCard(json: json, assets: {'portrait.jpg': jpeg});
    final output = codec.encode(card, modifiedAt: exportedAt);
    final decoded = image.decodePng(output)!;
    expect((decoded.width, decoded.height), (2, 3));
    expect(codec.decode(output).iconBytes, orderedEquals(jpeg));
  });

  test('JSON without a portrait still exports a readable PNG card', () {
    final card = codec.decode(_fixture('card-v1.json'));
    final output = codec.encode(card, modifiedAt: exportedAt);
    expect(image.decodePng(output), isNotNull);
    expect(codec.decode(output).name, card.name);
  });

  test('asset paths and URI aliases keep case and never URL-decode traversal', () {
    expect(embeddedCardAssetPath('embeded://A/B.png'), 'A/B.png');
    expect(embeddedCardAssetPath('embedded://A/B.png'), 'A/B.png');
    expect(embeddedCardAssetPath('__asset:A/B.png'), 'A/B.png');
    expect(embeddedCardAssetPath('embeded://../x'), isNull);
    expect(embeddedCardAssetPath('embeded://%2e%2e/x'), '%2e%2e/x');
  });
}

Uint8List _fixture(String name) => File('test/fixtures/$name').readAsBytesSync();
Uint8List _bytes(Map<String, Object?> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));
Map<String, Object?> _json(List<int> bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

// Fixture manipulation uses archive's independent CRC implementation. Production
// PNG code cannot make these assertions pass by sharing its own chunk helpers.
List<(String, Uint8List)> _chunks(Uint8List bytes) {
  final chunks = <(String, Uint8List)>[];
  final data = ByteData.sublistView(bytes);
  for (var offset = 8; offset < bytes.length;) {
    final length = data.getUint32(offset);
    chunks.add((
      ascii.decode(bytes.sublist(offset + 4, offset + 8)),
      Uint8List.sublistView(bytes, offset, offset + length + 12),
    ));
    offset += length + 12;
  }
  return chunks;
}

List<(String, String)> _textChunks(Uint8List bytes) {
  final result = <(String, String)>[];
  for (final (type, chunk) in _chunks(bytes)) {
    if (type != 'tEXt') continue;
    final payload = chunk.sublist(8, chunk.length - 4);
    final end = payload.indexOf(0);
    result.add((latin1.decode(payload.sublist(0, end)), latin1.decode(payload.sublist(end + 1))));
  }
  return result;
}

Uint8List _removeText(Uint8List bytes, String keyword) {
  final out = BytesBuilder()..add(bytes.sublist(0, 8));
  for (final (type, chunk) in _chunks(bytes)) {
    if (type == 'tEXt') {
      final payload = chunk.sublist(8, chunk.length - 4);
      if (latin1.decode(payload.sublist(0, payload.indexOf(0))).toLowerCase() == keyword) continue;
    }
    out.add(chunk);
  }
  return out.takeBytes();
}

Uint8List _insertText(Uint8List bytes, String keyword, String text) {
  final payload = [...latin1.encode(keyword), 0, ...latin1.encode(text)];
  final chunk = Uint8List(payload.length + 12);
  final data = ByteData.sublistView(chunk)..setUint32(0, payload.length);
  chunk.setRange(4, 8, ascii.encode('tEXt'));
  chunk.setRange(8, 8 + payload.length, payload);
  data.setUint32(chunk.length - 4, getCrc32(chunk.sublist(4, chunk.length - 4)));
  final out = BytesBuilder()..add(bytes.sublist(0, 8));
  for (final (type, existing) in _chunks(bytes)) {
    if (type == 'IEND') out.add(chunk);
    out.add(existing);
  }
  return out.takeBytes();
}
