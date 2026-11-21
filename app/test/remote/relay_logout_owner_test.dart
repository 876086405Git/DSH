// Real RemoteScreen actions, account controllers, SDK REST and SecretStore.
// The loopback server holds only the first revoke response after its normal
// mutation. No SDK close, private credential field or timer is replaced.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/secret_store.dart' as app_secrets;
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/relay_login_sheet.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_remote/test/support/fake_remote.dart';
import '../shell/golden_harness.dart' show FakeRuntime, runningStatus, usePhoneSurface;

const _guard = Duration(seconds: 8);
const _operation = #logoutOwnerOperation;

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

class _RevokeGate {
  final entered = Completer<void>();
  final released = Completer<void>();

  Future<void> call() {
    entered.complete();
    return released.future;
  }

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

// Values stay inside this test. The trace contains only action/kind/caller,
// never a key, user identity, password, token or serialized secret value.
class _Secrets implements app_secrets.SecretStore, remote.SecretStore {
  final values = <String, String>{};
  final events = <Map<String, Object>>[];

  String? record(String suffix) => values.entries.where((entry) => entry.key.endsWith(suffix)).firstOrNull?.value;

  void _observe(String action, String key) {
    final kind = key.endsWith('.identity')
        ? 'identity'
        : key.endsWith('.credentials')
        ? 'credentials'
        : 'other';
    events.add({
      'sequence': events.length + 1,
      'action': action,
      'kind': kind,
      'caller': Zone.current[_operation] as String? ?? 'observer',
    });
  }

  @override
  Future<String?> read(String key) async {
    _observe('read', key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _observe('write', key);
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _observe('delete', key);
    values.remove(key);
  }
}

// Calls delegate unchanged to the real adapter. Zone values only attribute
// subsequent store operations; they do not intercept timers or scheduling.
class _ObservedBackend extends DshRemoteRelayBackend {
  _ObservedBackend({required super.secrets, required super.account}) : super(direct: false);

  final logouts = <Future<void>>[];
  final passwordLogins = <Future<RelayUser>>[];
  final _started = StreamController<void>.broadcast(sync: true);

  @override
  Future<void> logout() {
    final result = runZoned(super.logout, zoneValues: {_operation: 'logout-${logouts.length + 1}'});
    logouts.add(result);
    result.ignore();
    _started.add(null);
    return result;
  }

  @override
  Future<RelayUser> loginWithPassword(String email, String password) {
    final result = runZoned(
      () => super.loginWithPassword(email, password),
      zoneValues: {_operation: 'login-${passwordLogins.length + 1}'},
    );
    passwordLogins.add(result);
    result.ignore();
    _started.add(null);
    return result;
  }

  Future<void> waitForLogouts(int count) async {
    if (logouts.length >= count) return;
    await _started.stream.firstWhere((_) => logouts.length >= count).timeout(_guard);
  }

  Future<void> waitForLogins(int count) async {
    if (passwordLogins.length >= count) return;
    await _started.stream.firstWhere((_) => passwordLogins.length >= count).timeout(_guard);
  }

  Future<void> closeObserver() => _started.close();
}

Future<T> _state<T>(ProviderContainer container, ProviderListenable<T> provider, bool Function(T) accept) async {
  final arrived = Completer<T>();
  final sub = container.listen(provider, (_, next) {
    if (!arrived.isCompleted && accept(next)) arrived.complete(next);
  }, fireImmediately: true);
  try {
    return await arrived.future.timeout(_guard);
  } finally {
    sub.close();
  }
}

class _Fixture {
  _Fixture(this.server, this.secrets, this.account, this.backend, this.container, this.original);

  final FakeRemoteServer server;
  final _Secrets secrets;
  final remote.RemoteAccount account;
  final _ObservedBackend backend;
  final ProviderContainer container;
  final RelayUser original;
  final _gate = _RevokeGate();
  final restoredAccounts = <remote.RemoteAccount>[];
  Future<List<String>>? _cleaning;

