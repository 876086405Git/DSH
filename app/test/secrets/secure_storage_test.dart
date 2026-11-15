import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/state/provider_keys.dart';
import 'package:dsh_app/state/settings_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/secrets');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Map<String, String> values;

  setUp(() {
    calls = [];
    values = {};
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map?;
      switch (call.method) {
        case 'read':
          return values[args!['key']];
        case 'readAll':
          return Map<String, String>.of(values);
        case 'write':
          values[args!['key'] as String] = args['value'] as String;
          return null;
        case 'recover':
          expect(args, {'confirmed': true});
          values.clear();
          return null;
        case 'delete':
          values.remove(args!['key']);
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('OH four-method consumer uses the exact channel contract, including null write as delete', () async {
    const store = AppSecureStorage.forPlatform('ohos');
    expect(await store.read(key: 'remote.中文'), isNull);
    await store.write(key: 'remote.中文', value: 'SSH 私钥🔐\nline two');
    expect(await store.read(key: 'remote.中文'), 'SSH 私钥🔐\nline two');
    expect(await store.readAll(), {'remote.中文': 'SSH 私钥🔐\nline two'});
    await store.write(key: 'remote.中文', value: null);
    expect(await store.readAll(), isEmpty);
    expect(calls.map((call) => call.method), ['read', 'write', 'read', 'readAll', 'delete', 'readAll']);
    expect(calls[1].arguments, {'key': 'remote.中文', 'value': 'SSH 私钥🔐\nline two'});
  });

  test('OH malformed reply and explicit errors stay failures rather than empty data', () async {
    const store = AppSecureStorage.forPlatform('ohos');
    messenger.setMockMethodCallHandler(channel, (_) async => {'good': 'value', 'bad': 7});
    await expectLater(store.readAll(), throwsFormatException);
    messenger.setMockMethodCallHandler(channel, (_) async => 7);
    await expectLater(store.read(key: 'k'), throwsFormatException);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'secrets_unreadable', message: '原加密数据未被覆盖。');
    });
    await expectLater(store.write(key: 'hosted_links', value: '[]'),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'secrets_unreadable')));
  });

  test('OH recovery is explicitly confirmed and propagates native failure', () async {
    const store = AppSecureStorage.forPlatform('ohos');
    await store.write(key: 'saved', value: 'credential');
    await expectLater(store.recover(confirmed: false), throwsArgumentError);
    expect(await store.readAll(), {'saved': 'credential'});
    expect(calls.where((call) => call.method == 'recover'), isEmpty);
    await store.recover(confirmed: true);
    expect(await store.readAll(), isEmpty);
    expect(calls.where((call) => call.method == 'recover').single.arguments, {'confirmed': true});
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'secrets_io');
    });
    await expectLater(store.recover(confirmed: true),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'secrets_io')));
  });

  test('missing HUKS key stays explicit and never triggers automatic recovery', () async {
    const store = AppSecureStorage.forPlatform('ohos');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'secrets_key_missing');
    });
    await expectLater(store.readAll(),
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'secrets_key_missing')));
    expect(calls.map((call) => call.method), ['readAll']);
  });

  test('recovery is unavailable on Android and explicit Flutter injections without touching their data', () async {
    const android = AppSecureStorage.forPlatform('android');
    const injected = AppSecureStorage.forPlatform('ohos', FlutterSecureStorage());
    await android.write(key: 'kept', value: 'original');
    await expectLater(android.recover(confirmed: true), throwsUnsupportedError);
    await expectLater(injected.recover(confirmed: true), throwsUnsupportedError);
    expect(await android.readAll(), {'kept': 'original'});
    expect(calls, isEmpty);
  });

  test('Android default and explicit Flutter injection use the original storage, not the OH channel', () async {
    const android = AppSecureStorage.forPlatform('android');
    await android.write(key: 'original', value: 'keystore value');
    expect(await const FlutterSecureStorage().read(key: 'original'), 'keystore value');
    const injected = AppSecureStorage.forPlatform('ohos', FlutterSecureStorage());
    expect(await injected.readAll(), {'original': 'keystore value'});
    await injected.delete(key: 'original');
    expect(await android.readAll(), isEmpty);
    expect(calls, isEmpty);
  });

  test('the five existing defaults retain Android keys, namespaces and const construction', () async {
    final remote = SecureSecretStore();
    final forum = SecureForumStore();
    const provider = SecureProviderKeyVault();
    const hosted = SecureHostedLinkStore();
    await remote.write('password', 'ssh');
    await forum.write('keypair', '{"private":"rsa"}');
    await provider.write('custom', 'provider');
    await hosted.save([]);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ready = Completer<void>();
    container.listen(settingsProvider, (_, next) {
      if (next.loaded && !ready.isCompleted) ready.complete();
    }, fireImmediately: true);
    await ready.future;
    await container.read(settingsProvider.notifier).setApiKey('  deepseek  ');
    expect(await const FlutterSecureStorage().readAll(), {
      'remote.password': 'ssh', 'forum.keypair': '{"private":"rsa"}',
      'provider_key_custom': 'provider', 'hosted_links': '[]', 'deepseek_api_key': 'deepseek',
    });
    expect(await provider.readAll(), {'custom': 'provider'});
    expect(calls, isEmpty);
  });
}
