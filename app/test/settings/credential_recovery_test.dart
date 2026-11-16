// 清除已保存的密钥 on HarmonyOS: asked for, once, in the person's own words; what
// was read from the vault doesn't come back; Android never sees any of it.

import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_config.dart';
import 'package:dsh_app/forum/forum_crypto.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/credential_recovery.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/provider_keys.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FakeBrowser;
import '../engine_settings/support.dart' as engine;
import '../remote/support/fake_relay.dart';
import '../shell/golden_harness.dart';

final _zh = lookupL10n(AppLocale.zhCN);

/// The `dsh/secrets` channel. [failure] is what every read and write says
/// until a recover clears the file; [recoverFailure] what a recover says.
class _Vault {
  String? failure;
  String? recoverFailure;
  final calls = <MethodCall>[];
  final _cleared = <void Function()>[];

  void whenCleared(void Function() action) => _cleared.add(action);

  List<MethodCall> get recovers => [
    for (final call in calls)
      if (call.method == 'recover') call,
  ];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    if (call.method == 'recover') {
      if (recoverFailure case final code?) throw PlatformException(code: code);
      failure = null;
      for (final action in _cleared) {
        action();
      }
      return null;
    }
    if (failure case final code?) throw PlatformException(code: code);
    return call.method == 'readAll' ? <String, String>{} : null;
  }
}

class _FailingSettings extends FakeSettings {
  _FailingSettings(this.code) : super(const AppSettings(loaded: true));

  final String code;
  int saves = 0;

  @override
  Future<void> setApiKey(String key) async {
    saves++;
    throw PlatformException(code: code);
  }
}

class _UnreadableSecrets implements SecretStore {
  _UnreadableSecrets([this.code = 'secrets_unreadable']);

  final String code;

  /// Store calls that changed or would have changed something (write, delete).
  int writes = 0;

  @override
  Future<String?> read(String key) async => throw PlatformException(code: code);

  @override
  Future<void> write(String key, String value) async {
    writes++;
    throw PlatformException(code: code);
  }

  @override
  Future<void> delete(String key) async {
    writes++;
    throw PlatformException(code: code);
  }
}

class _MemoryLinks implements HostedLinkStore {
  _MemoryLinks(this.saved);
  List<HostedLink> saved;

  @override
  Future<List<HostedLink>> load() async => List.of(saved);

  @override
  Future<void> save(List<HostedLink> links) async => saved = List.of(links);
}

class _MemoryKeys implements ProviderKeyVault {
  _MemoryKeys(this.keys);
  final Map<String, String> keys;

  @override
  Future<Map<String, String>> readAll() async => Map.of(keys);

  @override
  Future<void> write(String id, String key) async => keys[id] = key;

  @override
  Future<void> delete(String id) async => keys.remove(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/secrets');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Vault vault;

  setUp(() {
    vault = _Vault();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, vault.handle);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pumpPrivacy(WidgetTester tester, String os) => engine.pumpPage(
    tester,
    const PrivacyPage(),
    overrides: [
      ...engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
      relayBackendProvider.overrideWith((ref) => FakeRelayBackend()),
      operatingSystemProvider.overrideWithValue(os),
    ],
  );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text(_zh.harmonyCredentialsClear));
    await engine.settle(tester);
    expect(find.text(_zh.harmonyCredentialsClearBody), findsOneWidget);
  }

  group('the row', () {
    for (final code in const ['secrets_unreadable', 'secrets_key_missing', 'secrets_key_unusable']) {
      testWidgets('shows on HarmonyOS when the vault says $code', (tester) async {
        vault.failure = code;
        await pumpPrivacy(tester, 'ohos');
        expect(find.text(_zh.harmonyCredentialsClear), findsOneWidget);
        expect(vault.recovers, isEmpty, reason: 'nothing automatic');
      });
    }

    for (final code in const ['secrets_unavailable', 'secrets_io']) {
      testWidgets('stays away for $code: that one may pass', (tester) async {
        vault.failure = code;
        await pumpPrivacy(tester, 'ohos');
        expect(find.text(_zh.harmonyCredentialsClear), findsNothing);
      });
    }

    testWidgets('stays away while the vault is fine', (tester) async {
      await pumpPrivacy(tester, 'ohos');
      expect(find.text(_zh.harmonyCredentialsClear), findsNothing);
      expect(vault.calls.map((call) => call.method), ['read']);
    });

    testWidgets('on Android: no row, and the channel is never asked', (tester) async {
      vault.failure = 'secrets_unreadable';
      await pumpPrivacy(tester, 'android');
      expect(find.text(_zh.harmonyCredentialsClear), findsNothing);
      expect(vault.calls, isEmpty);
    });
  });

