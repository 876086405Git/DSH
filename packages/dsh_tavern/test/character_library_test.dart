import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/io/card_codec.dart';
import 'package:dsh_tavern/src/store/character_library.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CharacterLibrary library;
  final importedAt = DateTime.utc(2026, 11, 10, 1);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-tavern-cards-');
    library = CharacterLibrary(root, now: () => importedAt);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('import, reload and export keep raw bytes and unknown resources', () async {
    final original = await File('test/fixtures/card-assets.charx').readAsBytes();
    final imported = await library.importCard(original, fileName: '../../not-a-storage-path.charx');
    expect(imported.card.name, '知更');
    expect(imported.avatarPath, isNotNull);
    expect(await File(imported.avatarPath!).exists(), true);
    expect(imported.importedAt, importedAt);
    expect(await File('${root.path}/characters/${imported.id}/original.charx').readAsBytes(), orderedEquals(original));

    final reloaded = await CharacterLibrary(root).read(imported.id);
    expect(reloaded, isNotNull);
    expect(reloaded!.card.json, imported.card.json);
    expect(reloaded.card.originalBytes, orderedEquals(original));
    expect(reloaded.card.assets['unknown-app.bin'], List<int>.generate(256, (index) => index));
    final exported = const CardCodec().decode(await library.exportCard(imported.id, format: TavernCardFormat.charx));
    expect(exported.assets['state.json'], imported.card.assets['state.json']);
    expect(exported.json['unknown_root'], imported.card.json['unknown_root']);
    expect(exported.data['modification_date'], importedAt.millisecondsSinceEpoch ~/ 1000);
    expect((await library.read(imported.id))!.card.data['modification_date'], 0);
    expect((await library.list()).single.id, imported.id);
  });

  test('separate imports never overwrite each other and delete affects only one', () async {
    final bytes = await File('test/fixtures/card-v1.json').readAsBytes();
    final first = await library.importCard(bytes);
    final second = await library.importCard(bytes);
    expect(first.id, isNot(second.id));
    expect(await library.list(), hasLength(2));
    await library.delete(first.id);
    expect(await library.read(first.id), isNull);
    expect((await library.read(second.id))!.card.name, first.card.name);
    await library.delete(first.id);
    expect((await library.list()).single.id, second.id);
  });

  test('runtime projections reuse unchanged files and refresh managed and external edits', () async {
    final imported = await library.importCard(await File('test/fixtures/card-v3.json').readAsBytes());
    final first = await library.readRuntimeAuthority(imported.id, (data) => data);
    final avatar = await library.readRuntimeAvatarMetadata(imported.id);
    expect(identical(await library.readRuntimeAuthority(imported.id, (data) => data), first), isTrue);
    expect(identical(await library.readRuntimeAvatarMetadata(imported.id), avatar), isTrue);
    await library.updateFields(imported.id, {'description': 'Managed change'});
    expect(await library.readRuntimeAuthority(imported.id, (data) => data['description']), 'Managed change');
    expect((await library.readRuntimeAvatarMetadata(imported.id)).snapshot.rawText, contains('Managed change'));

    final file = File('${root.path}/characters/${imported.id}/card.json');
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    (raw['data']! as Map<String, Object?>)['description'] = 'External change with different length';
    await file.writeAsString(jsonEncode(raw));
    expect(
      await library.readRuntimeAuthority(imported.id, (data) => data['description']),
      'External change with different length',
    );
    expect((await library.readRuntimeAvatarMetadata(imported.id)).snapshot.rawText, contains('External change'));
    final detached = await library.readAuthority(imported.id, (data) => data);
    detached!['description'] = 'Detached edit';
    expect(
      await library.readRuntimeAuthority(imported.id, (data) => data['description']),
      'External change with different length',
    );
    await library.delete(imported.id);
    expect(await library.readRuntimeAuthority(imported.id, (data) => data), isNull);
    expect((await library.readRuntimeAvatarMetadata(imported.id)).snapshot.present, isFalse);
  });

  test('runtime projections retain the eight most recently read characters', () async {
    final bytes = await File('test/fixtures/card-v1.json').readAsBytes();
    final ids = <String>[];
    for (var index = 0; index < 9; index++) {
      ids.add((await library.importCard(bytes)).id);
    }
    final authority = <Map<String, Object?>>[];
    final avatars = <CharacterAvatarMetadata>[];
    for (final id in ids.take(8)) {
      authority.add((await library.readRuntimeAuthority(id, (data) => data))!);
      avatars.add(await library.readRuntimeAvatarMetadata(id));
    }
    expect(identical(await library.readRuntimeAuthority(ids.first, (data) => data), authority.first), isTrue);
    expect(identical(await library.readRuntimeAvatarMetadata(ids.first), avatars.first), isTrue);
    await library.readRuntimeAuthority(ids.last, (data) => data);
    await library.readRuntimeAvatarMetadata(ids.last);
    expect(identical(await library.readRuntimeAuthority(ids.first, (data) => data), authority.first), isTrue);
    expect(identical(await library.readRuntimeAvatarMetadata(ids.first), avatars.first), isTrue);
    final reloaded = await library.readRuntimeAuthority(ids[1], (data) => data);
    final avatar = await library.readRuntimeAvatarMetadata(ids[1]);
    expect(identical(reloaded, authority[1]), isFalse);
    expect(reloaded, authority[1]);
    expect(identical(avatar, avatars[1]), isFalse);
    expect(avatar.snapshot.sameAs(avatars[1].snapshot), isTrue);
    expect(avatar.file, avatars[1].file);
    expect(avatar.sha256, avatars[1].sha256);
  });

  test('concurrent imports are serialized and no partial directory is listed', () async {
    final bytes = await File('test/fixtures/card-v3.json').readAsBytes();
    final first = library.importCard(bytes);
    final visibleAfterFirst = library.list();
    final second = library.importCard(bytes);
    expect(await visibleAfterFirst, hasLength(1));
    final results = await Future.wait([first, second]);
    expect(results.map((record) => record.id).toSet(), hasLength(2));
    expect(await library.list(), hasLength(2));
  });

  test('a failed import does not poison the operation queue or publish files', () async {
    await expectLater(
      library.importCard(Uint8List.fromList(utf8.encode('{broken'))),
      throwsA(isA<TavernImportError>()),
    );
    expect(await library.list(), isEmpty);
    final record = await library.importCard(await File('test/fixtures/card-v1.json').readAsBytes());
    expect((await library.read(record.id))!.card.name, '灯塔守望者 🐳');
  });

  test('recovery discards staging and deletion trash but keeps committed imports', () async {
    final record = await library.importCard(await File('test/fixtures/card-v1.json').readAsBytes());
    for (final name in ['.staging-interrupted', '.trash-interrupted']) {
      final dir = await Directory('${root.path}/characters/$name').create();
      await File('${dir.path}/half-written').writeAsString('not committed');
    }
    final recovered = await CharacterLibrary(root).list();
    expect(recovered.single.id, record.id);
    expect(await Directory('${root.path}/characters/.staging-interrupted').exists(), false);
    expect(await Directory('${root.path}/characters/.trash-interrupted').exists(), false);
  });

  test('invalid ids cannot address another directory', () async {
    await expectLater(library.read('../outside'), throwsArgumentError);
    await expectLater(library.delete('/outside'), throwsArgumentError);
    await expectLater(library.exportCard('card-not-an-id'), throwsArgumentError);
  });

  test('unknown valid id reads null and export reports a stable import error', () async {
    const missing = 'card-00000000000000000000000000000000';
    expect(await library.read(missing), isNull);
    await expectLater(library.exportCard(missing), throwsA(isA<TavernImportError>()));
  });

  test('lorebook import leaves the character library unchanged', () async {
    final bytes = Uint8List.fromList(utf8.encode('{"entries":{}}'));
    await expectLater(
      library.importCard(bytes),
      throwsA(isA<TavernImportError>().having((error) => error.isLorebook, 'isLorebook', true)),
    );
    expect(await library.list(), isEmpty);
  });
}