  static Future<_Fixture> create() async {
    final server = await FakeRemoteServer.start();
    final secrets = _Secrets();
    final account = remote.RemoteAccount(secrets: secrets, serverUrl: server.url);
    final backend = _ObservedBackend(secrets: secrets, account: account);
    ProviderContainer? container;
    try {
      final original = await backend.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
      SharedPreferences.setMockInitialValues({
        RelayServerController.prefsKey: server.url.origin,
        ActiveHostController.prefsKey: HostRef.local.encode(),
      });
      container = ProviderContainer(
        overrides: [
          secretStoreProvider.overrideWithValue(secrets),
          relayBackendProvider.overrideWithValue(backend),
          localConnectionProvider.overrideWith(_NoLocal.new),
          networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
        ],
      );
      await _state(container, relayServerProvider, (origin) => origin == server.url.origin);
      await container.read(activeHostProvider.notifier).ready;
      await container.read(relayAccountProvider.future).timeout(_guard);
      return _Fixture(server, secrets, account, backend, container, original);
    } catch (_) {
      container?.dispose();
      // Each owned resource gets a cleanup attempt even if another fails.
      try {
        await backend.close().timeout(_guard);
      } catch (_) {}
      try {
        await backend.closeObserver().timeout(_guard);
      } catch (_) {}
      try {
        await server.close().timeout(_guard);
      } catch (_) {}
      rethrow;
    }
  }

  void holdFirstRevokeResponse() => server.beforeRevokeResponse = _gate.call;

  bool get sameBackend =>
      identical(container.read(relayBackendProvider), backend) && identical(backend.account, account);
  bool get uiSignedIn => container.read(relayAccountProvider).value?.signedIn ?? false;

  Future<remote.RemoteUser?> restoredUser() async {
    final restored = remote.RemoteAccount(secrets: secrets, serverUrl: server.url);
    restoredAccounts.add(restored);
    return restored.currentUser();
  }

  Future<List<String>> cleanup() => _cleaning ??= _cleanup();

  Future<List<String>> _cleanup() async {
    final failed = <String>[];
    Future<void> settled<T>(Future<T> request) => request.then<void>((_) {}, onError: (Object _) {});
    Future<void> attempt(String label, FutureOr<void> Function() action) async {
      try {
        await Future<void>.sync(action).timeout(_guard);
      } catch (_) {
        failed.add(label);
      }
    }

    _gate.release();
    await attempt('container', container.dispose);
    for (final (index, request) in backend.logouts.indexed) {
      await attempt('logout-${index + 1}', () => settled(request));
    }
    for (final (index, request) in backend.passwordLogins.indexed) {
      await attempt('login-${index + 1}', () => settled(request));
    }
    for (final (index, restored) in restoredAccounts.indexed) {
      await attempt('restored-${index + 1}', restored.close);
    }
    await attempt('backend', backend.close);
    await attempt('observer', backend.closeObserver);
    await attempt('server', server.close);
    return failed;
  }
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _withScreen(WidgetTester tester, Future<void> Function(_Fixture fixture) body) async {
  final fixture = (await tester.runAsync(_Fixture.create))!;
  addTearDown(() async {
    final failed = await fixture.cleanup();
    if (failed.isNotEmpty) fail('Owned cleanup failed: ${failed.join(', ')}');
  });
  usePhoneSurface(tester);
  try {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: const RemoteScreen(),
        ),
      ),
    );
    await _frames(tester);
    // The page re-reads the account's hosts when it opens: let that request
    // finish before the test talks to the server (its reply lands on a pump).
    for (var i = 0; i < 100 && (fixture.container.read(relayAccountProvider).value?.refreshing ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await body(fixture);
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      // Business failures remain the primary error. Cleanup failures are
      // reported separately by the registered teardown above.
      await tester.runAsync(fixture.cleanup);
    }
  }
}

Future<void> _confirmLogout(WidgetTester tester, _Fixture fixture, {required int call, bool hold = false}) async {
  final entry = find.descendant(
    of: find.byType(RemoteScreen),
    matching: find.widgetWithText(TextButton, appL10n.remoteSignOut),
  );
  expect(entry, findsOneWidget);
  expect(tester.widget<TextButton>(entry).onPressed, isNotNull, reason: 'actual logout entry is enabled');
  await tester.runAsync(() => tester.tap(entry));
  await _frames(tester);
  final confirm = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, appL10n.remoteSignOut),
  );
  expect(confirm, findsOneWidget);
  await tester.runAsync(() async {
    await tester.tap(confirm);
    await fixture.backend.waitForLogouts(call);
    if (hold) {
      await fixture._gate.entered.future.timeout(_guard);
    } else {
      await fixture.backend.logouts[call - 1].timeout(_guard);
      await _state(fixture.container, relayAccountProvider, (value) => value.value?.signedIn == false);
    }
  });
  await _frames(tester);
  expect(find.byType(AlertDialog), findsNothing);
}

