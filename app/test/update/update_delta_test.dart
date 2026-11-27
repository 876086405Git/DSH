// Delta updates in the app: the installed APK is hashed once per installed
// build; a patch from it is downloaded like the APK and builds the APK the
// install path then takes as before. Anything wrong with the patch falls back
// to the whole APK, silently and for good for that release. Offers without a
// patch for this APK, and old manifests without `patches`, work as before.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _version = '1.2.0+11011200';
const _apk = 'dsh-go-1.2.0-arm64.apk';
const _patchName = 'dsh-go-1.0.0-to-1.2.0-arm64.dshdlt';
const _feed = 'https://dl.dshtui.com/update.json';
const _dl = 'https://dl.dshtui.com/download/1.2.0';
const _github = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0';

final _old = utf8.encode('PK the installed 1.0.0, ${'resources ' * 300}${'classes ' * 300}');
final _new = [..._old.sublist(0, 2000), ...utf8.encode('the 1.2.0 code'), ..._old.sublist(2400)];
final _patch = deltaPatch(_old, _new, [
  deltaCopy(0, 2000),
  deltaData(utf8.encode('the 1.2.0 code')),
  deltaCopy(2400, _old.length - 2400),
  deltaEnd,
]);

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, Object?> _manifest({List<int>? patch, String? from, bool patches = true}) => {
  'schema': 1,
  'version': _version,
  'tag': 'v1.2.0',
  'assets': {
    'arm64': {'name': _apk, 'url': '$_dl/$_apk', 'size': _new.length, 'sha256': _sha(_new)},
  },
  if (patches)
    'patches': {
      'arm64': [
        {
          'from': from ?? _sha(_old),
          'fromVersion': '1.0.0',
          'name': _patchName,
          'size': (patch ?? _patch).length,
          'sha256': _sha(patch ?? _patch),
        },
      ],
    },
};

