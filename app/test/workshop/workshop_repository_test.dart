import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart' show PetImportException, PetImportProblem;
import 'package:dsh_app/update/update_http.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_receipt.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../update/support.dart' show fileRoute;
import 'support.dart';

/// Fires the actual downloader's idle callback without waiting 30 wall seconds.
/// Other timers and real temporary-file IO keep their ordinary behavior.
class _ManualTimer implements Timer {
  _ManualTimer(this._callback);
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;
  @override bool get isActive => _active;
  @override int get tick => _tick;
  @override void cancel() => _active = false;
  void fire() {
    if (!_active) throw StateError('test timer is inactive');
    _active = false;
    _tick = 1;
    _callback();
  }
}

class _Packages implements WorkshopPackages {
  final items = <WorkshopInstalled>[];
  final calls = <String>[];
  Object? failure;
  Future<void> Function()? beforeInstall;
  @override
  Future<List<WorkshopInstalled>> installed() async => List.of(items);
  @override
  Future<int> copyOverhead(String kind) async => 0;
  @override
  Future<WorkshopInstalled> install(File archive, WorkshopReceipt receipt, {required bool replaceExisting}) async {
    calls.add('install');
    await beforeInstall?.call();
    if (failure != null) throw failure!;
    final item = WorkshopInstalled(localId: 'user-${receipt.id}', receipt: receipt);
    items.add(item);
    return item;
  }
  @override
  Future<void> remove(WorkshopInstalled item) async { calls.add('remove'); items.remove(item); }
}

