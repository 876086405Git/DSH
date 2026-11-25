import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Size;

import 'package:dsh_app/companion/companion_float.dart' show companionFloatStoreProvider;
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/themes/theme_pack.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show workshopPng, workshopUnzip, workshopZip;
import 'workshop_state_support.dart' show StateClient, StatePackages, stateSettled, stateSignal;

const _source = WorkshopPublishSource(kind: 'pet', localId: 'user-cat', name: 'Cat');
WorkshopPublicationInput _input() => WorkshopPublicationInput(id: 'cat', titleZh: '小猫', titleEn: 'Cat',
  author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat');

class _Pets extends PetLibrary {
  _Pets() : super(() async => Directory('unused-source-pets'));
  bool fail = false;
  @override
  Future<List<PetPack>> list() async {
    if (fail) throw const WorkshopException('workshop_storage');
    return [const PetPack(id: 'user-cat', name: 'Cat', canvas: Size(1, 1), anchorX: 0,
      baseline: 1, contentBox: Rect.fromLTWH(0, 0, 1, 1), animations: {}, states: {},
      author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat')];
  }
}

class _Companion extends CompanionPackStore {
  _Companion() : super(Directory('unused-source-companion'));
  bool available = true;
  @override
  Future<bool> installed() async => available;
  @override
  Future<CompanionCharacter> character() async => const CompanionCharacter(name: 'Private nickname',
    author: 'Model author', license: 'CC-BY-4.0', source: 'https://source.example/model');
}

class _Repository extends WorkshopRepository {
  _Repository() : super(client: StateClient(), packages: StatePackages(),
    downloadDirectory: Directory('unused-source-downloads'), appVersion: '1.0.0');
  bool fail = false;
  String? selected, name, persona;
  WorkshopPreviewInput? preview;
  Future<WorkshopPreparedUpload> _write(File destination, WorkshopPublication publication) async {
    await destination.writeAsBytes([1, 2, 3, 4]);
    if (fail) throw const WorkshopException('workshop_no_space');
    // Tests the state/ownership seam, not an archive parser or hash verifier.
    return WorkshopPreparedUpload(file: destination, metadata: publication.withArchive('a' * 64, 4),
      files: const ['pack.json', 'idle.png']);
  }
  @override
  Future<WorkshopPreparedUpload> preparePet(PetLibrary library, String localId, File destination,
    WorkshopPublication publication, {bool petIdleDownscale = false}) async {
    selected = localId;
    return _write(destination, publication);
  }
  @override
  Future<WorkshopPreparedUpload> prepareCompanion(CompanionPackStore store, File destination,
    WorkshopPublication publication, {String? name, String? persona, WorkshopPreviewInput? preview}) async {
    selected = 'companion';
    this.name = name;
    this.persona = persona;
    this.preview = preview;
    return _write(destination, publication);
  }
}

typedef _Loader = Future<WorkshopPublishSources> Function();
class _LoaderChoice extends Notifier<_Loader> {
  _LoaderChoice(this.initial);
  final _Loader initial;
  @override
  _Loader build() => initial;
  void select(_Loader next) => state = next;
}
final _loaderChoice = NotifierProvider<_LoaderChoice, _Loader>(() => throw StateError('Missing source loader'));

Future<WorkshopPublishSources> _ready(ProviderContainer container) {
  final done = Completer<WorkshopPublishSources>();
  final subscription = container.listen(workshopPublishSourcesProvider, (_, next) {
    if (!next.loading && !done.isCompleted) done.complete(next);
  }, fireImmediately: true);
  return done.future.whenComplete(subscription.close);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installed theme and picked theme ZIP both prepare an attributed theme archive', () async {
    final root = await Directory.systemTemp.createTemp('workshop-theme-source-test-');
    final library = ThemeLibrary(() async => Directory('${root.path}/local'));
    final repository = WorkshopRepository(
      client: StateClient(),
      packages: StatePackages(),
      downloadDirectory: Directory('${root.path}/downloads'),
      appVersion: '1.4.0',
    );
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async => root),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
      themeLibraryProvider.overrideWithValue(library),
    ]);
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return root.path;
    });
    try {
      final local = await library.saveCustom(ThemePack.parse({'schema': 1, 'id': 'mine', 'name': 'My local theme'}));
      final sources = await container.read(workshopSourcesLoaderProvider)();
      final installed = sources.values.singleWhere((source) => source.kind == 'theme');
      expect(installed.localId, local.id);
      expect(installed.fromFile, isFalse);

      final zip = workshopZip(root, {
        'folder/theme.json': utf8.encode(jsonEncode({'schema': 1, 'id': 'mine', 'name': 'My ZIP theme'})),
      });
      final picked = await container.read(workshopFileStagerProvider)(zip);
      expect(picked.kind, 'theme');
      expect(picked.localId, installed.localId);
      expect(picked.fromFile, isTrue);
      expect((await library.load(local.id)).name, 'My local theme');

      final prepare = container.read(workshopPrepareDraftProvider);
      final publication = _input().publication('theme');
      for (final source in [installed, picked]) {
        final draft = await prepare(source, publication);
        try {
          expect((draft.upload.metadata.kind, draft.upload.metadata.id), ('theme', 'cat'));
          final files = workshopUnzip(draft.upload.file);
          expect(files.keys, ['theme.json']);
          final manifest = jsonDecode(utf8.decode(files['theme.json']!)) as Map<String, dynamic>;
          expect(manifest['name'], source.name);
          expect(manifest['author'], 'Author');
        } finally {
          await draft.dispose();
        }
      }
    } finally {
      messenger.setMockMethodCallHandler(paths, null);
      container.dispose();
      await root.delete(recursive: true);
    }
  });

  test('source loader lists local public attribution without a companion nickname', () async {
    final container = ProviderContainer(overrides: [
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      final sources = await container.read(workshopSourcesLoaderProvider)();
      expect(sources.values.map((source) => source.kind), ['pet', 'companion']);
      expect(sources.values.first.localId, 'user-cat');
      expect(sources.values.last.name, isNull);
      expect(sources.values.last.author, 'Model author');
      expect(sources.issues, isEmpty);
    } finally { container.dispose(); }
  });

  test('one source failure keeps the other source and stable issue code', () async {
    final pets = _Pets()..fail = true;
    final companion = _Companion();
    final container = ProviderContainer(overrides: [
      petLibraryProvider.overrideWithValue(pets),
      companionFloatStoreProvider.overrideWithValue(() async => companion),
    ]);
    try {
      final sources = await container.read(workshopSourcesLoaderProvider)();
      expect(sources.values.single.kind, 'companion');
      expect(sources.issues['pet']?.code, 'workshop_storage');
      companion.available = false;
      expect((await container.read(workshopSourcesLoaderProvider)()).issues['companion']?.code,
        'workshop_companion_unavailable');
    } finally { container.dispose(); }
  });

  test('failed source refresh preserves the old choices', () async {
    var fail = false;
    final container = ProviderContainer(overrides: [
      workshopSourcesLoaderProvider.overrideWithValue(() async {
        if (fail) throw const WorkshopException('workshop_storage');
        return WorkshopPublishSources(values: [_source]);
      }),
    ]);
    container.listen(workshopPublishSourcesProvider, (_, _) {});
    try {
      expect((await _ready(container)).values.single, same(_source));
      fail = true;
      await container.read(workshopPublishSourcesProvider.notifier).refresh();
      final current = container.read(workshopPublishSourcesProvider);
      expect(current.values.single, same(_source));
      expect(current.issues['all']?.code, 'workshop_storage');
      expect(current.loading, isFalse);
    } finally { container.dispose(); }
  });

  test('a synchronously throwing source factory becomes state after initialization', () async {
    final container = ProviderContainer(overrides: [
      workshopSourcesLoaderProvider.overrideWithValue(() => throw const WorkshopException('workshop_storage')),
    ]);
    try {
      final current = await _ready(container);
      expect(current.loading, isFalse);
      expect(current.issues['all']?.code, 'workshop_storage');
    } finally { container.dispose(); }
  });

  test('late source refresh cannot overwrite a newly selected loader generation', () async {
    final entered = Completer<void>(), gate = Completer<WorkshopPublishSources>();
    var count = 0;
    final choice = _LoaderChoice(() async {
      if (++count == 1) return WorkshopPublishSources(values: [_source]);
      entered.complete();
      return gate.future;
    });
    final container = ProviderContainer(overrides: [
      _loaderChoice.overrideWith(() => choice),
      workshopSourcesLoaderProvider.overrideWith((ref) => ref.watch(_loaderChoice)),
    ]);
    container.listen(workshopPublishSourcesProvider, (_, _) {});
    await _ready(container);
    final pending = container.read(workshopPublishSourcesProvider.notifier).refresh();
    final settled = stateSettled(pending);
    try {
      await stateSignal(entered, pending);
      choice.select(() async => WorkshopPublishSources(values: const [
        WorkshopPublishSource(kind: 'companion', localId: 'companion'),
      ]));
      expect((await _ready(container)).values.single.kind, 'companion');
      gate.complete(WorkshopPublishSources(values: [_source]));
      await pending;
      expect(container.read(workshopPublishSourcesProvider).values.single.kind, 'companion');
    } finally {
      if (!gate.isCompleted) gate.complete(WorkshopPublishSources());
      await settled;
      container.dispose();
    }
  });

  test('preparation owns a fresh private directory and cleanup leaves siblings intact', () async {
    final root = await Directory.systemTemp.createTemp('workshop-prepare-test-');
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async => root),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      final sibling = File('${root.path}/keep.txt')..writeAsStringSync('keep');
      final draft = await container.read(workshopPrepareDraftProvider)(_source, _input().publication('pet'));
      expect(repository.selected, 'user-cat');
      expect(draft.directoryName, matches(r'^draft-[A-Za-z0-9_-]{1,100}$'));
      expect(await draft.upload.file.exists(), isTrue);
      expect(draft.upload.metadata.id, 'cat');
      expect(draft.upload.files, ['pack.json', 'idle.png']);
      await draft.dispose();
      await draft.dispose();
      expect(await draft.upload.file.parent.exists(), isFalse);
      expect(sibling.readAsStringSync(), 'keep');
    } finally {
      container.dispose();
      await root.delete(recursive: true);
    }
  });

  test('companion preparation omits private name and persona arguments', () async {
    final root = await Directory.systemTemp.createTemp('workshop-companion-prepare-test-');
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async => root),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      final draft = await container.read(workshopPrepareDraftProvider)(
        const WorkshopPublishSource(kind: 'companion', localId: 'companion', name: 'Private nickname'),
        _input().publication('companion'));
      expect(repository.selected, 'companion');
      expect(repository.name, isNull);
      expect(repository.persona, isNull);
      expect(repository.preview, isNull);
      await draft.dispose();
    } finally { container.dispose(); await root.delete(recursive: true); }
  });

  test('explicit companion PNG and mode reach the same preparation call', () async {
    final root = await Directory.systemTemp.createTemp('workshop-preview-source-test-');
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async => root),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      final preview = WorkshopPreviewInput.companionPng(workshopPng(2, 1));
      final source = const WorkshopPublishSource(kind: 'companion', localId: 'companion').withPreview(preview);
      final draft = await container.read(workshopPrepareDraftProvider)(source,
        _input().publication('companion', previewSource: source.previewSource));
      expect(repository.preview, same(preview));
      expect(draft.upload.metadata.previewSource, 'companion-preview');
      expect(repository.name, isNull);
      expect(repository.persona, isNull);
      await draft.dispose();
    } finally { container.dispose(); await root.delete(recursive: true); }
  });

  test('source mode mismatch is rejected before owning a draft directory', () async {
    var directoryReads = 0;
    final repository = _Repository();
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async {
        directoryReads++;
        throw StateError('A mismatched source must not request storage');
      }),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      final prepare = container.read(workshopPrepareDraftProvider);
      await expectLater(prepare(_source.withPreview(const WorkshopPreviewInput.petIdle()), _input().publication('pet')),
        throwsA(isA<WorkshopException>().having((error) => error.code, 'code', 'workshop_bad_metadata')));
      final wrongKind = const WorkshopPublishSource(kind: 'companion', localId: 'companion',
        preview: WorkshopPreviewInput.petIdle());
      await expectLater(prepare(wrongKind, _input().publication('companion')),
        throwsA(isA<WorkshopException>().having((error) => error.code, 'code', 'workshop_bad_metadata')));
      expect(repository.selected, isNull);
      expect(directoryReads, 0);
    } finally { container.dispose(); }
  });

  test('failed preparation removes its own partial output and keeps the original stable error', () async {
    final root = await Directory.systemTemp.createTemp('workshop-failed-prepare-test-');
    final repository = _Repository()..fail = true;
    final container = ProviderContainer(overrides: [
      workshopRepositoryProvider.overrideWith((ref) async => repository),
      workshopDirectoryProvider.overrideWithValue(() async => root),
      petLibraryProvider.overrideWithValue(_Pets()),
      companionFloatStoreProvider.overrideWithValue(() async => _Companion()),
    ]);
    try {
      await expectLater(container.read(workshopPrepareDraftProvider)(_source, _input().publication('pet')),
        throwsA(isA<WorkshopException>().having((error) => error.code, 'code', 'workshop_no_space')));
      expect(await Directory('${root.path}/exports').list().toList(), isEmpty);
    } finally { container.dispose(); await root.delete(recursive: true); }
  });

  test('restoring a retained journal does no preparation and works before local file availability is known', () async {
    final root = await Directory.systemTemp.createTemp('workshop-restore-test-');
    final container = ProviderContainer(overrides: [
      workshopDirectoryProvider.overrideWithValue(() async => root),
    ]);
    try {
      final pending = WorkshopPendingSubmission(requestId: 'a' * 32, fingerprint: 'b' * 64,
        directoryName: 'draft-original', metadata: _input().publication('pet').withArchive('c' * 64, 4),
        files: const ['pack.json']);
      final restored = await container.read(workshopRestoreDraftProvider)(pending);
      expect(restored.retained, isTrue);
      expect(await restored.upload.file.exists(), isFalse);
      expect(restored.upload.metadata.toJson(), pending.metadata.toJson());
      await restored.upload.file.parent.create(recursive: true);
      await restored.upload.file.writeAsBytes([1, 2, 3, 4]);
      await restored.dispose();
      expect(await restored.upload.file.exists(), isTrue);
      restored.retained = false;
      await restored.dispose();
      expect(await restored.upload.file.parent.exists(), isFalse);
    } finally { container.dispose(); await root.delete(recursive: true); }
  });

  test('restore rejects a non-private basename before requesting the storage root', () async {
    var rootReads = 0;
    final container = ProviderContainer(overrides: [
      workshopDirectoryProvider.overrideWithValue(() async { rootReads++; return Directory('unused-root'); }),
    ]);
    try {
      final invalid = WorkshopPendingSubmission(requestId: 'a' * 32, fingerprint: 'b' * 64,
        directoryName: 'outside/child', metadata: _input().publication('pet').withArchive('c' * 64, 4), files: []);
      await expectLater(container.read(workshopRestoreDraftProvider)(invalid),
        throwsA(isA<WorkshopException>().having((error) => error.code, 'code', 'workshop_preferences')));
      expect(rootReads, 0);
    } finally { container.dispose(); }
  });

  test('overlapping cleanup coalesces and failed cleanup remains retryable', () async {
    final gate = Completer<void>();
    var calls = 0;
    final draft = WorkshopPreparedDraft(directoryName: 'draft-test',
      upload: WorkshopPreparedUpload(file: File('unused-test-archive'),
        metadata: _input().publication('pet').withArchive('a' * 64, 4), files: []),
      cleanup: () async { if (++calls == 1) await gate.future; });
    final first = draft.dispose(), second = draft.dispose();
    final settled = Future.wait([first, second]).then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    try {
      expect(identical(first, second), isTrue);
      gate.completeError(const WorkshopException('workshop_storage'));
      await expectLater(first, throwsA(isA<WorkshopException>()));
      await settled;
      expect(calls, 1);
      await draft.dispose();
      await draft.dispose();
      expect(calls, 2);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await settled;
    }
  });

  test('a synchronously failing cleanup callback can be retried', () async {
    var calls = 0;
    final draft = WorkshopPreparedDraft(directoryName: 'draft-sync-cleanup',
      upload: WorkshopPreparedUpload(file: File('unused-test-archive'),
        metadata: _input().publication('pet').withArchive('a' * 64, 4), files: []),
      cleanup: () {
        if (++calls == 1) throw const WorkshopException('workshop_storage');
        return Future<void>.value();
      });
    await expectLater(draft.dispose(), throwsA(isA<WorkshopException>()));
    await draft.dispose();
    await draft.dispose();
    expect(calls, 2);
  });
}
