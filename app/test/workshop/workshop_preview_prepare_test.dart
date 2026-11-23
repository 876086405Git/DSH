import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../state/workshop_state_support.dart' show StatePackages;
import 'support.dart';

WorkshopPublication _publication(String kind, {bool preview = false}) => WorkshopPublication({
  ...workshopMeta(kind: kind),
  if (preview) 'previewSource': workshopPreviewSources[kind],
});

Map<String, Object?> _pet(int width, {bool alternate = false}) => {
  ...workshopPet(),
  'canvas': {'w': 513, 'h': 16}, 'contentBox': {'x': 0, 'y': 0, 'w': 513, 'h': 16},
  'animations': {
    // Insert the larger alternative first to distinguish map order from the
    // states.idle primary selection. The first main frame is cell 1, not 0.
    if (alternate) 'bonus': {'sheet': 'bonus.png', 'frameW': 513, 'frameH': 1, 'cols': 1,
      'box': {'x': 0, 'y': 0, 'w': 513, 'h': 1}, 'frames': [{'i': 0, 'ms': 200}]},
    'main': {'sheet': 'idle.png', 'frameW': width, 'frameH': 1, 'cols': 2,
      'box': {'x': 0, 'y': 0, 'w': width, 'h': 1}, 'frames': [{'i': 1, 'ms': 200}, {'i': 0, 'ms': 300}]},
  },
  'states': {'idle': ['main', if (alternate) 'bonus']},
};

Future<CompanionPackStore> _companion(Directory temp, {String? textureName, bool extraPreview = false}) async {
  final files = workshopCharacter();
  if (textureName != null) {
    final model = jsonDecode(utf8.decode(files['character/m.model3.json']!)) as Map<String, dynamic>;
    (model['FileReferences'] as Map)['Textures'] = [textureName];
    files['character/m.model3.json'] = utf8.encode(jsonEncode(model));
    files['character/$textureName'] = files.remove('character/texture.png')!;
  }
  if (extraPreview) files['character/preview.png'] = workshopPng(3, 2);
  final store = CompanionPackStore(Directory('${temp.path}/store'), expectedRuntime: workshopRuntimeDigest());
  // Runtime is installed manually; the preview stays in a later data-only ZIP.
  await store.install(workshopZip(temp, {...workshopRuntime(), ...files}).path);
  return store;
}

class _Access extends WorkshopAccessController {
  _Access(this.capabilities);
  final WorkshopCapabilities capabilities;

  @override
  WorkshopAccessState build() => WorkshopAccessState(session: Object(), capabilities: capabilities);
}