void main() {
  late Directory temp;
  late FakeWorkshopHttp http;
  late WorkshopClient client;
  late _Packages packages;
  late WorkshopRepository repository;
  late WorkshopEntry entry;
  final bytes = List.generate(20, (i) => i);
  setUp(() {
    temp = Directory.systemTemp.createTempSync('workshop-download');
    entry = WorkshopEntry.fromJson(workshopEntryJson(metadata: workshopMeta(bytes: bytes)));
    http = FakeWorkshopHttp((_, url, headers, _) => url.path.endsWith('.json') ?
      workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) : fileRoute(bytes)(url, headers));
    client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http);
    packages = _Packages();
    repository = WorkshopRepository(client: client, packages: packages, downloadDirectory: Directory('${temp.path}/downloads'),
      appVersion: '1.0.15+123', freeBytes: () async => 1024 * 1024 * 1024);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('resume uses the existing downloader and installs only after a second fresh catalog', () async {
    await repository.downloadDirectory.create();
    File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip.part').writeAsBytesSync(bytes.sublist(0, 8));
    final offsets = <int?>[];
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      fileRoute(bytes, onRequest: offsets.add)(url, headers);
    final installed = await repository.install(entry);
    expect(offsets, [8]);
    expect(installed.receipt.sha256, entry.metadata.sha256);
    expect(packages.calls, ['install']);
    expect(http.requests.where((r) => r.url.path.endsWith('/workshop.json')), hasLength(2));
  });

  test('a dropped stream resumes the exact same content addressed URL', () async {
    final offsets = <int?>[];
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      fileRoute(bytes, dropAfter: 8, onRequest: offsets.add)(url, headers);
    await repository.install(entry);
    expect(offsets, [null, 8, 16]);
    expect(packages.calls, ['install']);
  });

  for (final offset in [0, 8]) {
    test('cancel while a ${offset == 0 ? 200 : 206} body is idle reaches upstream and preserves resume bytes', () async {
      await repository.downloadDirectory.create();
      final part = File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip.part');
      if (offset > 0) part.writeAsBytesSync(bytes.sublist(0, offset));
      final cancel = CancelToken();
      final sent = Completer<void>();
      var upstreamCancelled = false, wasListening = false;
      late final StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onListen: () {
          wasListening = true;
          scheduleMicrotask(() {
            if (body.isClosed) return;
            body.add(bytes.sublist(offset, offset + 4));
            sent.complete();
          });
        },
        onCancel: () { upstreamCancelled = true; },
      );
      http.route = (_, url, _, _) => url.path.endsWith('.json') ?
        workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
        UpdateHttpResponse(status: offset == 0 ? 200 : 206,
          headers: {if (offset > 0) 'content-range': 'bytes $offset-19/20'},
          contentLength: bytes.length - offset, body: body.stream);
      final pending = repository.install(entry, cancel: cancel);
      final settled = pending.then<void>((_) {}, onError: (Object _) {});
      try {
        await Future.any<void>([
          sent.future,
          pending.then<void>((_) => fail('installation ended before the body sent its first bytes')),
        ]).timeout(const Duration(seconds: 10));
        // Let the first event and all of its microtasks finish. No second
        // event or stream close is sent before checking cancellation.
        await Future<void>.delayed(Duration.zero);
        cancel.cancel();
        await expectLater(pending.timeout(const Duration(seconds: 10)), workshopError('workshop_cancelled'));
        expect(upstreamCancelled, isTrue, reason: 'an idle network body must not wait for its next data event');
        expect(part.readAsBytesSync(), bytes.sublist(0, offset + 4));
        expect(packages.calls, isEmpty);
        expect(await repository.installed(), isEmpty, reason: 'the shared repository queue is released');

        final offsets = <int?>[];
        http.route = (_, url, headers, _) => url.path.endsWith('.json') ?
          workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
          fileRoute(bytes, onRequest: offsets.add)(url, headers);
        await repository.install(entry);
        expect(offsets, [offset + 4]);
        expect(packages.calls, ['install']);
        expect(File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip').readAsBytesSync(), bytes);
      } finally {
        cancel.cancel();
        final closing = body.close();
        await settled;
        if (wasListening) await closing;
      }
    });
  }

  test('idle timeout cancels the stalled HTTP body before resuming its partial file', () async {
    final cancel = CancelToken();
    final idleArmed = Completer<void>();
    var listening = false, upstreamCancelled = false, captureIdle = true;
    _ManualTimer? idle;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () {
        listening = true;
        scheduleMicrotask(() {
          if (body.isClosed) return;
          body.add(bytes.sublist(0, 4));
        });
      },
      onCancel: () { upstreamCancelled = true; },
    );
    final offsets = <int?>[];
    var archives = 0;
    http.route = (_, url, headers, _) {
      if (url.path.endsWith('.json')) return workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()]));
      if (archives++ == 0) {
        offsets.add(null);
        return UpdateHttpResponse(status: 200, contentLength: bytes.length, body: body.stream);
      }
      return fileRoute(bytes, onRequest: offsets.add)(url, headers);
    };
    final pending = runZoned(() => repository.install(entry, cancel: cancel), zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (captureIdle && listening && duration == const Duration(seconds: 30)) {
          final timer = _ManualTimer(() => zone.runGuarded(callback));
          idle = timer;
          if (!idleArmed.isCompleted) idleArmed.complete();
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ));
    final settled = pending.then<void>((_) {}, onError: (Object _) {});
    try {
      await Future.any<void>([
        idleArmed.future,
        pending.then<void>((_) => fail('installation ended before the idle timer was armed')),
      ]).timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      captureIdle = false;
      expect(idle!.isActive, isTrue);
      idle!.fire();
      await Future<void>.delayed(Duration.zero);
      expect(upstreamCancelled, isTrue, reason: 'timeout cannot wait for a data event to propagate cancel');
      final installed = await pending.timeout(const Duration(seconds: 10));
      expect(offsets, [null, 4]);
      expect(installed.receipt.sha256, entry.metadata.sha256);
      expect(packages.calls, ['install']);
      expect(File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip').readAsBytesSync(), bytes);
    } finally {
      captureIdle = false;
      cancel.cancel();
      final closing = body.close();
      await settled;
      if (listening) await closing;
    }
  });

  test('one resume slot prunes only workshop digest files', () async {
    await repository.downloadDirectory.create();
    final home = repository.downloadDirectory.path;
    final old = File('$home/${'a' * 64}.zip')..writeAsBytesSync([1]);
    final oldPart = File('${old.path}.part')..writeAsBytesSync([2]);
    final unrelated = File('$home/keep.txt')..writeAsStringSync('keep');
    final directory = Directory('$home/${'b' * 64}.zip')..createSync();
    File('${directory.path}/keep').writeAsStringSync('keep');
    final current = File('$home/${entry.metadata.sha256}.zip.part')..writeAsBytesSync(bytes.sublist(0, 8));
    final offsets = <int?>[];
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      fileRoute(bytes, onRequest: offsets.add)(url, headers);
    await repository.install(entry);
    expect(offsets, [8]);
    expect(old.existsSync(), isFalse);
    expect(oldPart.existsSync(), isFalse);
    expect(unrelated.readAsStringSync(), 'keep');
    expect(File('${directory.path}/keep').readAsStringSync(), 'keep');
    expect(current.existsSync(), isFalse, reason: 'the verified part was renamed to its complete ZIP');
  });

  test('repositories sharing a cache root cannot prune an active installer archive', () async {
    final otherBytes = bytes.reversed.toList();
    final otherEntry = WorkshopEntry.fromJson(workshopEntryJson(metadata: workshopMeta(id: 'dog', bytes: otherBytes)));
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson(), otherEntry.toJson()])) :
      fileRoute(url.path == entry.metadata.archivePath ? bytes : otherBytes)(url, headers);
    final entered = Completer<void>(), release = Completer<void>();
    packages.beforeInstall = () async {
      if (!entered.isCompleted) { entered.complete(); await release.future; }
    };
    final first = repository.install(entry);
    final firstSettled = first.then<void>((_) {}, onError: (Object _) {});
    Future<void>? secondSettled;
    try {
      await entered.future;
      final other = WorkshopRepository(client: client, packages: packages,
        downloadDirectory: Directory('${repository.downloadDirectory.path}/'), appVersion: '1.0.15', freeBytes: () async => 1024 * 1024 * 1024);
      final second = other.install(otherEntry);
      secondSettled = second.then<void>((_) {}, onError: (Object _) {});
      await Future<void>.delayed(Duration.zero);
      expect(http.requests.where((r) => r.url.path.endsWith('.zip')), hasLength(1));
      expect(File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip').existsSync(), isTrue);
      release.complete();
      await first;
      await second;
      expect(packages.calls, ['install', 'install']);
      expect(File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip').existsSync(), isFalse);
      expect(File('${repository.downloadDirectory.path}/${otherEntry.metadata.sha256}.zip').existsSync(), isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      await firstSettled;
      if (secondSettled != null) await secondSettled;
    }
  });

  test('a checksum mismatch never reaches the installer', () async {
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      fileRoute(List.filled(bytes.length, 99))(url, headers);
    await expectLater(repository.install(entry), workshopError('workshop_sha_mismatch'));
    expect(packages.calls, isEmpty);
  });

  test('body exceeding known size is bounded even without content-length', () async {
    http.route = (_, url, _, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      UpdateHttpResponse(status: 200, body: Stream.value([...bytes, 99]));
    await expectLater(repository.install(entry), workshopError('workshop_size_mismatch'));
    expect(packages.calls, isEmpty);
  });

  test('a wrong Content-Range cannot append to a partial file', () async {
    await repository.downloadDirectory.create();
    final part = File('${repository.downloadDirectory.path}/${entry.metadata.sha256}.zip.part')..writeAsBytesSync(bytes.sublist(0, 8));
    http.route = (_, url, _, _) => url.path.endsWith('.json') ? workshopJsonResponse(workshopCatalogJson(entries: [entry.toJson()])) :
      UpdateHttpResponse(status: 206, headers: {'content-range': 'bytes 0-19/20'}, contentLength: 20, body: Stream.value(bytes));
    await expectLater(repository.install(entry), workshopError('workshop_download_range'));
    expect(part.readAsBytesSync(), bytes.sublist(0, 8));
    expect(packages.calls, isEmpty);
  });

  test('low-space preflight fails before a ZIP is requested', () async {
    repository = WorkshopRepository(client: client, packages: packages, downloadDirectory: repository.downloadDirectory,
      appVersion: '1.0.15', freeBytes: () async => 1);
    await expectLater(repository.install(entry), workshopError('workshop_no_space'));
    expect(http.requests.where((r) => r.url.path.endsWith('.zip')), isEmpty);
    expect(packages.calls, isEmpty);
  });

  test('the real disabled companion projection reports shutdown before missing entry', () async {
    final companion = WorkshopEntry.fromJson(workshopEntryJson(metadata: workshopMeta(kind: 'companion', bytes: bytes)));
    packages.items.add(WorkshopInstalled(localId: 'companion', receipt: WorkshopReceipt(kind: 'companion', id: 'cat',
      version: '1.0.0', sha256: companion.metadata.sha256, origin: workshopTestOrigin)));
    final catalogJson = workshopCatalogJson(entries: [], companion: false, withdrawn: [
      {'kind': 'companion', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate},
    ]);
    http.route = (_, _, _, _) => workshopJsonResponse(catalogJson);
    await expectLater(repository.install(companion), workshopError('workshop_companion_disabled'));
    expect(http.requests.where((r) => r.url.path.endsWith('.zip')), isEmpty);
    expect(packages.calls, isEmpty);
    final state = (await repository.installedStates(WorkshopCatalog.fromJson(catalogJson))).single;
    expect(state.unavailable, 'workshop_companion_disabled');
    expect(state.installedWithdrawn, isTrue);
    await repository.uninstall(state.installed);
    expect(packages.calls, ['remove']);
  });

  test('withdrawal during download prevents installation of the cached bytes', () async {
    var catalogs = 0;
    http.route = (_, url, headers, _) {
      if (!url.path.endsWith('.json')) return fileRoute(bytes)(url, headers);
      catalogs++;
      return workshopJsonResponse(workshopCatalogJson(entries: catalogs == 1 ? [entry.toJson()] : [], withdrawn: catalogs == 1 ? [] : [
        {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate},
      ]));
    };
    await expectLater(repository.install(entry), workshopError('workshop_version_withdrawn'));
    expect(packages.calls, isEmpty);
  });

  test('cancellation during hash verification never starts installation', () async {
    final cancel = CancelToken();
    await expectLater(repository.install(entry, cancel: cancel, onVerifying: cancel.cancel), workshopError('workshop_cancelled'));
    expect(packages.calls, isEmpty);
  });

  test('a withdrawal accepted during the final space query prevents installer handoff', () async {
    final entered = Completer<void>(), release = Completer<int?>();
    var spaces = 0;
    var catalog = workshopCatalogJson(entries: [entry.toJson()]);
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ?
      workshopJsonResponse(catalog) : fileRoute(bytes)(url, headers);
    repository = WorkshopRepository(client: client, packages: packages, downloadDirectory: repository.downloadDirectory,
      appVersion: '1.0.15', freeBytes: () {
        if (++spaces == 2) {
          entered.complete();
          return release.future;
        }
        return Future.value(1024 * 1024 * 1024);
      });
    final otherHttp = FakeWorkshopHttp((_, _, _, _) => workshopJsonResponse(catalog));
    final other = WorkshopClient(origin: workshopTestOrigin,
      cacheFile: File('${temp.path}/./catalog.json'), http: otherHttp);
    final cancel = CancelToken();
    final pending = repository.install(entry, cancel: cancel);
    final settled = pending.then<void>((_) {}, onError: (Object _) {});
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      catalog = workshopCatalogJson(entries: [], at: '2026-11-11T00:00:01.000Z', withdrawn: [
        {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'author withdrew', 'at': '2026-11-11T00:00:01.000Z'},
      ]);
      final accepted = await other.catalog(requireFresh: true);
      expect(accepted.catalog.blocked('pet', 'cat', '1.0.0'), isTrue);
      expect(packages.calls, isEmpty);
      // Both clients now receive C2. This isolates the space-query gap from
      // a stale-response/rollback failure in the subsequent fresh request.
      release.complete(1024 * 1024 * 1024);
      await expectLater(pending.timeout(const Duration(seconds: 10)), workshopError('workshop_version_withdrawn'));
      expect(packages.calls, isEmpty);
      expect(spaces, 2);
      expect(http.requests.where((r) => r.url.path.endsWith('/workshop.json')), hasLength(2));
      expect(otherHttp.requests, hasLength(1));
    } finally {
      cancel.cancel();
      if (!release.isCompleted) release.complete(1024 * 1024 * 1024);
      await settled;
      other.close();
    }
  });

  test('final low space takes precedence over a newly withdrawn catalog', () async {
    var catalogs = 0, spaces = 0;
    http.route = (_, url, headers, _) {
      if (!url.path.endsWith('.json')) return fileRoute(bytes)(url, headers);
      return workshopJsonResponse(++catalogs == 1 ? workshopCatalogJson(entries: [entry.toJson()]) :
        workshopCatalogJson(entries: [], at: '2026-11-11T00:00:01.000Z', withdrawn: [
          {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'author withdrew', 'at': '2026-11-11T00:00:01.000Z'},
        ]));
    };
    repository = WorkshopRepository(client: client, packages: packages, downloadDirectory: repository.downloadDirectory,
      appVersion: '1.0.15', freeBytes: () async => ++spaces == 1 ? 1024 * 1024 * 1024 : 0);
    await expectLater(repository.install(entry), workshopError('workshop_no_space'));
    expect(spaces, 2);
    expect(catalogs, 1, reason: 'insufficient space stops before the final network revalidation');
    expect(packages.calls, isEmpty);
  });

  test('a withdrawal after installer handoff does not revoke an installation in flight', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var catalog = workshopCatalogJson(entries: [entry.toJson()]);
    http.route = (_, url, headers, _) => url.path.endsWith('.json') ?
      workshopJsonResponse(catalog) : fileRoute(bytes)(url, headers);
    packages.beforeInstall = () async {
      entered.complete();
      await release.future;
    };
    final other = WorkshopClient(origin: workshopTestOrigin,
      cacheFile: File('${temp.path}/./catalog.json'),
      http: FakeWorkshopHttp((_, _, _, _) => workshopJsonResponse(catalog)));
    final pending = repository.install(entry);
    final settled = pending.then<void>((_) {}, onError: (Object _) {});
    try {
      await entered.future.timeout(const Duration(seconds: 10));
      catalog = workshopCatalogJson(entries: [], at: '2026-11-11T00:00:01.000Z', withdrawn: [
        {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'author withdrew', 'at': '2026-11-11T00:00:01.000Z'},
      ]);
      expect((await other.catalog(requireFresh: true)).catalog.blocked('pet', 'cat', '1.0.0'), isTrue);
      expect(packages.calls, ['install']);
      release.complete();
      final installed = await pending.timeout(const Duration(seconds: 10));
      expect(installed.receipt.version, '1.0.0');
      expect(installed.receipt.sha256, entry.metadata.sha256);
      await expectLater(repository.install(entry), workshopError('workshop_version_withdrawn'));
      expect(packages.calls, ['install'], reason: 'the later withdrawal blocks the next installation');
    } finally {
      if (!release.isCompleted) release.complete();
      await settled;
      other.close();
    }
  });

  test('offline browsing may use cache but offline installation cannot', () async {
    await client.catalog();
    http.route = (_, _, _, _) => throw const SocketException('offline');
    expect((await client.catalog()).stale, isTrue);
    await expectLater(repository.install(entry), workshopError('workshop_network'));
    expect(packages.calls, isEmpty);
  });

  test('installed withdrawn status and a newer available update coexist', () async {
    final old = WorkshopReceipt(kind: 'pet', id: 'cat', version: '1.0.0', sha256: entry.metadata.sha256, origin: workshopTestOrigin);
    packages.items.add(WorkshopInstalled(localId: 'user-cat', receipt: old));
    final next = workshopEntryJson(metadata: workshopMeta(version: '1.1.0', bytes: bytes), blocked: ['1.0.0']);
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [next]));
    final state = (await repository.states(catalog)).single;
    expect(state.installed, isNotNull);
    expect(state.installedWithdrawn, isTrue);
    expect(state.updateAvailable, isTrue);
    expect(state.unavailable, isNull);
  });

  test('uninstall is offline and targets the observed installation receipt', () async {
    final installed = WorkshopInstalled(localId: 'user-cat', receipt: WorkshopReceipt(kind: 'pet', id: 'cat', version: '1.0.0', sha256: entry.metadata.sha256, origin: workshopTestOrigin));
    packages.items.add(installed);
    await repository.uninstall(installed);
    expect(packages.items, isEmpty);
    expect(packages.calls, ['remove']);
    expect(http.requests, isEmpty);
  });

  test('installed withdrawn resources remain listed after their public entry is gone', () async {
    final item = WorkshopInstalled(localId: 'user-cat', receipt: WorkshopReceipt(kind: 'pet', id: 'cat',
      version: '1.0.0', sha256: entry.metadata.sha256, origin: workshopTestOrigin));
    packages.items.add(item);
    final catalog = WorkshopCatalog.fromJson(workshopCatalogJson(entries: [], withdrawn: [
      {'kind': 'pet', 'id': 'cat', 'version': '1.0.0', 'reason': 'withdrawn', 'at': workshopTestDate},
    ]));
    expect(await repository.states(catalog), isEmpty);
    final state = (await repository.installedStates(catalog)).single;
    expect(state.installed, item);
    expect(state.entry, isNull);
    expect(state.installedWithdrawn, isTrue);
    expect(state.updateAvailable, isFalse);
    expect(state.unavailable, 'workshop_version_withdrawn');
    await repository.uninstall(state.installed);
    expect(packages.items, isEmpty);
    expect(http.requests, isEmpty);
  });

  test('a real ENOSPC from installation is not reported as a network failure', () async {
    packages.failure = const FileSystemException('write failed', '/private/path', OSError('no space', 28));
    await expectLater(repository.install(entry), workshopError('workshop_no_space'));
  });

  test('package validation membership follows the real local mapper and its detail priority', () {
    for (final problem in PetImportProblem.values) {
      final code = workshopLocalError(PetImportException(problem)).code;
      expect(workshopPackageValidationCodes.contains(code), problem != PetImportProblem.storage,
        reason: 'PetImportProblem.${problem.name}: $code');
    }
    for (final problem in CompanionPackProblem.values) {
      final code = workshopLocalError(CompanionPackException(problem)).code;
      expect(workshopPackageValidationCodes.contains(code),
        problem != CompanionPackProblem.storage && problem != CompanionPackProblem.noRuntime,
        reason: 'CompanionPackProblem.${problem.name}: $code');
    }
    for (final (error, expected, recognized) in const [
      (CompanionPackException(CompanionPackProblem.storage, 'companion_bad_json'),
        'workshop_companion_bad_json', true),
      (CompanionPackException(CompanionPackProblem.noRuntime, 'companion_bad_json'),
        'workshop_runtime_missing', false),
      (CompanionPackException(CompanionPackProblem.notAPack, 'companion_readers_busy'),
        'workshop_readers_busy', false),
      (CompanionPackException(CompanionPackProblem.notAPack, 'companion_future'),
        'workshop_companion_future', false),
      (PetImportException(PetImportProblem.storage, null, 28), 'workshop_no_space', false),
    ]) {
      final code = workshopLocalError(error).code;
      expect(code, expected);
      expect(workshopPackageValidationCodes.contains(code), recognized);
    }
  });

  test('non-validation and unknown codes do not become package failures by prefix', () {
    for (final code in [
      null,
      'workshop_companion_disabled',
      'workshop_preview_png',
      'workshop_install_record',
      'workshop_companion_storage',
      'workshop_companion_runtime_missing',
      'workshop_companion_export_exists',
      'workshop_pet_future',
      'companion_bad_json',
    ]) {
      expect(workshopPackageValidationCodes.contains(code), isFalse, reason: '$code');
    }
  });

  test('companion prepare applies the same full PNG gate as the Worker', () async {
    final store = CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest());
    final publication = WorkshopPublication(workshopMeta(kind: 'companion'));
    // Past the longest side a texture may have (#1328), and not a PNG at all.
    for (final texture in [workshopPng(companionTextureSide + 1, 1), <int>[1, 2, 3]]) {
      await store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter(), 'character/texture.png': texture}).path);
      expect(await store.installed(), isTrue, reason: 'the general local import acceptance is unchanged');
      final output = File('${temp.path}/bad-texture.zip');
      await expectLater(repository.prepareCompanion(store, output, publication), workshopError('workshop_companion_bad_png'));
      expect(workshopPackageValidationCodes.contains('workshop_companion_bad_png'), isTrue);
      expect(output.existsSync(), isFalse);
    }
    await store.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    final prepared = await repository.prepareCompanion(store, File('${temp.path}/valid-texture.zip'), publication);
    expect(prepared.files, contains('character/texture.png'));
    expect(prepared.metadata.sha256, isNotEmpty);
    expect(http.requests, isEmpty);
  });
}