  group('the confirmation', () {
    testWidgets('says what goes and what stays, in the danger colour', (tester) async {
      vault.failure = 'secrets_unreadable';
      await pumpPrivacy(tester, 'ohos');
      await openDialog(tester);
      for (final words in ['API key', 'DSH Remote 登录', 'SSH 密码', '重新填写', '对话和主机列表会保留']) {
        expect(_zh.harmonyCredentialsClearBody, contains(words));
      }
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, _zh.harmonyCredentialsClearAction));
      expect(button.style!.backgroundColor!.resolve({}), DshColors.of(tester.element(find.byType(AlertDialog))).danger);
    });

    testWidgets('cancel leaves the vault alone', (tester) async {
      vault.failure = 'secrets_unreadable';
      await pumpPrivacy(tester, 'ohos');
      await openDialog(tester);
      await tester.tap(find.text(_zh.commonCancel));
      await engine.flush(tester);
      expect(vault.recovers, isEmpty);
      expect(find.text(_zh.harmonyCredentialsClear), findsOneWidget);
    });

    testWidgets('confirm recovers exactly once, with the word, and the row goes', (tester) async {
      vault.failure = 'secrets_key_missing';
      await pumpPrivacy(tester, 'ohos');
      await openDialog(tester);
      await tester.tap(find.text(_zh.harmonyCredentialsClearAction));
      await engine.flush(tester);
      expect(vault.recovers.single.arguments, {'confirmed': true});
      expect(find.text(_zh.harmonyCredentialsCleared), findsOneWidget);
      expect(find.text(_zh.harmonyCredentialsClear), findsNothing);
    });

