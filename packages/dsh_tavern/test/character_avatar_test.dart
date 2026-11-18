import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/authoring_authority.dart';
import 'package:dsh_tavern/src/store/character_library.dart' as character_library;
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

const _deadline = Duration(seconds: 10);

void main() {
  test('avatar adoption retains the character and original media across CAS, failure and reopen', () async {
    final h = await ScriptFixture.open();
    final oldPng = _png(2, 3);
    final opaque = Uint8List.fromList([7, 0, 255, 13]);
    final original = _charx(
      {
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'foreign_root': {'keep': true},
        'data': {
          'name': 'Quiet portrait',
          'description': 'Original description.',
          'first_mes': 'Hello.',
          'extensions': {
            'foreign': [1, null],
          },
          'assets': [
            {'type': 'icon', 'name': 'main', 'uri': 'embedded://assets/old.png', 'ext': 'png', 'foreign_asset': true},
            {'type': 'x-private', 'name': 'opaque', 'uri': 'embedded://extras/value.bin', 'ext': 'bin'},
          ],
        },
      },
      {'assets/old.png': oldPng, 'extras/value.bin': opaque},
    );
    final character = await h.engine.importCard(original);
    final id = character.id;
    final directory = '${h.root.path}/characters/$id';
    final identityFile = File('$directory/library.json');
    final oldMetadata = scriptMap(jsonDecode(await identityFile.readAsString()))
      ..['foreign_library'] = {
        'keep': [false, null],
      };
    await identityFile.writeAsString(jsonEncode(oldMetadata), flush: true);
    final oldRaw = await File('$directory/card.json').readAsString();
    final oldPortrait = await File('$directory/portrait.png').readAsBytes();
    final oldResources = await _resources(directory, oldMetadata);
    final chat = await h.engine.createChat(id);
    final acknowledgements = <TavernScriptCharacterAvatarSnapshot>[];
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.kind == TavernScriptDispatchKind.cache &&
          request.delta?.resourceRefs.containsKey('characterAvatars') == true) {
        // The write must release both Library queues before waiting for this
        // real cache acknowledgement to read the adopted avatar.
        acknowledgements.add(await h.bridge.readCharacterAvatar(request.contextId, id));
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    var context = await h.context(chat, characterId: id, instanceId: 'avatar');
    final before = await h.bridge.readCharacterAvatar(context.id, id);
    expect(before.bytes, orderedEquals(oldPng));
    final oldCache = _avatarRow(await h.bridge.snapshot(context.id), id);
    expect(oldCache['hasAvatar'], isTrue);
    expect((await h.engine.watchCharacters().first).single.avatarPath, endsWith('/portrait.png'));

    final input = Uint8List.fromList(image.encodeJpg(image.Image(width: 3, height: 5)));
    final pending = h.bridge.replaceCharacterAvatar(context.id, id, input, expectedVersion: before.version);
    input.fillRange(0, input.length, 0);
    final replaced = await pending.timeout(_deadline);
    expect(replaced.characterId, id);
    expect(replaced.version, isNot(before.version));
    final adoptedPng = replaced.bytes!;
    final decoded = image.decodePng(adoptedPng)!;
    expect((decoded.width, decoded.height), (3, 5));
    final adoptedIdentity = await identityFile.readAsBytes();
    final unchanged = await h.bridge.replaceCharacterAvatar(
      context.id,
      id,
      adoptedPng,
      expectedVersion: replaced.version,
    );
    expect(unchanged.version, replaced.version);
    expect(unchanged.bytes, orderedEquals(adoptedPng));
    expect(await identityFile.readAsBytes(), orderedEquals(adoptedIdentity));
    final brokenPng = Uint8List.fromList(adoptedPng);
    brokenPng[29] ^= 1; // IHDR CRC, with the actual PNG payload otherwise intact.
    await expectLater(
      h.bridge.replaceCharacterAvatar(context.id, id, brokenPng, expectedVersion: replaced.version),
      throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
    );
    expect(await identityFile.readAsBytes(), orderedEquals(adoptedIdentity));
    final leaked = replaced.bytes!..fillRange(0, adoptedPng.length, 0);
    expect(leaked, isNot(orderedEquals(adoptedPng)));
    expect(replaced.bytes, orderedEquals(adoptedPng));
    expect((await h.bridge.readCharacterAvatar(context.id, id)).bytes, orderedEquals(adoptedPng));
    expect(await File('$directory/card.json').readAsString(), oldRaw);
    expect(await File('$directory/original.charx').readAsBytes(), orderedEquals(original));
    expect(await File('$directory/portrait.png').readAsBytes(), orderedEquals(oldPortrait));
    expect(await File('$directory/source.png').exists(), isFalse);
    expect(await _resources(directory, oldMetadata), oldResources);
    final adoptedMetadata = scriptMap(jsonDecode(await identityFile.readAsString()));
    final avatar = scriptMap(adoptedMetadata['avatar']);
    expect({...adoptedMetadata}..remove('avatar'), oldMetadata);
    expect(await File('$directory/${avatar['file']}').readAsBytes(), orderedEquals(adoptedPng));
    final detail = (await h.engine.character(id))!;
    final summary = (await h.engine.watchCharacters().first).single;
    expect(detail.id, id);
    expect(detail.avatarPath, summary.avatarPath);
    expect(await File(summary.avatarPath!).readAsBytes(), orderedEquals(adoptedPng));
    final cached = _avatarRow(await h.bridge.snapshot(context.id), id);
    expect(cached['version'], isNot(oldCache['version']));
    expect(cached['hasAvatar'], isTrue);
    expect(acknowledgements.any((value) => value.version == replaced.version), isTrue);
    await expectLater(
      h.bridge.replaceCharacterAvatar(context.id, id, _png(4, 6), expectedVersion: before.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );

    await h.engine.updateCharacterFields(id, {'description': 'Updated data, same portrait.'});
    final afterData = await h.bridge.readCharacterAvatar(context.id, id);
    expect(afterData.version, isNot(replaced.version));
    expect(afterData.bytes, orderedEquals(adoptedPng));
    expect((await h.engine.characterFields(id))!['description'], 'Updated data, same portrait.');
    await expectLater(
      h.bridge.replaceCharacterAvatar(context.id, id, _png(4, 6), expectedVersion: replaced.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    final externalMetadata = scriptMap(jsonDecode(await identityFile.readAsString()))..['foreign_library_edit'] = 2;
    await identityFile.writeAsString(jsonEncode(externalMetadata), flush: true);
    await expectLater(
      h.bridge.replaceCharacterAvatar(context.id, id, _png(4, 6), expectedVersion: afterData.version),
      throwsA(scriptError(TavernScriptErrorCode.revisionConflict)),
    );
    final beforeFailure = await h.bridge.readCharacterAvatar(context.id, id);
    final beforeFailureMetadata = await identityFile.readAsBytes();
    final blocker = await Directory('$directory/library.json.writing').create();
    try {
      await expectLater(
        h.bridge.replaceCharacterAvatar(context.id, id, _png(4, 6), expectedVersion: beforeFailure.version),
        throwsA(
          scriptError(TavernScriptErrorCode.storage).having((error) => error.committed, 'actual adoption', false),
        ),
      );
      expect(await identityFile.readAsBytes(), orderedEquals(beforeFailureMetadata));
      expect((await h.bridge.readCharacterAvatar(context.id, id)).bytes, orderedEquals(adoptedPng));
    } finally {
      await blocker.delete();
    }
    // The failed metadata write left a complete, unreferenced image. Retrying
    // exactly those bytes accepts it and does not overwrite any previous image.
    final retried = await h.bridge.replaceCharacterAvatar(
      context.id,
      id,
      _png(4, 6),
      expectedVersion: beforeFailure.version,
    );
    expect(image.decodePng(retried.bytes!)!.width, 4);
    final rawAfterData = await File('$directory/card.json').readAsString();
    await h.reopen();
    context = await h.context(chat, characterId: id, instanceId: 'avatar-reopened');
    expect((await h.bridge.readCharacterAvatar(context.id, id)).bytes, orderedEquals(retried.bytes!));
    expect(await File((await h.engine.character(id))!.avatarPath!).readAsBytes(), orderedEquals(retried.bytes!));
    expect(
      await File((await h.engine.watchCharacters().first).single.avatarPath!).readAsBytes(),
      orderedEquals(retried.bytes!),
    );

    // A real Library observer failure after its metadata rename still records
    // the adopted capture in finally. This is the file/authority failure
    // boundary, not a substitute for an App acknowledgement test.
    await h.close();
    final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
    character_library.CharacterAvatarCapture? committed;
    final finalPng = _png(7, 8);
    try {
      final authority = AuthoringAuthority(root: h.root, store: store);
      final cards = character_library.CharacterLibrary(h.root, authority: authority);
      final expected = await cards.readAvatar(id);
      var prepares = 0;
      cards.cardCommitted = (_, _) {
        throw StateError('Actual post-rename observer failure.');
      };
      await expectLater(
        cards.replaceAvatar(
          id,
          finalPng,
          prepare: (current) {
            prepares++;
            expect(current.metadata.snapshot.sameAs(expected.metadata.snapshot), isTrue);
            expect(current.bytes, orderedEquals(expected.bytes!));
          },
          onCommitted: (actual) {
            committed = actual;
          },
        ),
        throwsA(isA<TavernAuthoringException>().having((error) => error.receipt?.committed, 'actual adoption', true)),
      );
      expect(prepares, 1);
      expect(committed, isNotNull);
      expect(committed!.bytes, orderedEquals(finalPng));
      expect((await cards.readAvatar(id)).bytes, orderedEquals(finalPng));
      expect(await File('$directory/card.json').readAsString(), rawAfterData);
      expect(await File('$directory/original.charx').readAsBytes(), orderedEquals(original));
      expect(await File('$directory/portrait.png').readAsBytes(), orderedEquals(oldPortrait));
      expect(await _resources(directory, oldMetadata), oldResources);
    } finally {
      await store.close();
    }
    await h.reopen();
    context = await h.context(chat, characterId: id, instanceId: 'avatar-after-notification');
    expect((await h.bridge.readCharacterAvatar(context.id, id)).bytes, orderedEquals(finalPng));
    expect(await File((await h.engine.character(id))!.avatarPath!).readAsBytes(), orderedEquals(finalPng));
    expect(
      await File((await h.engine.watchCharacters().first).single.avatarPath!).readAsBytes(),
      orderedEquals(finalPng),
    );
    h.expectNoGeneration();
  });
}

ScriptJson _avatarRow(TavernScriptSnapshot snapshot, String id) =>
    (snapshot.resourceRefs['characterAvatars']! as List<Object?>).cast<ScriptJson>().singleWhere(
      (row) => row['characterId'] == id,
    );

Future<Map<String, Object?>> _resources(String directory, ScriptJson metadata) async => {
  for (final path in (metadata['resources']! as List<Object?>).cast<String>())
    path: await File('$directory/resources/$path').readAsBytes(),
};

Uint8List _png(int width, int height) => Uint8List.fromList(image.encodePng(image.Image(width: width, height: height)));

Uint8List _charx(ScriptJson raw, Map<String, Uint8List> assets) {
  final archive = Archive()..addFile(ArchiveFile.string('card.json', jsonEncode(raw)));
  for (final entry in assets.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
