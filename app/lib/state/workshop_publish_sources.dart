import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../companion/companion_float.dart' show companionFloatStoreProvider;
import '../companion/companion_pack.dart';
import '../pets/pet_library.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_preview.dart';
import '../workshop/workshop_repository.dart';
import 'workshop_dependencies.dart';
import 'workshop_preferences.dart';
import 'workshop_publication.dart';

class WorkshopPublishSource {
  const WorkshopPublishSource({required this.kind, required this.localId,
    this.name, this.author, this.license, this.source, this.preview, this.library, this.store});
  final String kind, localId;
  final String? name, author, license, source;
  final WorkshopPreviewInput? preview;
  String? get previewSource => preview?.source;

  /// A picked file, unpacked on its own ([workshopFileStagerProvider]): the
  /// pet is packed from [library], the companion from [store], instead of
  /// the person's own.
  final PetLibrary? library;
  final CompanionPackStore? store;
  bool get fromFile => library != null || store != null;

  WorkshopPublishSource withPreview(WorkshopPreviewInput? value) => WorkshopPublishSource(
    kind: kind, localId: localId, name: name, author: author, license: license, source: source, preview: value,
    library: library, store: store);

  WorkshopPublicationInput initialInput() {
    final candidate = kind == 'pet' && localId.startsWith(userPetPrefix)
        ? localId.substring(userPetPrefix.length) : '';
    return WorkshopPublicationInput(id: workshopId(candidate) ? candidate : '',
      titleZh: kind == 'pet' ? name ?? '' : '', titleEn: kind == 'pet' ? name ?? '' : '',
      author: author ?? '', license: license ?? '', source: source ?? '');
  }
}

class WorkshopPublishSources {
  WorkshopPublishSources({List<WorkshopPublishSource> values = const [],
    Map<String, WorkshopException> issues = const {}, this.loading = false, this.generation = 0})
    : values = List.unmodifiable(values), issues = Map.unmodifiable(issues);
  final List<WorkshopPublishSource> values;
  final Map<String, WorkshopException> issues;
  final bool loading;
  final int generation;
}

final workshopSourcesLoaderProvider = Provider<Future<WorkshopPublishSources> Function()>((ref) {
  final pets = ref.watch(petLibraryProvider);
  final companion = ref.watch(companionFloatStoreProvider);
  return () async {
    final values = <WorkshopPublishSource>[], issues = <String, WorkshopException>{};
    try {
      for (final pet in await pets.list()) {
        values.add(WorkshopPublishSource(kind: 'pet', localId: pet.id, name: pet.name,
          author: pet.author, license: pet.license, source: pet.source));
      }
    } on Object catch (error) {
      issues['pet'] = workshopLocalError(error);
    }
    try {
      final store = await companion();
      if (await store.installed()) {
        final character = await store.character();
        values.add(WorkshopPublishSource(kind: 'companion', localId: 'companion',
          author: character.author, license: character.license, source: character.source));
      } else {
        issues['companion'] = const WorkshopException('workshop_companion_unavailable');
      }
    } on Object catch (error) {
      issues['companion'] = workshopLocalError(error);
    }
    return WorkshopPublishSources(values: values, issues: issues);
  };
});

class WorkshopPublishSourcesController extends Notifier<WorkshopPublishSources> {
  int _generation = 0, _request = 0;
  late Future<WorkshopPublishSources> Function() _loader;

  @override
  WorkshopPublishSources build() {
    _loader = ref.watch(workshopSourcesLoaderProvider);
    final generation = ++_generation, request = ++_request;
    final loader = _loader;
    unawaited(Future<void>.microtask(() => _read(generation, request, loader)));
    return WorkshopPublishSources(loading: true, generation: generation);
  }

  Future<void> refresh() async {
    final current = state;
    state = WorkshopPublishSources(values: current.values, issues: current.issues,
      loading: true, generation: current.generation);
    await _read(current.generation, ++_request, _loader);
  }

  bool _current(int generation, int request) => ref.mounted &&
      state.generation == generation && _request == request;

  Future<void> _read(int generation, int request, Future<WorkshopPublishSources> Function() loader) async {
    try {
      final found = await loader();
      if (_current(generation, request)) {
        state = WorkshopPublishSources(values: found.values, issues: found.issues, generation: generation);
      }
    } on Object catch (error) {
      if (_current(generation, request)) {
        state = WorkshopPublishSources(values: state.values,
          issues: {'all': workshopLocalError(error)}, generation: generation);
      }
    }
  }
}

final workshopPublishSourcesProvider = NotifierProvider<WorkshopPublishSourcesController, WorkshopPublishSources>(
  WorkshopPublishSourcesController.new,
);

/// The cleanup callback owns only the private directory created for this draft.
/// A persisted pending request retains it across page/account/app replacement.
class WorkshopPreparedDraft {
  WorkshopPreparedDraft({required this.upload, required this.directoryName, required this.cleanup});
  final WorkshopPreparedUpload upload;
  final String directoryName;
  final Future<void> Function() cleanup;
  bool retained = false;
  bool _disposed = false;
  Future<void>? _disposal;
  Future<void> dispose() {
    final inProgress = _disposal;
    if (inProgress != null) return inProgress;
    if (_disposed || retained) return Future<void>.value();
    // Assign before a caller-supplied cleanup can synchronously fail. Its
    // finally must clear the assigned Future so a later retry can run.
    return _disposal = Future<void>.microtask(_clean);
  }
  Future<void> _clean() async {
    try {
      await cleanup();
      _disposed = true;
    } finally {
      _disposal = null;
    }
  }
}

