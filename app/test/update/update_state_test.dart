import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _m1 = UpdateMirror(id: 'm1', label: 'mirror-one.example', prefix: 'https://mirror-one.example/');
const _sources = UpdateSources(mirrors: [UpdateMirror.github, _m1]);
const _api = 'https://api.github.com/repos/ccch1mneyyy/dsh-go/releases/latest';
const _manifest = 'https://github.com/ccch1mneyyy/dsh-go/releases/latest/download/update.json';
const _apkUrl = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/dsh-go-1.2.0-arm64.apk';

final _apk = utf8.encode('PK pretend this is DSH 1.2.0 for arm64');

Map<String, Object?> _release({String version = '1.2.0', List<int>? apk, String? sha}) => {
  'schema': 1,
  'version': version,
  'tag': 'v1.2.0',
  'notes': '- 应用内更新',
  'assets': {
    'arm64': {
      'name': 'dsh-go-1.2.0-arm64.apk',
      'size': (apk ?? _apk).length,
      'sha256': sha ?? sha256.convert(apk ?? _apk).toString(),
    },
    'x64': {'name': 'dsh-go-1.2.0-x64.apk', 'size': 99, 'sha256': '0' * 64},
  },
};

void main() {
  group('isAutoCheckDue', () {
    final now = DateTime(2026, 11, 2, 9);
    test('never checked → due', () => expect(isAutoCheckDue(now: now), isTrue));
    test('checked 23 h ago → not due; 24 h → due', () {
      expect(
        isAutoCheckDue(
          now: now,
          lastChecked: now.subtract(const Duration(hours: 23)),
          lastAttempt: now.subtract(const Duration(hours: 23)),
        ),
        isFalse,
      );
      expect(
        isAutoCheckDue(
          now: now,
          lastChecked: now.subtract(const Duration(hours: 24)),
          lastAttempt: now.subtract(const Duration(hours: 24)),
        ),
        isTrue,
      );
    });
    test('failing checks retry after 4 h, not on every launch', () {
      final dayAgo = now.subtract(const Duration(days: 2));
      expect(
        isAutoCheckDue(now: now, lastChecked: dayAgo, lastAttempt: now.subtract(const Duration(hours: 1))),
        isFalse,
      );
      expect(
        isAutoCheckDue(now: now, lastChecked: dayAgo, lastAttempt: now.subtract(const Duration(hours: 4))),
        isTrue,
      );
      expect(isAutoCheckDue(now: now, lastAttempt: now.subtract(const Duration(minutes: 5))), isFalse);
    });
    test('a clock set backwards counts as due', () {
      final future = now.add(const Duration(days: 30));
      expect(isAutoCheckDue(now: now, lastChecked: future, lastAttempt: future), isTrue);
    });
  });

  group('controller', () {
    late Directory dir;
    late FakeHttp http;
    late FakeInstaller installer;
    late DateTime now;
    String? flavor;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('dsh_update_state');
      http = FakeHttp();
      installer = FakeInstaller();
      now = DateTime(2026, 11, 2, 9);
      flavor = 'arm64';
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          updateHttpProvider.overrideWithValue(http),
          updateInstallerProvider.overrideWithValue(installer),
          updateSourcesProvider.overrideWithValue(_sources),
          updateClockProvider.overrideWithValue(() => now),
          updateFlavorNameProvider.overrideWithValue(flavor),
          updateDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<AppUpdateController> ready(ProviderContainer c) async {
      final controller = c.read(appUpdateProvider.notifier);
      await controller.ready;
      return controller;
    }

    test('loads the installed version and flavor from the native side', () async {
      installer.app = const InstalledApp(versionName: '1.1.0', versionCode: 5, abi: 'x86_64');
      flavor = null;
      final c = container();
      await ready(c);
      final state = c.read(appUpdateProvider);
      expect(state.loaded, isTrue);
      expect(state.current.toString(), '1.1.0+5');
      expect(state.flavor, ApkFlavor.x64);
      expect(state.autoCheck, isTrue);
    });

    test('daily auto check: offers once, then waits a day; remembers the endpoint that answered', () async {
      const m1 = 'https://mirror-one.example/$_manifest';
      http.routes[m1] = (_, _) => textResponse(jsonEncode(_release()));
      final c = container();
      final controller = await ready(c);

      expect(await controller.autoCheckIfDue(), isTrue);
      final state = c.read(appUpdateProvider);
      expect(state.check, UpdateCheckPhase.available);
      expect(state.latest!.version.name, '1.2.0');
      expect(state.asset!.name, 'dsh-go-1.2.0-arm64.apk');
      expect(http.urls, [_manifest, m1]);

      now = now.add(const Duration(hours: 5));
      expect(await controller.autoCheckIfDue(), isFalse);
      expect(http.requests, hasLength(2), reason: 'throttled');

      now = now.add(const Duration(hours: 20));
      http.requests.clear();
      expect(await controller.autoCheckIfDue(), isTrue);
      expect(http.urls, [m1], reason: 'starts where it worked last time');
    });

    test('a build without the APK installer (HarmonyOS) never checks or offers', () async {
      // A real channel with no handler behind it, as on HarmonyOS.
      TestWidgetsFlutterBinding.ensureInitialized();
      final c = ProviderContainer(
        overrides: [
          updateHttpProvider.overrideWithValue(http),
          updateInstallerProvider.overrideWithValue(const ChannelUpdateInstaller()),
          updateSourcesProvider.overrideWithValue(_sources),
          updateClockProvider.overrideWithValue(() => now),
          updateDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      final controller = await ready(c);
      expect(c.read(appUpdateProvider).loaded, isTrue);
      expect(c.read(appUpdateProvider).installable, isFalse);
      expect(await controller.autoCheckIfDue(), isFalse);
      expect(await controller.check(), UpdateCheckPhase.idle);
      expect(http.requests, isEmpty);
    });

    test('switched off: no automatic check', () async {
      final c = container();
      final controller = await ready(c);
      await controller.setAutoCheck(false);
      expect(await controller.autoCheckIfDue(), isFalse);
      expect(http.requests, isEmpty);
      expect((await SharedPreferences.getInstance()).getBool('update_auto_check'), isFalse);
    });

    test('switched off while the check is in flight: no offer, but the result is kept', () async {
      final answer = Completer<UpdateHttpResponse>();
      http.routes[_manifest] = (_, _) => answer.future;
      final c = container();
      final controller = await ready(c);
      final offered = controller.autoCheckIfDue();
      await pumpEventQueue();
      expect(http.urls, [_manifest]);
      await controller.setAutoCheck(false);
      answer.complete(textResponse(jsonEncode(_release())));
      expect(await offered, isFalse);
      final state = c.read(appUpdateProvider);
      expect(state.autoCheck, isFalse);
      expect(state.hasUpdate, isTrue, reason: 'a manual look still finds it');
    });

    test('a skipped version is not offered again, a newer one is; a manual check still shows it', () async {
      http.routes[_api] = (_, _) => textResponse(fixture('github_release.json'));
      final c = container();
      final controller = await ready(c);
      expect(await controller.autoCheckIfDue(), isTrue);
      await controller.skipLatest();
      expect(c.read(appUpdateProvider).isSkipped, isTrue);

      now = now.add(const Duration(days: 1));
      expect(await controller.autoCheckIfDue(), isFalse);
      expect(await controller.check(), UpdateCheckPhase.available);

      http.routes[_api] = (_, _) => textResponse(fixture('github_release.json').replaceAll('1.2.0', '1.2.1'));
      now = now.add(const Duration(days: 1));
      expect(await controller.autoCheckIfDue(), isTrue);
      expect(c.read(appUpdateProvider).latest!.version.name, '1.2.1');
      expect(c.read(appUpdateProvider).isSkipped, isFalse);
    });

    test('same version as installed → up to date', () async {
      installer.app = const InstalledApp(versionName: '1.2.0', versionCode: 7, abi: 'arm64');
      http.routes[_api] = (_, _) => textResponse(fixture('github_release.json'));
      final c = container();
      final controller = await ready(c);
      expect(await controller.check(), UpdateCheckPhase.upToDate);
      expect(c.read(appUpdateProvider).hasUpdate, isFalse);
    });

    test('nothing reachable → unavailable, quietly', () async {
      final c = container();
      final controller = await ready(c);
      expect(await controller.check(), UpdateCheckPhase.unavailable);
      expect(await controller.autoCheckIfDue(), isFalse, reason: 'just attempted');
    });

    test('the last offer survives a restart without the network, and is dropped once installed', () async {
      SharedPreferences.setMockInitialValues({
        'update_latest': jsonEncode(_release()),
        'update_last_checked': now.millisecondsSinceEpoch,
        'update_last_attempt': now.millisecondsSinceEpoch,
      });
      final c = container();
      await ready(c);
      expect(c.read(appUpdateProvider).hasUpdate, isTrue);
      expect(c.read(appUpdateProvider).check, UpdateCheckPhase.available);
      expect(http.requests, isEmpty);

      installer.app = const InstalledApp(versionName: '1.2.0', versionCode: 7, abi: 'arm64');
      final after = container();
      await ready(after);
      expect(after.read(appUpdateProvider).hasUpdate, isFalse);
      expect((await SharedPreferences.getInstance()).getString('update_latest'), isNull);
    });

    test('download → no install permission → settings → back → install', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
      http.routes[_apkUrl] = fileRoute(_apk);
      installer.canInstall = false;
      final c = container();
      final controller = await ready(c);
      await controller.check();

      await controller.startDownload();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(File('${dir.path}/dsh-go-1.2.0-arm64.apk').readAsBytesSync(), _apk);

      await controller.install();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.needsPermission);
      await controller.requestInstallPermission();
      expect(installer.calls, contains('openInstallPermission'));

      // Came back without granting it: still waiting.
      await controller.onAppResumed();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.needsPermission);

      installer.canInstall = true;
      await controller.onAppResumed();
      expect(installer.calls, containsAllInOrder(['inspect', 'install']));
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.idle);
    });

    test('download prefers the mirror that answered the check', () async {
      http.routes['https://mirror-one.example/$_manifest'] = (_, _) => textResponse(jsonEncode(_release()));
      http.routes['https://mirror-one.example/$_apkUrl'] = fileRoute(_apk);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      http.requests.clear();
      await controller.startDownload();
      expect(http.urls.first, 'https://mirror-one.example/$_apkUrl');
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    });

    test('checksum mismatch everywhere → failed, nothing to install', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release(sha: 'f' * 64)));
      http.routes[_apkUrl] = fileRoute(_apk);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      final state = c.read(appUpdateProvider);
      expect(state.task, UpdateTaskPhase.failed);
      expect(state.problem, UpdateProblem.checksum);
      await controller.install();
      expect(installer.calls, isNot(contains('install')));
    });

    test('no checksum anywhere → refuses to download', () async {
      http.routes[_api] = (_, _) => textResponse(fixture('github_release.json'));
      flavor = 'x64'; // the fixture's x64 asset has no digest, and there is no SHA256SUMS route
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      expect(c.read(appUpdateProvider).problem, UpdateProblem.noChecksum);
      expect(http.urls.where((u) => u.endsWith('.apk')), isEmpty);
    });

    test('a different signing key is caught before the system installer', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
      http.routes[_apkUrl] = fileRoute(_apk);
      installer.inspection = const ApkInspection(valid: true, signatureMatches: false);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      await controller.install();
      expect(c.read(appUpdateProvider).problem, UpdateProblem.signature);
      expect(installer.calls, isNot(contains('install')));
    });

    test('cancelled in the system dialog → back to ready; system-reported conflicts map to problems', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
      http.routes[_apkUrl] = fileRoute(_apk);
      installer.result = const InstallResult(InstallStatus.aborted);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      await controller.install();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(c.read(appUpdateProvider).problem, UpdateProblem.installCancelled);
      // The same checked file goes to the system's own installer.
      expect(await controller.installWithSystem(), isTrue);
      expect(installer.calls.last, 'openWithSystemInstaller');
      expect(installer.installed.last, installer.installed.first);

      installer.result = const InstallResult(InstallStatus.signature, 'INSTALL_FAILED_UPDATE_INCOMPATIBLE');
      await controller.install();
      expect(c.read(appUpdateProvider).problem, UpdateProblem.signature);
    });

    test('not enough space → stops before downloading', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
      installer.app = const InstalledApp(versionName: '1.0.0', versionCode: 1, abi: 'arm64', freeBytes: 1024);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      expect(c.read(appUpdateProvider).problem, UpdateProblem.noSpace);
      expect(http.urls.where((u) => u.endsWith('.apk')), isEmpty);
    });

    test('a system dialog that closes without reporting frees the install after a grace period', () async {
      http.routes[_manifest] = (_, _) => textResponse(jsonEncode(_release()));
      http.routes[_apkUrl] = fileRoute(_apk);
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      installer.pending = Completer<InstallResult>();
      final installing = controller.install();
      await installer.called('install');
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.installing);
      await controller.onAppResumed(confirmGrace: const Duration(milliseconds: 10));
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(c.read(appUpdateProvider).problem, UpdateProblem.installUnconfirmed);
      // A late answer from the abandoned attempt changes nothing.
      installer.pending!.complete(const InstallResult(InstallStatus.failure));
      await installing;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    });
  });
}
