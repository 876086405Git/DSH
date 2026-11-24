// Several characters installed at once: `pack/` is the active one, the others
// wait on the shelf until the person switches to them.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart';

Map<String, String> _bytes(Directory root) => {
  for (final file in root.listSync(recursive: true).whereType<File>())
    if (!file.path.endsWith('.companion-shelved'))
      file.path.substring(root.path.length).replaceAll(r'\', '/'): base64Encode(file.readAsBytesSync()),
};

void main() {
  late Directory temp;
  late CompanionPackStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('companion-roster');
    store = CompanionPackStore(Directory('${temp.path}/home'), expectedRuntime: workshopRuntimeDigest());
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Directory shelf() => Directory('${store.root.path}/shelf');
  File note() => File('${store.root.path}/pack.fallback');
  List<String> folders() => shelf().existsSync()
      ? [for (final d in shelf().listSync().whereType<Directory>()) d.path.substring(shelf().path.length + 1)]
      : const [];
  CompanionPackStore restarted() => CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest());

  Future<String> add(String name) async {
    await store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(name: name)}).path);
    return (await store.characterKey())!;
  }

  WorkshopReceipt receipt({String id = 'cat', String version = '1.0.0', String hash = 'a'}) =>
      WorkshopReceipt(kind: 'companion', id: id, version: version, sha256: hash * 64, origin: workshopTestOrigin);

  Future<String> addWorkshop(WorkshopReceipt workshop, {String name = 'Cat', bool replaceExisting = true}) async {
    final files = {...workshopCharacter(name: name), 'character/preview.png': workshopPng(4, 4)};
    await store.install(workshopZip(temp, files).path, workshop: workshop, replaceExisting: replaceExisting);
    return (await store.characterKey())!;
  }

  Future<List<(String?, bool)>> names([CompanionPackStore? from]) async => [
    for (final entry in await (from ?? store).roster()) (entry.character.name, entry.active),
  ];

  test('installing a second character shelves the first, identity and all', () async {
    final ann = await add('Ann');
    final bea = await add('Bea');
    expect((await store.character()).name, 'Bea');
    expect(await store.characterKey(), bea);
    expect(folders(), hasLength(1));
    final shelved = Directory('${shelf().path}/${folders().single}');
    expect(jsonDecode(File('${shelved.path}/.companion-character.json').readAsStringSync())['key'], ann);
    expect(jsonDecode(File('${shelved.path}/character/character.json').readAsStringSync())['name'], 'Ann');
    expect(File('${shelved.path}/runtime/live2dcubismcore.min.js').existsSync(), isTrue);
    expect(await names(), [('Bea', true), ('Ann', false)]);
    expect(Directory('${store.root.path}/pack.previous').existsSync(), isFalse);
    expect(note().existsSync(), isFalse);
  });

  test('a failed install of another character leaves the active one where it was', () async {
    await add('Ann');
    final broken = {
      ...workshopRuntime(),
      'runtime/cubism-framework.js': utf8.encode('changed'),
      ...workshopCharacter(),
    };
    await expectLater(store.install(workshopZip(temp, broken).path), throwsA(isA<CompanionPackException>()));
    expect(await names(), [('Ann', true)]);
    expect(folders(), isEmpty);
  });

  test('the roster lists the active one, then the most recently shelved', () async {
    final ann = await add('Ann');
    final cat = await addWorkshop(receipt());
    final bea = await add('Bea');
    // Something that isn't a pack is passed over.
    Directory('${shelf().path}/junk').createSync();
    File('${shelf().path}/junk/notes.txt').writeAsStringSync('x');

    final roster = await store.roster();
    expect([for (final e in roster) e.key], [bea, cat, ann]);
    expect([for (final e in roster) e.active], [true, false, false]);
    expect([for (final e in roster) e.character.name], ['Bea', 'Cat', 'Ann']);
    expect(roster[0].character.author, 'Author');
    expect(roster[1].workshop!.same(receipt()), isTrue);
    expect(roster[1].cover!.readAsBytesSync(), workshopPng(4, 4));
    expect(roster[0].workshop, isNull);
    expect(roster[0].cover, isNull);
    expect(roster[2].cover, isNull);
  });

  test('activate swaps both ways and keeps every byte', () async {
    final ann = await add('Ann');
    final bea = await add('Bea');
    final annBytes = _bytes(Directory('${shelf().path}/${folders().single}'));
    final beaBytes = _bytes(store.pack);

    final base = store.revision, revisions = <int>[];
    final sub = store.revisions.listen(revisions.add);
    addTearDown(sub.cancel);
    var stops = 0;
    addTearDown(store.beforeChanges(() async => stops++));

    await store.activate(ann);
    expect(revisions, [base + 1, base + 2]);
    expect(stops, 1);
    expect(
      await store.characterIdentity(),
      isA<({CompanionCharacter character, String? key})>()
          .having((i) => i.key, 'key', ann)
          .having((i) => i.character.name, 'name', 'Ann'),
    );
    expect(await names(), [('Ann', true), ('Bea', false)]);
    expect(_bytes(store.pack), annBytes);
    expect(_bytes(Directory('${shelf().path}/${folders().single}')), beaBytes);

    await store.activate(bea);
    expect(await store.characterKey(), bea);
    expect(await names(), [('Bea', true), ('Ann', false)]);
    expect(_bytes(store.pack), beaBytes);
    expect(await store.unavailableReason(), isNull);
    expect(note().existsSync(), isFalse);
  });

  test('activate refuses a key that is not on the shelf', () async {
    final ann = await add('Ann');
    for (final key in [ann, 'local:${'x' * 24}']) {
      await expectLater(
        store.activate(key),
        throwsA(isA<CompanionPackException>().having((e) => e.detail, 'detail', 'companion_not_shelved')),
      );
    }
    expect(await names(), [('Ann', true)]);
  });

  test('with nothing active, activate just brings the shelved one up', () async {
    final ann = await add('Ann');
    await add('Bea');
    await store.remove();
    await store.activate(ann);
    expect(await names(), [('Ann', true)]);
    expect(folders(), isEmpty);
  });

  test('the same character again replaces her instead of shelving a copy', () async {
    final bundled = workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(name: 'Whale')}).path;
    await store.installBundled(bundled);
    await store.installBundled(bundled);
    expect(await store.characterKey(), companionBundledCharacterKey);
    expect(await names(), [('Whale', true)]);
    expect(folders(), isEmpty);

    final cat = await addWorkshop(receipt());
    await addWorkshop(
      receipt(version: '1.1.0', hash: 'b'),
      name: 'Cat 1.1',
    );
    expect(await store.characterKey(), cat);
    expect((await store.workshopReceipt())!.version, '1.1.0');
    expect(await names(), [('Cat 1.1', true), ('Whale', false)]);
  });

  test('another Workshop companion needs no replacement prompt: the active one goes onto the shelf', () async {
    await add('Ann');
    final cat = await addWorkshop(receipt(), name: 'Cat');
    final dog = await addWorkshop(receipt(id: 'dog'), name: 'Dog', replaceExisting: false);
    expect(await store.characterKey(), dog);
    expect([for (final e in await store.roster()) e.key].take(2), [dog, cat]);
    expect(await names(), [('Dog', true), ('Cat', false), ('Ann', false)]);
    // The same item still keeps its update rules against the active pack.
    await expectLater(
      addWorkshop(receipt(id: 'dog', version: '1.0.0', hash: 'b'), replaceExisting: false),
      workshopError('workshop_version_rewritten'),
    );
  });

  test('a store that does not shelve still asks before replacing', () async {
    store = CompanionPackStore(store.root, expectedRuntime: workshopRuntimeDigest(), shelve: false);
    await add('Ann');
    await expectLater(addWorkshop(receipt(), replaceExisting: false), workshopError('workshop_install_conflict'));
    await addWorkshop(receipt());
    expect(await names(), [('Cat', true)]);
    expect(folders(), isEmpty);
  });

  test('a character already on the shelf comes back as the new install, without a copy left behind', () async {
    final ann = await add('Ann');
    final cat = await addWorkshop(receipt());
    await store.activate(ann);
    await addWorkshop(
      receipt(version: '1.1.0', hash: 'b'),
      name: 'Cat 1.1',
    );
    expect(await store.characterKey(), cat);
    expect((await store.workshopReceipt())!.version, '1.1.0');
    expect(await names(), [('Cat 1.1', true), ('Ann', false)]);
    expect(folders(), hasLength(1));

    // The shelved copy keeps the Workshop's update rules.
    await store.activate(ann);
    await expectLater(
      store.install(workshopZip(temp, workshopCharacter()).path, workshop: receipt(), replaceExisting: true),
      workshopError('workshop_downgrade'),
    );
    expect(await names(), [('Ann', true), ('Cat 1.1', false)]);

    final whale = workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(name: 'Whale')}).path;
    await store.installBundled(whale);
    await add('Bea');
    await store.installBundled(whale);
    // Ann went onto the shelf after Cat 1.1 did.
    expect(await names(), [('Whale', true), ('Bea', false), ('Ann', false), ('Cat 1.1', false)]);
    expect(folders(), hasLength(3));
  });

  test('removeShelved deletes only that one and leaves the stage alone', () async {
    final ann = await add('Ann');
    final bea = await add('Bea');
    final cat = await addWorkshop(receipt());
    var stops = 0;
    addTearDown(store.beforeChanges(() async => stops++));
    final base = store.revision;

    await store.removeShelved(ann);
    expect(store.revision, greaterThan(base));
    expect(stops, 0);
    expect([for (final e in await store.roster()) e.key], [cat, bea]);
    expect(folders(), hasLength(1));
    await store.removeShelved(ann);
    expect(await store.characterKey(), cat);
  });

  test('remove() takes the active one only and activates nobody in her place', () async {
    final ann = await add('Ann');
    await add('Bea');
    await store.remove();
    expect(await store.installed(), isFalse);
    expect(await names(), [('Ann', false)]);
    expect(await restarted().installed(), isFalse);
    expect(await names(restarted()), [('Ann', false)]);
    await store.activate(ann);
    expect(await store.installed(), isTrue);
  });

  group('recovery', () {
    // Ann and Bea with their shelf folders known: Ann active, Bea shelved.
    Future<({String ann, String bea, String annFolder, String beaFolder})> pair() async {
      final ann = await add('Ann');
      final bea = await add('Bea');
      final annFolder = folders().single;
      await store.activate(ann);
      return (ann: ann, bea: bea, annFolder: annFolder, beaFolder: folders().single);
    }

    test('an activate cut short after the active pack was shelved finishes', () async {
      final p = await pair();
      final annBytes = _bytes(store.pack);
      note().writeAsStringSync(p.beaFolder);
      store.pack.renameSync('${shelf().path}/${p.annFolder}');

      final next = restarted();
      expect(await next.installed(), isTrue);
      expect(await next.characterKey(), p.bea);
      expect(await names(next), [('Bea', true), ('Ann', false)]);
      expect(_bytes(Directory('${shelf().path}/${p.annFolder}')), annBytes);
      expect(note().existsSync(), isFalse);
    });

    test('an activate cut short before anything moved changes nothing', () async {
      final p = await pair();
      note().writeAsStringSync(p.beaFolder);
      // Recovery runs with the store's next real step; the roster only reads.
      final next = restarted();
      expect(await next.installed(), isTrue);
      expect(await names(next), [('Ann', true), ('Bea', false)]);
      expect(note().existsSync(), isFalse);
    });

    test('an activate cut short after the swap only drops the note', () async {
      final p = await pair();
      note().writeAsStringSync(p.beaFolder);
      store.pack.renameSync('${shelf().path}/${p.annFolder}');
      Directory('${shelf().path}/${p.beaFolder}').renameSync(store.pack.path);
      final next = restarted();
      expect(await next.installed(), isTrue);
      expect(await names(next), [('Bea', true), ('Ann', false)]);
      expect(note().existsSync(), isFalse);
    });

    test('an install cut short after shelving the active pack brings her back', () async {
      final ann = await add('Ann');
      // Her folder name doesn't matter here: she comes back by the note.
      note().writeAsStringSync('feedface');
      shelf().createSync();
      store.pack.renameSync('${shelf().path}/feedface');
      Directory('${store.root.path}/pack.staging/character').createSync(recursive: true);

      final next = restarted();
      expect(await next.characterKey(), ann);
      expect(await names(next), [('Ann', true)]);
      expect(Directory('${store.root.path}/pack.staging').existsSync(), isFalse);
      expect(note().existsSync(), isFalse);
    });

    test('readers that will not stop leave the swap for the next try', () async {
      final p = await pair();
      note().writeAsStringSync(p.beaFolder);
      store.pack.renameSync('${shelf().path}/${p.annFolder}');
      final next = restarted();
      final unregister = next.beforeChanges(() async => throw StateError('renderer still open'));
      await expectLater(next.installed(), throwsA(isA<CompanionPackException>()));
      expect(note().existsSync(), isTrue);
      expect(store.pack.existsSync(), isFalse);
      unregister();
      expect(await next.installed(), isTrue);
      expect(await names(next), [('Bea', true), ('Ann', false)]);
    });
  });
}
