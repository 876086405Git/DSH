import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/runtime/phone_callback_bridge.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Real loopback sockets for the typed claim; no external network is used.
class _LocalSocketBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _ownerSecret = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _requestId = '66666666-6666-4666-8666-666666666666';
const _nonce = '77777777-7777-4777-8777-777777777777';

Map<String, Object?> _bootstrap(Uri uri) => {
  'v': 1,
  'engineId': 'engine',
  'bridgeGeneration': 5,
  'baseUrl': uri.toString(),
  'owner': _ownerSecret,
};

Future<DshPhoneClaim> _claim({bool handoff = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final uri = Uri.parse('http://127.0.0.1:${server.port}');
  final wire = {
    'v': 1,
    'engineId': 'engine',
    'bridgeGeneration': 5,
    'requestId': _requestId,
    'sessionId': 'session',
    'callId': 'call',
    'tool': handoff ? 'mcp__phone__handoff' : 'mcp__phone__clipboard',
    'args': handoff ? {'reason': '请确认'} : {'set': 'private text'},
    'timeoutMs': handoff ? 600000 : 30000,
    'deadlineMs': handoff ? 601000 : 31000,
  };
  server.listen((request) async {
    await request.drain<void>();
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'request': wire, 'executionNonce': _nonce}));
    await request.response.close();
  });
  final auth = DshConnection(
    uri,
    cookie: DshCookie(name: 'dsh-auth-test', value: 'signed', authority: uri.authority),
  );
  final client = DshPhoneClient(auth, DshPhoneOwner.fromNative(_bootstrap(uri)));
  try {
    return await client.claim(DshPhoneRequest.fromJson(wire));
  } finally {
    client.close();
    auth.close(force: true);
    await server.close(force: true);
  }
}

void main() {
  _LocalSocketBinding();
  const channel = MethodChannel('dsh/runtime');
  const native = OhosPhoneNative();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('attach is explicitly enabled, and retirement carries only the original native scope', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'phoneAttach') return _bootstrap(Uri.parse('http://127.0.0.1:3080'));
      return null;
    });
    final owner = await native.attach();
    await native.retire(owner);
    expect(calls[0].arguments, {'enabled': true});
    expect(calls[1].method, 'phoneRetire');
    expect(calls[1].arguments, {'engineId': 'engine', 'bridgeGeneration': 5});
    expect(owner.toString(), isNot(contains(_ownerSecret)));
  });

  test('execution passes identity only and decodes the native result without substituting arguments', () async {
    final claim = await _claim();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'phoneExecute');
      expect(call.arguments, claim.nativeIdentity);
      expect((call.arguments as Map).containsKey('args'), isFalse);
      expect((call.arguments as Map).containsKey('owner'), isFalse);
      return {
        'status': 'succeeded',
        'effect': 'clipboard_written',
        'evidence': 'unknown',
        'dispatched': true,
        'code': 'clipboard_written',
        'message': '已写入',
      };
    });
    final result = await native.execute(claim);
    result.validateFor(claim.request);
    expect(result.effect, DshPhoneEffect.clipboardWritten);
  });

  test('only the explicit handoff method reports confirmation; check and cancel stay separate', () async {
    final claim = await _claim(handoff: true);
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, claim.nativeIdentity);
      return switch (call.method) {
        'phoneCheck' => {'pending': true, 'foreground': false, 'nowMs': 1001, 'deadlineMs': 601000},
        'phoneCancel' => {'dispatched': null},
        'phoneHandoffContinue' => {
          'status': 'succeeded',
          'effect': 'none',
          'evidence': 'user_confirmed',
          'dispatched': true,
          'code': 'user_confirmed',
          'message': '已继续',
        },
        _ => throw MissingPluginException(),
      };
    });
    final check = await native.check(claim);
    expect(check.pending, isTrue);
    expect(check.foreground, isFalse);
    expect(await native.cancel(claim), isNull);
    final result = await native.continueHandoff(claim);
    result.validateFor(claim.request);
    expect(calls, ['phoneCheck', 'phoneCancel', 'phoneHandoffContinue']);
  });

  test('platform errors never become invented success or disclose native exception details', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'ohos_phone_unavailable',
        message: _ownerSecret,
        details: {'private': _ownerSecret},
      );
    });
    await expectLater(
      native.attach(),
      throwsA(
        isA<DshPhoneException>()
            .having((e) => e.code, 'code', 'ohos_phone_unavailable')
            .having((e) => e.toString().contains(_ownerSecret), 'private details omitted', isFalse),
      ),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    await expectLater(native.attach(), throwsA(isA<DshPhoneException>().having((e) => e.code, 'code', 'unsupported')));
  });

  test('malformed native control data is rejected', () async {
    final claim = await _claim(handoff: true);
    messenger.setMockMethodCallHandler(channel, (call) async => {'dispatched': 'false'});
    await expectLater(native.cancel(claim), throwsA(isA<DshProtocolException>()));
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {'pending': true, 'foreground': true, 'nowMs': '1000', 'deadlineMs': 601000},
    );
    await expectLater(native.check(claim), throwsA(isA<DshProtocolException>()));
  });
}