void main() {
  late Directory dir;
  late File installed;
  late FakeHttp http;
  late FakeInstaller installer;

  InstalledApp app({int lastUpdateTime = 1000}) => InstalledApp(
    versionName: '1.0.0',
    versionCode: 1,
    abi: 'arm64',
    freeBytes: 8 << 30,
    apkPath: installed.path,
    lastUpdateTime: lastUpdateTime,
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dsh_update_delta');
    installed = File('${dir.path}/base.apk')..writeAsBytesSync(_old);
    http = FakeHttp({_feed: (_, _) => textResponse(jsonEncode(_manifest())), '$_dl/$_apk': fileRoute(_new)});
    installer = FakeInstaller(app: app());
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Directory downloads() => Directory('${dir.path}/updates');
  File built() => File('${downloads().path}/$_apk');
  Iterable<String> asked(String name) => http.urls.where((u) => u.endsWith('/$name'));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(buildUpdateSources()),
        updateClockProvider.overrideWithValue(() => DateTime(2026, 11, 2, 9)),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => downloads()),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<(ProviderContainer, AppUpdateController)> checked() async {
    final c = container();
    final controller = c.read(appUpdateProvider.notifier);
    await controller.ready;
    expect(await controller.check(), UpdateCheckPhase.available);
    return (c, controller);
  }

  test('the offer says the patch\'s size; only the patch comes, and the APK built from it is installed', () async {
    http.routes['$_dl/$_patchName'] = fileRoute(_patch);
    final (c, controller) = await checked();
    var state = c.read(appUpdateProvider);
    expect(state.installedSha256, _sha(_old));
    expect(state.patch!.name, _patchName);
    expect(state.downloadSize, _patch.length);
    expect((await SharedPreferences.getInstance()).getString('update_installed_sha256'), '1:1000:${_sha(_old)}');

    await controller.startDownload();
    state = c.read(appUpdateProvider);
    expect(state.task, UpdateTaskPhase.ready);
    expect(state.total, _patch.length);
    expect(state.source, 'dl.dshtui.com');
    expect(built().readAsBytesSync(), _new);
    expect(downloads().listSync().map((f) => f.uri.pathSegments.last), [_apk], reason: 'the patch is gone');
    expect(asked(_apk), isEmpty);

    await controller.install();
    expect(installer.installed, [built().path]);
    expect(installer.calls, containsAllInOrder(['inspect', 'install']));
  });

  test('the patch goes through the mirrors and resumes like the APK', () async {
    var calls = 0;
    final dropping = fileRoute(_patch, dropAfter: 40);
    final full = fileRoute(_patch);
    // Our copy doesn't have it; GitHub drops once.
    http.routes['$_dl/$_patchName'] = (_, _) => textResponse('Not Found', status: 404);
    http.routes['$_github/$_patchName'] = (url, headers) => calls++ == 0 ? dropping(url, headers) : full(url, headers);
    final (c, controller) = await checked();
    await controller.startDownload();
    expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(built().readAsBytesSync(), _new);
    expect(http.requests.where((r) => r.$1.toString() == '$_github/$_patchName').last.$2['range'], 'bytes=40-');
    expect(asked(_apk), isEmpty);
  });

  group('anything wrong with the patch: the whole APK, silently, and not that patch again', () {
    final broken = {
      'not on any mirror': (FakeHttp http) {},
      'not what the manifest says (its SHA-256)': (FakeHttp http) {
        http.routes['$_dl/$_patchName'] = fileRoute([..._patch]..[100] ^= 1);
      },
      'for another base APK': (FakeHttp http) {
        final other = deltaPatch(utf8.encode('another 1.0.0 build'), _new, [deltaData(_new), deltaEnd]);
        http.routes[_feed] = (_, _) => textResponse(jsonEncode(_manifest(patch: other)));
        http.routes['$_dl/$_patchName'] = fileRoute(other);
      },
      'building something else': (FakeHttp http) {
        final wrong = deltaPatch(_old, _new, [deltaCopy(0, _new.length), deltaEnd]);
        http.routes[_feed] = (_, _) => textResponse(jsonEncode(_manifest(patch: wrong)));
        http.routes['$_dl/$_patchName'] = fileRoute(wrong);
      },
    };
    for (final MapEntry(key: name, value: arrange) in broken.entries) {
      test(name, () async {
        arrange(http);
        final (c, controller) = await checked();
        expect(c.read(appUpdateProvider).downloadSize, isNot(_new.length));
        await controller.startDownload();
        var state = c.read(appUpdateProvider);
        expect(state.task, UpdateTaskPhase.ready);
        expect(state.problem, isNull);
        expect(built().readAsBytesSync(), _new);
        expect(asked(_apk), isNotEmpty);
        expect(state.patchFailedVersion, _version);
        expect(state.patch, isNull);
        expect(state.downloadSize, _new.length);
        expect(downloads().listSync().map((f) => f.uri.pathSegments.last), [_apk]);

        // After a restart, with the APK gone: the whole APK straight away.
        built().deleteSync();
        http.requests.clear();
        final (again, next) = await checked();
        expect(again.read(appUpdateProvider).downloadSize, _new.length);
        await next.startDownload();
        expect(again.read(appUpdateProvider).task, UpdateTaskPhase.ready);
        expect(asked(_patchName), isEmpty);
        state = again.read(appUpdateProvider);
        expect(state.total, _new.length);
      });
    }
  });

  test('no patch from this APK: the whole APK, and nothing remembered', () async {
    http.routes[_feed] = (_, _) => textResponse(jsonEncode(_manifest(from: 'b' * 64)));
    final (c, controller) = await checked();
    expect(c.read(appUpdateProvider).installedSha256, _sha(_old));
    expect(c.read(appUpdateProvider).patch, isNull);
    expect(c.read(appUpdateProvider).downloadSize, _new.length);
    await controller.startDownload();
    expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(asked(_patchName), isEmpty);
    expect(c.read(appUpdateProvider).patchFailedVersion, isNull);
  });

  test('a manifest without patches works as before: nothing hashed, the whole APK', () async {
    http.routes[_feed] = (_, _) => textResponse(jsonEncode(_manifest(patches: false)));
    final (c, controller) = await checked();
    expect(c.read(appUpdateProvider).installedSha256, isNull);
    expect(c.read(appUpdateProvider).downloadSize, _new.length);
    await controller.startDownload();
    expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(http.urls.where((url) => url.endsWith('.apk')), ['$_dl/$_apk']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_installed_sha256'), isNull);
    expect(jsonDecode(prefs.getString('update_latest')!), isNot(contains('patches')));
  });

  test('the installed APK is hashed once per installed build', () async {
    // Remembered for this build: not hashed again (the file says otherwise).
    SharedPreferences.setMockInitialValues({'update_installed_sha256': '1:1000:${'a' * 64}'});
    http.routes[_feed] = (_, _) => textResponse(jsonEncode(_manifest(from: 'a' * 64)));
    var (c, _) = await checked();
    expect(c.read(appUpdateProvider).installedSha256, 'a' * 64);
    expect(c.read(appUpdateProvider).patch, isNotNull);

    // Reinstalled since: hashed afresh.
    installer.app = app(lastUpdateTime: 2000);
    (c, _) = await checked();
    expect(c.read(appUpdateProvider).installedSha256, _sha(_old));
    expect(c.read(appUpdateProvider).patch, isNull);
    expect((await SharedPreferences.getInstance()).getString('update_installed_sha256'), '1:2000:${_sha(_old)}');
  });

  test('the cached offer keeps its patches; an APK already built is checked and kept', () async {
    http.routes['$_dl/$_patchName'] = fileRoute(_patch);
    final (_, controller) = await checked();
    await controller.startDownload();

    http.requests.clear();
    final c = container();
    final again = c.read(appUpdateProvider.notifier);
    await again.ready;
    expect(c.read(appUpdateProvider).latest!.patches[ApkFlavor.arm64], hasLength(1));
    await again.startDownload();
    expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(http.requests, isEmpty);
    expect(built().readAsBytesSync(), _new);
  });

  group('the sheet', () {
    final release = parseUpdateManifest({
      ..._manifest(),
      'assets': {
        'arm64': {'name': _apk, 'url': '$_dl/$_apk', 'size': 180107933, 'sha256': _sha(_new)},
      },
      'patches': {
        'arm64': [
          {'from': _sha(_old), 'name': _patchName, 'size': 12345678, 'sha256': _sha(_patch)},
        ],
      },
    });

    Future<void> pump(WidgetTester tester, AppUpdateState state) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const Scaffold(body: SingleChildScrollView(child: UpdateSheet())),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            appUpdateProvider.overrideWith(() => _Offer(state)),
          ],
        ),
      );
      await tester.pump();
    }

    AppUpdateState offer({String? installed, String? failed}) => AppUpdateState(
      loaded: true,
      current: AppVersion.tryParse('1.0.0+1')!,
      flavor: ApkFlavor.arm64,
      check: UpdateCheckPhase.available,
      latest: release,
      installedSha256: installed,
      patchFailedVersion: failed,
    );

    testWidgets('the patch\'s size when one applies', (tester) async {
      await pump(tester, offer(installed: _sha(_old)));
      expect(find.textContaining(formatUpdateSize(12345678)), findsOneWidget);
      expect(find.textContaining(formatUpdateSize(180107933)), findsNothing);
    });

    testWidgets('the APK\'s size when none does, or it failed', (tester) async {
      for (final state in [offer(), offer(installed: 'c' * 64), offer(installed: _sha(_old), failed: _version)]) {
        await tester.pumpWidget(const SizedBox()); // a fresh ProviderScope each time
        await pump(tester, state);
        expect(find.textContaining(formatUpdateSize(180107933)), findsOneWidget);
        expect(find.textContaining(formatUpdateSize(12345678)), findsNothing);
      }
    });
  });

  group('the manifest', () {
    test('patches round-trip through the cached offer; broken entries and odd names are left out', () {
      final release = parseUpdateManifest({
        ..._manifest(),
        'patches': {
          'arm64': [
            {'from': 'A' * 64, 'fromVersion': '1.0.0', 'name': _patchName, 'size': 3, 'sha256': 'sha256:${'B' * 64}'},
            {'from': 'a' * 64, 'name': _patchName, 'size': 3},
            {'from': 'a' * 64, 'name': '../../shared_prefs/x', 'size': 3, 'sha256': 'b' * 64},
            {'from': 'short', 'name': _patchName, 'size': 3, 'sha256': 'b' * 64},
            'nonsense',
          ],
          'riscv': [
            {'from': 'a' * 64, 'name': _patchName, 'size': 3, 'sha256': 'b' * 64},
          ],
        },
      });
      final patch = release.patches[ApkFlavor.arm64]!.single;
      expect((patch.from, patch.sha256, patch.fromVersion), ('a' * 64, 'b' * 64, '1.0.0'));
      expect(release.patches.keys, [ApkFlavor.arm64]);
      expect(release.patchFor(ApkFlavor.arm64, 'a' * 64), same(patch));
      expect(release.patchFor(ApkFlavor.arm64, null), isNull);
      expect(release.patchFor(ApkFlavor.x64, 'a' * 64), isNull);

      final copy = parseUpdateManifest(jsonDecode(jsonEncode(release.toManifestJson())));
      expect(copy.patches[ApkFlavor.arm64]!.single.toJson(), patch.toJson());
      expect(copy.withApkSha256(ApkFlavor.arm64, 'c' * 64).patches, copy.patches);
    });
  });
}

class _Offer extends AppUpdateController {
  _Offer(this.initial);

  final AppUpdateState initial;

  @override
  AppUpdateState build() => initial;

  @override
  Future<void> get ready async {}
}