Future<RelayUser> _signInAgain(WidgetTester tester, _Fixture fixture) async {
  expect(fixture.uiSignedIn, isFalse);
  expect(fixture.container.read(relayServerProvider) == fixture.server.url.origin, isTrue);
  await tester.runAsync(() => tester.tap(find.text(appL10n.remoteSelfHostedEmailSignIn)));
  await _frames(tester);
  expect(find.byType(SelfHostedLoginSheet), findsOneWidget);
  final fields = find.descendant(of: find.byType(SelfHostedLoginSheet), matching: find.byType(TextField));
  expect(fields, findsNWidgets(3));
  expect(tester.widget<TextField>(fields.at(0)).controller!.text == fixture.server.url.origin, isTrue);
  await tester.enterText(fields.at(1), FakeRemoteServer.account);
  await tester.enterText(fields.at(2), FakeRemoteServer.password);
  final submit = find.descendant(
    of: find.byType(SelfHostedLoginSheet),
    matching: find.widgetWithText(FilledButton, appL10n.commonSignIn),
  );
  late RelayUser signedIn;
  await tester.runAsync(() async {
    await tester.tap(submit);
    await fixture.backend.waitForLogins(2);
    signedIn = await fixture.backend.passwordLogins.last.timeout(_guard);
    await _state(fixture.container, relayAccountProvider, (value) => value.value?.user?.id == signedIn.id);
  });
  await _frames(tester);
  expect(find.byType(SelfHostedLoginSheet), findsNothing);
  expect(fixture.sameBackend, isTrue);
  expect(fixture.container.read(relayServerProvider) == fixture.server.url.origin, isTrue);
  return signedIn;
}