void main() {
  late Directory temp;
  late FakeWorkshopHttp http;
  late WorkshopRepository repository;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('workshop-preview-prepare-');
    http = FakeWorkshopHttp((method, url, headers, body) => throw StateError('Preparation must not send HTTP'));
    repository = WorkshopRepository(
      client: WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http),
      packages: StatePackages(), downloadDirectory: Directory('${temp.path}/downloads'), appVersion: '1.0.0',
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('pet opt-in checks the primary idle cell and preserves its nonzero first frame', () async {
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    final installed = await pets.install(workshopZip(temp, {
      'pack.json': utf8.encode(jsonEncode(_pet(512, alternate: true))),
      'idle.png': workshopPng(1024, 1), 'bonus.png': workshopPng(513, 1),
    }));
    final prepared = await repository.preparePet(pets, installed.id,
      File('${temp.path}/pet-preview.zip'), _publication('pet', preview: true));
    final members = workshopUnzip(prepared.file);
    final manifest = jsonDecode(utf8.decode(members['pack.json']!)) as Map;
    final main = (manifest['animations'] as Map)['main'] as Map;
    expect((manifest['states'] as Map)['idle'], ['main', 'bonus']);
    expect((main['frames'] as List).first, {'i': 1, 'ms': 200});
    expect(main['frameW'], 512);
    expect(members.keys.toSet(), {'pack.json', 'idle.png', 'bonus.png'});
    expect(members['idle.png'], workshopPng(1024, 1));
    expect(prepared.metadata.previewSource, 'pet-idle');
    expect(prepared.metadata.sha256, sha256.convert(prepared.file.readAsBytesSync()).toString());
    expect(http.requests, isEmpty);
  });

  test('a 513-pixel idle cell needs advertised scaling, which leaves the ZIP contents unchanged', () async {
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    final installed = await pets.install(workshopZip(temp, {
      'pack.json': utf8.encode(jsonEncode(_pet(513))), 'idle.png': workshopPng(1026, 1),
    }));
    final old = await repository.preparePet(pets, installed.id, File('${temp.path}/old.zip'), _publication('pet'));
    expect(old.metadata.previewSource, isNull);
    await expectLater(repository.preparePet(pets, installed.id,
      File('${temp.path}/opt-in.zip'), _publication('pet', preview: true)), workshopError('workshop_preview_dimensions'));
    final originalMembers = workshopUnzip(old.file);
    expect(originalMembers['idle.png'], workshopPng(1026, 1));
    for (final downscale in [false, true]) {
      final caps = WorkshopCapabilities.fromJson({
        ...workshopCaps(),
        'preview': {
          'schema': 1, 'format': 'png', 'sources': ['pet-idle'],
          'maxWidth': 512, 'maxHeight': 512, 'maxPixels': 262144, 'maxBytes': 2097152,
          if (downscale) 'petIdleDownscale': true,
        },
      });
      final container = ProviderContainer(overrides: [
        workshopAccessProvider.overrideWith(() => _Access(caps)),
        workshopRepositoryProvider.overrideWith((ref) async => repository),
        workshopDirectoryProvider.overrideWithValue(() async => temp),
        petLibraryProvider.overrideWithValue(pets),
      ]);
      try {
        final prepared = container.read(workshopPrepareDraftProvider)(WorkshopPublishSource(
          kind: 'pet', localId: installed.id, preview: const WorkshopPreviewInput.petIdle(),
        ), _publication('pet', preview: true));
        if (!downscale) {
          await expectLater(prepared, workshopError('workshop_preview_dimensions'));
        } else {
          final draft = await prepared;
          expect(draft.upload.metadata.previewSource, 'pet-idle');
          expect(workshopUnzip(draft.upload.file), originalMembers);
          expect(draft.upload.metadata.sha256, sha256.convert(draft.upload.file.readAsBytesSync()).toString());
          await draft.cleanup();
        }
      } finally {
        container.dispose();
      }
    }
    expect(http.requests, isEmpty);
  });

  test('companion selection snapshots PNG bytes and hashes the one final archive', () async {
    final store = await _companion(temp);
    final original = await store.exportZip(File('${temp.path}/plain.zip'),
      author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat');
    final expectedModel = workshopUnzip(original);
    final selected = workshopPng(2, 3), expectedPng = Uint8List.fromList(workshopPng(2, 3));
    final preview = WorkshopPreviewInput.companionPng(selected);
    selected.fillRange(0, selected.length, 0);
    final prepared = await repository.prepareCompanion(store, File('${temp.path}/with-preview.zip'),
      _publication('companion', preview: true), preview: preview);
    final members = workshopUnzip(prepared.file);
    expect((preview.width, preview.height, preview.size), (2, 3, expectedPng.length));
    expect(members.keys.toSet(), {...expectedModel.keys, 'character/preview.png'});
    for (final member in expectedModel.entries) {
      expect(members[member.key], member.value, reason: member.key);
    }
    expect(members['character/preview.png'], expectedPng);
    expect(prepared.metadata.previewSource, 'companion-preview');
    expect(prepared.metadata.size, prepared.file.lengthSync());
    expect(prepared.metadata.sha256, sha256.convert(prepared.file.readAsBytesSync()).toString());
    expect(prepared.files, members.keys.toList()..sort());
    expect(temp.listSync().where((item) => item.uri.pathSegments.any((part) => part.startsWith('.workshop-preview-'))), isEmpty);
    final destination = CompanionPackStore(Directory('${temp.path}/reinstalled'), expectedRuntime: workshopRuntimeDigest());
    await destination.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    await destination.install(prepared.file.path, replaceExisting: true, workshop: WorkshopReceipt(
      kind: 'companion', id: prepared.metadata.id, version: prepared.metadata.version,
      sha256: prepared.metadata.sha256, origin: workshopTestOrigin));
    expect(File('${destination.pack.path}/character/preview.png').readAsBytesSync(), expectedPng);
    expect(await destination.unavailableReason(), isNull);
    expect(http.requests, isEmpty);
  });

  test('an old unreferenced preview filename does not opt a companion into public previews', () async {
    final store = await _companion(temp, extraPreview: true);
    final prepared = await repository.prepareCompanion(store, File('${temp.path}/old-companion.zip'), _publication('companion'));
    expect(prepared.metadata.previewSource, isNull);
    expect(workshopUnzip(prepared.file).containsKey('character/preview.png'), isFalse);
    expect(File('${store.pack.path}/character/preview.png').existsSync(), isTrue);
  });

  for (final texture in ['preview.png', 'Preview.PNG', 'preview.png/texture.png']) {
    test('a model resource at $texture is never overwritten by the selected preview', () async {
      final store = await _companion(temp, textureName: texture);
      final original = File('${store.pack.path}/character/$texture').readAsBytesSync();
      final target = File('${temp.path}/conflict.zip');
      await expectLater(repository.prepareCompanion(store, target, _publication('companion', preview: true),
        preview: WorkshopPreviewInput.companionPng(workshopPng(2, 2))), workshopError('workshop_preview_conflict'));
      expect(target.existsSync(), isFalse);
      expect(File('${store.pack.path}/character/$texture').readAsBytesSync(), original);
      expect(temp.listSync().where((item) => item.uri.pathSegments.any((part) => part.startsWith('.workshop-preview-'))), isEmpty);
    });
  }

  test('explicit companion preview requires matching image input and declaration', () async {
    final store = await _companion(temp);
    final target = File('${temp.path}/missing.zip');
    await expectLater(repository.prepareCompanion(store, target, _publication('companion', preview: true)),
      workshopError('workshop_preview_missing'));
    await expectLater(repository.prepareCompanion(store, target, _publication('companion'),
      preview: WorkshopPreviewInput.companionPng(workshopPng(1, 1))), workshopError('workshop_bad_metadata'));
    await expectLater(repository.prepareCompanion(store, target, _publication('companion', preview: true),
      preview: const WorkshopPreviewInput.petIdle()), workshopError('workshop_bad_metadata'));
    expect(target.existsSync(), isFalse);
  });

  test('preview preparation preserves an existing destination and its source-directory boundary', () async {
    final store = await _companion(temp);
    final target = File('${temp.path}/keep.zip')..writeAsStringSync('keep');
    final preview = WorkshopPreviewInput.companionPng(workshopPng(1, 1));
    await expectLater(repository.prepareCompanion(store, target, _publication('companion', preview: true), preview: preview),
      workshopError('workshop_export_exists'));
    expect(target.readAsStringSync(), 'keep');
    final inside = File('${store.root.path}/new/output.zip');
    await expectLater(repository.prepareCompanion(store, inside, _publication('companion', preview: true), preview: preview),
      workshopError('workshop_storage'));
    expect(inside.parent.existsSync(), isFalse);
    expect(temp.listSync().where((item) => item.uri.pathSegments.any((part) => part.startsWith('.workshop-preview-'))), isEmpty);
  });

  test('PNG input accepts the boundary and rejects size, dimensions, CRC, truncation and animation', () {
    final boundary = WorkshopPreviewInput.companionPng(workshopPng(512, 512));
    expect((boundary.width, boundary.height), (512, 512));
    expect(() => WorkshopPreviewInput.companionPng(Uint8List(0)), workshopError('workshop_preview_size'));
    expect(() => WorkshopPreviewInput.companionPng(Uint8List(workshopPreviewBytes + 1)), workshopError('workshop_preview_size'));
    expect(() => WorkshopPreviewInput.companionPng(workshopPng(513, 1)), workshopError('workshop_preview_dimensions'));
    final png = workshopPng(1, 1);
    final badCrc = Uint8List.fromList(png)..[png.length - 1] ^= 1;
    expect(() => WorkshopPreviewInput.companionPng(badCrc), workshopError('workshop_preview_png'));
    expect(() => WorkshopPreviewInput.companionPng(Uint8List.sublistView(png, 0, png.length - 1)),
      workshopError('workshop_preview_png'));
    final animation = Uint8List(20);
    final data = ByteData.sublistView(animation);
    data.setUint32(0, 8);
    animation.setRange(4, 8, ascii.encode('acTL'));
    data.setUint32(8, 1);
    data.setUint32(16, getCrc32(Uint8List.sublistView(animation, 4, 16)));
    final apng = Uint8List.fromList([...png.take(33), ...animation, ...png.skip(33)]);
    expect(() => WorkshopPreviewInput.companionPng(apng), workshopError('workshop_preview_png'));
  });
}