/// Unpacks a zip the person picked into a folder of its own, through the same
/// import as 导入 (a pet: pack.json or a Codex pet; a companion: a Live2D
/// model, with or without character.json), so a file that would not install
/// fails here, before the form. Nothing joins their pets, and the companion
/// they have stays: a character-only model borrows a copy of its runtime.
typedef WorkshopFileStager = Future<WorkshopPublishSource> Function(File zip);

final workshopFileStagerProvider = Provider<WorkshopFileStager>((ref) {
  final companion = ref.watch(companionFloatStoreProvider);
  return (zip) async {
    final root = await (await getTemporaryDirectory()).createTemp('workshop-file-');
    try {
      if (await _hasLive2DModel(zip)) {
        final store = CompanionPackStore(Directory('${root.path}/companion'));
        final runtime = Directory('${(await companion()).pack.path}/runtime');
        if (await runtime.exists()) await _copyTree(runtime, Directory('${store.pack.path}/runtime'));
        await store.install(zip.path);
        final character = await store.character();
        return WorkshopPublishSource(kind: 'companion', localId: 'file', name: character.name,
          author: character.author, license: character.license, source: character.source, store: store);
      }
      final library = PetLibrary(() async => Directory('${root.path}/pets'));
      final installed = await library.install(zip);
      final pack = await library.load(installed.id);
      return WorkshopPublishSource(kind: 'pet', localId: installed.id, name: pack.name,
        author: pack.author, license: pack.license, source: pack.source, library: library);
    } on Object {
      try { await root.delete(recursive: true); } on Object { /* The temporary folder goes with the cache. */ }
      rethrow;
    }
  };
});

Future<bool> _hasLive2DModel(File zip) async {
  final input = InputFileStream(zip.path);
  try {
    return ZipDecoder().decodeStream(input).files.any((f) => f.name.toLowerCase().endsWith('.model3.json'));
  } on Object {
    return false; // Not a zip: the pet import says so in its own words.
  } finally {
    await input.close();
  }
}

Future<void> _copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list(followLinks: false)) {
    final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (entity is Directory) {
      await _copyTree(entity, Directory('${to.path}/$name'));
    } else if (entity is File) {
      await entity.copy('${to.path}/$name');
    }
  }
}

typedef WorkshopPrepareDraft = Future<WorkshopPreparedDraft> Function(
  WorkshopPublishSource source, WorkshopPublication publication);
typedef WorkshopRestoreDraft = Future<WorkshopPreparedDraft> Function(WorkshopPendingSubmission pending);

final workshopPrepareDraftProvider = Provider<WorkshopPrepareDraft>((ref) {
  final repository = ref.watch(workshopRepositoryProvider.future);
  // The page can keep the prepare function before invoking it. Observe an
  // early factory failure now; invoking the function still reports that error.
  unawaited(repository.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
  final pets = ref.watch(petLibraryProvider);
  final companion = ref.watch(companionFloatStoreProvider);
  final directory = ref.watch(workshopDirectoryProvider);
  return (source, publication) async {
    Directory? owned;
    try {
      if (source.previewSource != publication.previewSource ||
          source.previewSource != null && source.previewSource != workshopPreviewSources[source.kind]) {
        workshopInvalid('workshop_bad_metadata');
      }
      final repo = await repository;
      final root = Directory('${(await directory()).path}/exports');
      await root.create(recursive: true);
      final draft = await root.createTemp('draft-');
      owned = draft;
      final file = File('${draft.path}/archive.zip');
      final WorkshopPreparedUpload upload;
      if (source.kind == 'pet') {
        upload = await repo.preparePet(source.library ?? pets, source.localId, file, publication);
      } else if (source.kind == 'companion' && (source.localId == 'companion' || source.store != null)) {
        // No personal name, persona, runtime, or private preference is passed.
        upload = await repo.prepareCompanion(source.store ?? await companion(), file, publication, preview: source.preview);
      } else {
        throw const WorkshopException('workshop_unsupported_kind');
      }
      return WorkshopPreparedDraft(upload: upload,
        directoryName: draft.uri.pathSegments.where((part) => part.isNotEmpty).last,
        cleanup: () async { if (await draft.exists()) await draft.delete(recursive: true); });
    } on Object catch (error) {
      final failed = owned;
      if (failed != null) {
        try { if (await failed.exists()) await failed.delete(recursive: true); } on Object { /* Keep the preparation error. */ }
      }
      throw workshopLocalError(error);
    }
  };
});

final workshopRestoreDraftProvider = Provider<WorkshopRestoreDraft>((ref) {
  final directory = ref.watch(workshopDirectoryProvider);
  return (pending) async {
    // Revalidate before deriving a private path; no absolute path is persisted.
    final checked = WorkshopPendingSubmission.fromJson(pending.toJson());
    final root = await directory();
    final draft = Directory('${root.path}/exports/${checked.directoryName}');
    return WorkshopPreparedDraft(
      upload: WorkshopPreparedUpload(file: File('${draft.path}/archive.zip'),
        metadata: checked.metadata, files: checked.files),
      directoryName: checked.directoryName,
      cleanup: () async { if (await draft.exists()) await draft.delete(recursive: true); },
    )..retained = true;
  };
});