void main() {
  _LoopbackBinding();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('normal confirmed logout removes its credentials and identity', (tester) async {
    await _withScreen(tester, (fixture) async {
      await _confirmLogout(tester, fixture, call: 1);
      expect(fixture.sameBackend, isTrue);
      expect(fixture.uiSignedIn, isFalse);
      expect(fixture.server.devices[fixture.original.id]!.revoked, isTrue);
      expect(fixture.secrets.record('.credentials') == null, isTrue);
      expect(fixture.secrets.record('.identity') == null, isTrue);
      await tester.runAsync(() async {
        expect(await fixture.account.currentUser() == null, isTrue);
        expect(await fixture.restoredUser() == null, isTrue);
      });
    });
  });

  testWidgets('serial logout then same-server UI login retains its new identity', (tester) async {
    await _withScreen(tester, (fixture) async {
      await _confirmLogout(tester, fixture, call: 1);
      final signedIn = await _signInAgain(tester, fixture);
      expect(signedIn.id != fixture.original.id, isTrue);
      expect(fixture.server.devices[signedIn.id]!.revoked, isFalse);
      await tester.runAsync(() async {
        expect((await fixture.account.currentUser())?.deviceId == signedIn.id, isTrue);
        expect((await fixture.restoredUser())?.deviceId == signedIn.id, isTrue);
        expect(await fixture.account.listHosts(), isEmpty);
      });
    });
  });

  testWidgets('late first logout preserves login after a second real UI logout', (tester) async {
    await _withScreen(tester, (fixture) async {
      fixture.holdFirstRevokeResponse();
      await _confirmLogout(tester, fixture, call: 1, hold: true);
      expect(fixture.uiSignedIn, isTrue, reason: 'first logout has not changed the signed-in UI');
      expect(fixture.server.devices[fixture.original.id]!.revoked, isTrue);
      expect(fixture._gate.released.isCompleted, isFalse);

      await _confirmLogout(tester, fixture, call: 2);
      expect(fixture.backend.logouts, hasLength(2));
      expect(fixture.server.requests.where((request) => request == 'DELETE /api/v1/devices/self'), hasLength(2));
      expect(
        fixture.server.responses.where((response) => response.method == 'DELETE').map((response) => response.status),
        [401],
        reason: 'second revoke fails naturally while first successful response is still held',
      );
      expect(fixture._gate.released.isCompleted, isFalse);

      final signedIn = await _signInAgain(tester, fixture);
      final credentials = fixture.secrets.record('.credentials');
      final identity = fixture.secrets.record('.identity');
      expect(credentials != null && identity != null, isTrue);
      expect(signedIn.id != fixture.original.id, isTrue);
      await tester.runAsync(() async {
        expect((await fixture.account.currentUser())?.deviceId == signedIn.id, isTrue);
        expect(await fixture.account.listHosts(), isEmpty, reason: 'new login works before releasing old response');
      });
      final beforeRelease = fixture.secrets.events.length;
      late remote.RemoteUser? current;
      late remote.RemoteUser? restored;
      var listingSucceeded = false;
      var listingCode = 'none';
      await tester.runAsync(() async {
        fixture._gate.release();
        await fixture.backend.logouts.first.timeout(_guard);
        current = await fixture.account.currentUser();
        restored = await fixture.restoredUser();
        try {
          await fixture.account.listHosts();
          listingSucceeded = true;
        } on remote.RemoteConnectException catch (error) {
          listingCode = error.code == 'ACCOUNT_AUTH_REQUIRED' ? 'ACCOUNT_AUTH_REQUIRED' : 'other';
        }
      });
      await _frames(tester);
      final observation = {
        'sameBackend': fixture.sameBackend,
        'newIdentityWasCreated': signedIn.id != fixture.original.id,
        'oldDeviceRevoked': fixture.server.devices[fixture.original.id]!.revoked,
        'newDeviceRevoked': fixture.server.devices[signedIn.id]!.revoked,
        'uiStillSignedIn': fixture.uiSignedIn,
        'accountOwnsNewLogin': current?.deviceId == signedIn.id,
        'restoredOwnsNewLogin': restored?.deviceId == signedIn.id,
        'credentialsPreserved': fixture.secrets.record('.credentials') == credentials,
        'identityPreserved': fixture.secrets.record('.identity') == identity,
        'listingSucceeded': listingSucceeded,
        'listingCode': listingCode,
        'revokeResponseStatuses': [
          for (final response in fixture.server.responses)
            if (response.method == 'DELETE') response.status,
        ],
        'storeAfterOldResponse': fixture.secrets.events.skip(beforeRelease).toList(),
      };
      debugPrint('DSH_W18_LOGOUT_OWNER ${jsonEncode(observation)}');
      expect(observation['sameBackend'], isTrue);
      expect(observation['newDeviceRevoked'], isFalse);
      expect(observation['accountOwnsNewLogin'], isTrue, reason: 'old logout must not sign out the new login');
      expect(observation['restoredOwnsNewLogin'], isTrue);
      expect(observation['credentialsPreserved'], isTrue);
      expect(observation['identityPreserved'], isTrue);
      expect(observation['listingSucceeded'], isTrue);
      expect(observation['uiStillSignedIn'], isTrue);
    });
  });

  // These are public SDK/adapter controls. They do not claim another UI
  // gesture trace: their purpose is to distinguish a new sign-in from an
  // ordinary token refresh or a refused sign-in on the same account.
  Future<_Fixture> accountFixture() async {
    final fixture = await _Fixture.create();
    addTearDown(() async {
      final failed = await fixture.cleanup();
      if (failed.isNotEmpty) fail('Owned cleanup failed: ${failed.join(', ')}');
    });
    fixture.server.failNextRevoke = true;
    fixture.holdFirstRevokeResponse();
    return fixture;
  }

  test('SDK late logout preserves a committed login that reuses the same identity', () async {
    final fixture = await accountFixture();
    final oldLogout = fixture.backend.logout();
    await fixture._gate.entered.future.timeout(_guard);
    expect(fixture.server.devices[fixture.original.id]!.revoked, isFalse);
    final oldIdentity = fixture.secrets.record('.identity');
    final oldCredentials = fixture.secrets.record('.credentials');
    final signedIn = await fixture.backend.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final latestCredentials = fixture.secrets.record('.credentials');
    expect(signedIn.id == fixture.original.id, isTrue);
    expect(fixture.secrets.record('.identity') == oldIdentity, isTrue);
    expect(latestCredentials != oldCredentials, isTrue);
    expect(await fixture.account.listHosts(), isEmpty);

    fixture._gate.release();
    await oldLogout.timeout(_guard);
    final current = await fixture.account.currentUser();
    final restored = await fixture.restoredUser();
    var listingSucceeded = false;
    try {
      await fixture.account.listHosts();
      listingSucceeded = true;
    } on remote.RemoteConnectException {
      // The baseline's expected refusal is recorded as a boolean, not a
      // short-circuiting expectation or a token-bearing exception dump.
    }
    final observation = {
      'sameIdentity': signedIn.id == fixture.original.id,
      'currentOwnsCommittedLogin': current?.deviceId == signedIn.id,
      'restoredOwnsCommittedLogin': restored?.deviceId == signedIn.id,
      'credentialsPreserved': fixture.secrets.record('.credentials') == latestCredentials,
      'identityPreserved': fixture.secrets.record('.identity') == oldIdentity,
      'listingSucceeded': listingSucceeded,
      'revokeResponseStatuses': [
        for (final response in fixture.server.responses)
          if (response.method == 'DELETE') response.status,
      ],
    };
    debugPrint('DSH_W18_LOGOUT_OWNER_SAME_ID ${jsonEncode(observation)}');
    expect(observation['revokeResponseStatuses'], [503]);
    expect(observation['currentOwnsCommittedLogin'], isTrue);
    expect(observation['restoredOwnsCommittedLogin'], isTrue);
    expect(observation['credentialsPreserved'], isTrue);
    expect(observation['identityPreserved'], isTrue);
    expect(observation['listingSucceeded'], isTrue);
  });

  test('SDK current logout still removes credentials rotated by an ordinary refresh', () async {
    final fixture = await accountFixture();
    final oldLogout = fixture.backend.logout();
    await fixture._gate.entered.future.timeout(_guard);
    final before = fixture.secrets.record('.credentials');
    await fixture.account.refresh();
    expect(fixture.secrets.record('.credentials') != before, isTrue);
    expect((await fixture.account.currentUser())?.deviceId == fixture.original.id, isTrue);
    expect(fixture.server.refreshCount, 1);
    fixture._gate.release();
    await oldLogout.timeout(_guard);
    expect(await fixture.account.currentUser() == null, isTrue);
    expect(await fixture.restoredUser() == null, isTrue);
    expect(fixture.secrets.record('.credentials') == null, isTrue);
    expect(fixture.secrets.record('.identity') == null, isTrue);
  });

  test('SDK a refused login does not retire the current logout', () async {
    final fixture = await accountFixture();
    final oldLogout = fixture.backend.logout();
    await fixture._gate.entered.future.timeout(_guard);
    final before = fixture.secrets.record('.credentials');
    await expectLater(
      fixture.backend.loginWithPassword(FakeRemoteServer.account, 'invalid-test-password'),
      throwsA(isA<HostLinkError>().having((error) => error.kind, 'kind', HostLinkErrorKind.authFailed)),
    );
    expect(fixture.secrets.record('.credentials') == before, isTrue);
    fixture._gate.release();
    await oldLogout.timeout(_guard);
    expect(await fixture.account.currentUser() == null, isTrue);
    expect(await fixture.restoredUser() == null, isTrue);
    expect(fixture.secrets.record('.credentials') == null, isTrue);
    expect(fixture.secrets.record('.identity') == null, isTrue);
  });
}