    testWidgets('a failed clear says so, and the way out stays', (tester) async {
      vault
        ..failure = 'secrets_unreadable'
        ..recoverFailure = 'secrets_io';
      await pumpPrivacy(tester, 'ohos');
      await openDialog(tester);
      await tester.tap(find.text(_zh.harmonyCredentialsClearAction));
      await engine.flush(tester);
      expect(vault.recovers, hasLength(1));
      expect(find.text(_zh.harmonyCredentialsClearFailed), findsOneWidget);
      expect(find.text(_zh.harmonyCredentialsCleared), findsNothing);
      expect(find.text(_zh.harmonyCredentialsClear), findsOneWidget);
    });
  });

  group('where a save fails', () {
    Future<void> saveKey(WidgetTester tester, String os, _FailingSettings settings) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const ApiKeyPage(onboarding: false),
          brightness: Brightness.light,
          overrides: [
            settingsProvider.overrideWith(() => settings),
            relayBackendProvider.overrideWith((ref) => FakeRelayBackend()),
            operatingSystemProvider.overrideWithValue(os),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'sk-new');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, _zh.commonSave));
      await engine.settle(tester);
    }

    for (final code in const ['secrets_unreadable', 'secrets_key_missing', 'secrets_key_unusable']) {
      testWidgets('API key, $code: says the keys can\'t be read, not to try again', (tester) async {
        final settings = _FailingSettings(code);
        await saveKey(tester, 'ohos', settings);
        expect(find.text(_zh.harmonyCredentialsUnreadable), findsOneWidget);
        expect(find.text(_zh.shellSaveTryAgain), findsNothing);
        expect(vault.recovers, isEmpty);
      });
    }

    testWidgets('API key: after clearing, the typed key waits for the person to save again', (tester) async {
      final settings = _FailingSettings('secrets_unreadable');
      await saveKey(tester, 'ohos', settings);
      await tester.tap(find.text(_zh.harmonyCredentialsClearAction));
      await tester.pump();
      await tester.pump();
      expect(vault.recovers, hasLength(1));
      expect(settings.saves, 1);
    });

    testWidgets('API key: anything else may pass, so it still says to try again', (tester) async {
      await saveKey(tester, 'ohos', _FailingSettings('secrets_unavailable'));
      expect(find.text(_zh.shellSaveTryAgain), findsOneWidget);
      expect(find.text(_zh.harmonyCredentialsClearBody), findsNothing);
    });

    testWidgets('on Android: the same words as ever, whatever the code', (tester) async {
      await saveKey(tester, 'android', _FailingSettings('secrets_unreadable'));
      expect(find.text(_zh.shellSaveTryAgain), findsOneWidget);
      expect(find.text(_zh.harmonyCredentialsClearBody), findsNothing);
      expect(vault.calls, isEmpty);
    });

    Future<void> saveHost(WidgetTester tester, String os, SecretStore secrets) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SshHostFormPage(
            existing: SshHostConfig(id: 'h1', name: 'Mac', host: 'example.invalid', user: 'me'),
          ),
          brightness: Brightness.light,
          overrides: [
            secretStoreProvider.overrideWithValue(secrets),
            operatingSystemProvider.overrideWithValue(os),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.keyboardType == TextInputType.visiblePassword,
        ),
        'new-password',
      );
      await tester.pump();
      await tester.tap(find.text(_zh.commonSave).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('SSH host: offers the way out and keeps the form', (tester) async {
      final secrets = _UnreadableSecrets('secrets_key_missing');
      await saveHost(tester, 'ohos', secrets);
      expect(find.text(_zh.harmonyCredentialsClearBody), findsOneWidget);
      await tester.tap(find.text(_zh.commonCancel).last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SshHostFormPage), findsOneWidget);
      expect(secrets.writes, 1, reason: 'not tried again by itself');
      expect(vault.recovers, isEmpty);
    });

    testWidgets('SSH host on Android: only that it didn\'t save', (tester) async {
      await saveHost(tester, 'android', _UnreadableSecrets());
      expect(find.text(_zh.commonSaveFailed), findsOneWidget);
      expect(find.text(_zh.harmonyCredentialsClearBody), findsNothing);
    });

    for (final code in const ['secrets_unreadable', 'secrets_key_missing', 'secrets_key_unusable']) {
      test('relay account, $code: says so, and is not retried as a network error', () async {
        final backend = DshRemoteRelayBackend(secrets: _UnreadableSecrets(code), serverUrl: 'https://relay.example');
        addTearDown(backend.close);
        await expectLater(
          backend.currentUser(),
          throwsA(
            isA<HostLinkError>()
                .having((e) => e.message, 'message', appL10n.harmonyCredentialsUnreadableHint)
                .having((e) => e.retryable, 'retryable', isFalse),
          ),
        );
      });
    }

    test('forum sign-in: says the keys can\'t be read and where to go', () async {
      final c = ProviderContainer(
        overrides: [
          forumSecretStoreProvider.overrideWithValue(_UnreadableSecrets()),
          forumKeyPairFactoryProvider.overrideWithValue(() async => generateForumKeyPairSync()),
          accountBrowserProvider.overrideWithValue(FakeBrowser()),
        ],
      );
      addTearDown(c.dispose);
      c.read(forumAuthProvider);
      await pumpEventQueue();
      expect(await c.read(forumAuthProvider.notifier).signIn(), isFalse);
      expect(c.read(forumAuthProvider).phase, ForumAuthPhase.signedOut);
      expect(c.read(forumAuthProvider).error, appL10n.harmonyCredentialsUnreadableHint);
    });

    test('the failures trying again can\'t fix are exactly these three', () {
      PlatformException failure(String code) => PlatformException(code: code);
      expect(credentialsUnreadable(failure('secrets_unreadable')), isTrue);
      expect(credentialsUnreadable(failure('secrets_key_missing')), isTrue);
      expect(credentialsUnreadable(failure('secrets_key_unusable')), isTrue);
      for (final code in const ['secrets_unavailable', 'secrets_io', 'secrets_invalid', 'cancelled']) {
        expect(credentialsUnreadable(failure(code)), isFalse);
      }
      expect(credentialsUnreadable(StateError('secrets_unreadable')), isFalse);
    });
  });

  group('after clearing', () {
    late _MemoryLinks links;
    late _MemoryKeys keys;
    late MemorySecretStore forum;
    late List<FakeRelayBackend> relays;
    late int keyPairsMade;
    late ProviderContainer c;

    setUp(() {
      links = _MemoryLinks([
        HostedLink(
          id: 'l1',
          key: 'old-key',
          deleteToken: 'old-token',
          title: '旧链接',
          createdAt: DateTime.utc(2026, 10, 1),
          ttl: HostedTtl.month,
          origin: 'https://go.example',
        ),
      ]);
      keys = _MemoryKeys({'custom': 'old-provider-key'});
      forum = MemorySecretStore({'session:$forumDefaultBaseUrl': '{"key":"old","client":"c"}'});
      relays = [];
      keyPairsMade = 0;
      FlutterSecureStorage.setMockInitialValues({'deepseek_api_key': 'old-api-key'});
      vault.whenCleared(() {
        FlutterSecureStorage.setMockInitialValues({});
        links.saved = [];
        keys.keys.clear();
        forum.values.clear();
      });
      c = ProviderContainer(
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          hostedLinkStoreProvider.overrideWithValue(links),
          providerKeyVaultProvider.overrideWithValue(keys),
          forumSecretStoreProvider.overrideWithValue(forum),
          forumKeyPairFactoryProvider.overrideWithValue(() async {
            keyPairsMade++;
            return generateForumKeyPairSync();
          }),
          relayBackendProvider.overrideWith((ref) {
            final relay = FakeRelayBackend(user: relays.isEmpty ? sampleRelayUser : null);
            relays.add(relay);
            return relay;
          }),
        ],
      );
      addTearDown(c.dispose);
    });

    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await pumpEventQueue();
      }
    }

    test('nothing read from the vault is left to write back', () async {
      c.listen(settingsProvider, (_, _) {});
      c.listen(hostedLinksProvider, (_, _) {});
      c.listen(forumAuthProvider, (_, _) {});
      c.listen(relayAccountProvider, (_, _) {});
      await settle();
      expect(c.read(settingsProvider).apiKey, 'old-api-key');
      expect(c.read(settingsProvider).customProviderIds, {'custom'});
      expect(c.read(hostedLinksProvider).links, hasLength(1));
      expect(c.read(forumAuthProvider).signedIn, isTrue);
      expect(c.read(relayAccountProvider).value?.signedIn, isTrue);
      await c.read(forumAuthProvider.notifier).authorizeUrl();
      expect(keyPairsMade, 1);
      final relaysBefore = relays.length;
      c.read(activeHostProvider.notifier).select(const HostRef.relay('r1'));

      await c.read(credentialRecoveryProvider).recover();
      await settle();

      expect(vault.recovers.single.arguments, {'confirmed': true});
      expect(c.read(settingsProvider).apiKey, isEmpty);
      expect(c.read(settingsProvider).customProviderIds, isEmpty);
      expect(c.read(settingsProvider).loaded, isTrue, reason: 'no trip back to the splash');
      expect(c.read(hostedLinksProvider).links, isEmpty);
      expect(c.read(forumAuthProvider).signedIn, isFalse);
      expect(relays.length, greaterThan(relaysBefore), reason: 'the old account object is gone');
      expect(c.read(relayAccountProvider).value?.signedIn, isFalse);
      expect(c.read(activeHostProvider), HostRef.local);

      // The next save writes what's there now: the old link stays gone, and the
      // forum's key pair is made anew rather than remembered.
      await c.read(forumAuthProvider.notifier).authorizeUrl();
      expect(keyPairsMade, 2);
      expect(links.saved, isEmpty);
    });

    test('a failed clear leaves the file for another try and reports it', () async {
      vault.recoverFailure = 'secrets_io';
      await expectLater(
        c.read(credentialRecoveryProvider).recover(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'secrets_io')),
      );
      expect(vault.recovers, hasLength(1));
    });
  });
}
