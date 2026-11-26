import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _name = 'dsh-go-1.2.0-arm64.apk';
const _manifest = 'https://github.com/ccch1mneyyy/dsh-go/releases/latest/download/update.json';
const _asset = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_name';
final _bytes = utf8.encode('PK fixed startup-cleanup regression payload');

Map<String, Object?> _release({String version = '1.2.0'}) => {
  'schema': 1,
  'version': version,
  'tag': 'v$version',
  'assets': {
    'arm64': {'name': _name, 'size': _bytes.length, 'sha256': sha256.convert(_bytes).toString()},
  },
};

/// Holds only the startup directory walk. Once released, it enumerates the
/// real directory, and the real cleaner deletes its entries normally.
/// Subsequent directory lookups return the actual directory straight away.
class _HeldCleanup implements Directory {
  _HeldCleanup(this.actual);

  final Directory actual;
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  bool fail = false;

  @override
  String get path => actual.path;

  @override
  Future<bool> exists() => actual.exists();

  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    entered.complete();
    await release.future;
    try {
      if (fail) throw FileSystemException('fixed cleanup failure', path);
      yield* actual.list(recursive: recursive, followLinks: followLinks);
    } finally {
      finished.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rig {
  _Rig({String? cachedVersion, bool holdCleanup = true}) {
    SharedPreferences.setMockInitialValues({
      if (cachedVersion != null) 'update_latest': jsonEncode(_release(version: cachedVersion)),
    });
    cleanup = _HeldCleanup(directory);
    http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
    http.routes[_asset] = fileRoute(_bytes);
    container = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(FakeInstaller()),
        updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [UpdateMirror.github])),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async {
          directoryReads++;
          return holdCleanup && directoryReads == 1 ? cleanup : directory;
        }),
      ],
    );
    controller = container.read(appUpdateProvider.notifier);
    addTearDown(() {
      if (!cleanup.release.isCompleted) cleanup.release.complete();
      container.dispose();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
  }

  final directory = Directory.systemTemp.createTempSync('update-startup-cleanup-');
  final http = FakeHttp();
  late final _HeldCleanup cleanup;
  late final ProviderContainer container;
  late final AppUpdateController controller;
  int directoryReads = 0;

  AppUpdateState get state => container.read(appUpdateProvider);
  File get apk => File('${directory.path}/$_name');

  Future<void> checkAndDownload() async {
    await controller.check();
    await controller.startDownload();
  }
}

// The preferences, fake manifest and native-info replies have only microtask
// continuations before the next directory lookup. No wall-clock timer is used.
Future<void> _drainMicrotasks() async {
  for (var i = 0; i < 64; i++) {
    await Future<void>.value();
  }
}

void main() {
  for (final cachedVersion in <String?>[null, '1.0.0']) {
    test('startup cleanup cannot erase a new verified APK; cached=$cachedVersion', () async {
      final r = _Rig(cachedVersion: cachedVersion);
      await r.cleanup.entered.future;
      final downloading = r.checkAndDownload();
      await _drainMicrotasks();

      // Exercise the destructive ordering if the old cleanup permits it:
      // finish the real download/hash before releasing the old directory
      // walk. A serialized controller has not asked for a download directory
      // yet, so its cleanup can finish first and then unblock the download.
      if (r.directoryReads > 1) {
        await downloading;
        expect(r.state.task, UpdateTaskPhase.ready);
        expect(r.apk.readAsBytesSync(), _bytes);
      }
      r.cleanup.release.complete();
      await r.cleanup.finished.future;
      await downloading;

      expect(r.state.task, UpdateTaskPhase.ready);
      expect(r.apk.existsSync(), isTrue, reason: 'the old startup walk must not delete the newly verified APK');
      expect(r.apk.readAsBytesSync(), _bytes);
      expect(_httpDownloads(r), hasLength(1));
    });
  }

  test('startup still removes obsolete downloads when no new offer is requested', () async {
    final r = _Rig(cachedVersion: '1.0.0');
    final obsolete = File('${r.directory.path}/obsolete.apk')..writeAsBytesSync([1, 2, 3]);
    await r.cleanup.entered.future;
    r.cleanup.release.complete();
    await r.cleanup.finished.future;
    await r.controller.ready;

    expect(obsolete.existsSync(), isFalse);
    expect(r.state.loaded, isTrue);
    expect(r.state.hasUpdate, isFalse);
    expect(r.http.requests, isEmpty);
  });

  test('a newer cached APK can be verified and reused after an offline restart and refresh', () async {
    final r = _Rig(cachedVersion: '1.2.0', holdCleanup: false);
    r.apk.writeAsBytesSync(_bytes);
    await r.controller.ready;
    expect(r.directoryReads, 0);
    expect(r.state.apkHere, isFalse, reason: 'the cached APK has not been verified in this process');
    r.http.routes.clear();
    expect(await r.controller.check(), UpdateCheckPhase.available);
    expect(r.state.checkFailure, isNotNull);
    await r.controller.startDownload();

    expect(r.state.task, UpdateTaskPhase.ready);
    expect(r.state.apkHere, isTrue);
    expect(r.apk.readAsBytesSync(), _bytes);
    expect(_httpDownloads(r), isEmpty, reason: 'the cached APK is rehashed and reused without a download');
  });

  test('best-effort cleanup failure still permits a later download', () async {
    final r = _Rig();
    r.cleanup.fail = true;
    await r.cleanup.entered.future;
    r.cleanup.release.complete();
    await r.cleanup.finished.future;
    await r.controller.ready;
    await r.checkAndDownload();

    expect(r.state.task, UpdateTaskPhase.ready);
    expect(r.apk.readAsBytesSync(), _bytes);
    expect(_httpDownloads(r), hasLength(1));
  });

  test('disposal while startup cleanup waits does not adopt a late initial state', () async {
    final r = _Rig();
    await r.cleanup.entered.future;
    final ready = r.controller.ready;
    r.container.dispose();
    r.cleanup.release.complete();
    await r.cleanup.finished.future;
    await ready;

    expect(r.http.requests, isEmpty);
    expect(r.directoryReads, 1);
  });
}

Iterable<String> _httpDownloads(_Rig r) => r.http.urls.where((url) => url == _asset);
