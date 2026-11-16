import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _id = '44444444-4444-4444-8444-444444444444';
const _nonce = '55555555-5555-4555-8555-555555555555';
const _written = DshPhoneResult(
  status: DshPhoneStatus.succeeded,
  effect: DshPhoneEffect.clipboardWritten,
  evidence: DshPhoneEvidence.unknown,
  dispatched: true,
  code: 'clipboard_written',
  message: '已写入',
);
const _confirmed = DshPhoneResult(
  status: DshPhoneStatus.succeeded,
  effect: DshPhoneEffect.none,
  evidence: DshPhoneEvidence.userConfirmed,
  dispatched: true,
  code: 'user_confirmed',
  message: '用户已确认',
);

// This test adapter is not native authorization evidence. HTTP uses real Linux
// sockets; the production data pump, ownership and timer paths execute unchanged.
class _Native implements DshPhoneNative {
  _Native(this.owner);
  final DshPhoneOwner owner;
  int attachments = 0, retired = 0, executed = 0, continued = 0, cancelled = 0;
  int continueAttempts = 0;
  bool throwAfterContinue = false;
  final confirmationReplyLost = Completer<void>();
  Completer<DshPhoneCheck>? delayedCheck;
  Completer<bool?>? delayedCancel;
  bool pending = true, foreground = true;
  int nowMs = 1000;
  Completer<DshPhoneResult>? execution;
  @override
  Future<DshPhoneOwner> attach() async {
    attachments++;
    return owner;
  }

  @override
  Future<void> retire(DshPhoneOwner value) async {
    expect(value.nativeScope, owner.nativeScope);
    retired++;
    pending = false;
  }

  @override
  Future<DshPhoneResult> execute(DshPhoneClaim claim) async {
    executed++;
    return execution == null ? _written : await execution!.future;
  }

  @override
  Future<DshPhoneResult> continueHandoff(DshPhoneClaim claim) async {
    continueAttempts++;
    if (!pending || !foreground) throw const DshPhoneException('not_foreground', 0);
    pending = false;
    continued++;
    if (throwAfterContinue) {
      confirmationReplyLost.complete();
      throw const DshPhoneException('platform_reply_lost', 0);
    }
    return _confirmed;
  }

  @override
  Future<bool?> cancel(DshPhoneClaim claim) async {
    cancelled++;
    if (delayedCancel != null) return await delayedCancel!.future;
    pending = false;
    return false;
  }

  @override
  Future<DshPhoneCheck> check(DshPhoneClaim claim) async => delayedCheck == null
      ? DshPhoneCheck(pending: pending, foreground: foreground, nowMs: nowMs, deadlineMs: claim.request.deadlineMs)
      : await delayedCheck!.future;
}

class _Fixture {
  _Fixture(this.server, this.handoff) {
    final uri = Uri.parse('http://127.0.0.1:${server.port}');
    native = _Native(
      DshPhoneOwner.fromNative({
        'v': 1,
        'engineId': 'engine',
        'bridgeGeneration': 1,
        'baseUrl': uri.toString(),
        'owner': 'a' * 64,
      }),
    );
    authenticated = DshConnection(
      uri,
      cookie: DshCookie(name: 'dsh-auth-test', value: 'signed', authority: uri.authority),
    );
    request = {
      'v': 1,
      'engineId': 'engine',
      'bridgeGeneration': 1,
      'requestId': _id,
      'sessionId': 'session',
      'callId': 'call',
      'tool': handoff ? 'mcp__phone__handoff' : 'mcp__phone__clipboard',
      'args': handoff ? {'reason': '请完成页面操作'} : {'set': 'hello'},
      'timeoutMs': handoff ? 600000 : 30000,
      'deadlineMs': handoff ? 601000 : 31000,
    };
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
      requests.add((req.uri.path, body));
      Object answer;
      switch (req.uri.path.split('/').last) {
        case 'next':
          if (nextCount++ > 0) return; // Real long poll; session.close owns its socket.
          answer = {'v': 1, 'request': request};
        case 'claim':
          answer = {'request': request, 'executionNonce': _nonce};
        case 'cancel':
          if (!cancelReceived.isCompleted) cancelReceived.complete();
          answer = {'accepted': true};
        case 'result':
          if (body['phase'] == 'waiting_user') {
            answer = {'accepted': true, 'phase': 'waiting_user'};
          } else {
            if (dropReceipt) {
              req.response.statusCode = 503;
              await req.response.close();
              return;
            }
            answer = {'accepted': true, 'result': body['result']};
          }
        default:
          throw StateError('unexpected request');
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(answer));
      await req.response.close();
    });
  }
  static Future<_Fixture> start({bool handoff = false}) async =>
      _Fixture(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), handoff);
  final HttpServer server;
  final bool handoff;
  late final _Native native;
  late final DshConnection authenticated;
  late final Map<String, Object?> request;
  final requests = <(String, Map<String, Object?>)>[];
  int nextCount = 0;
  bool dropReceipt = false;
  final cancelReceived = Completer<void>();
  Future<void> close() async {
    authenticated.close(force: true);
    await server.close(force: true);
  }
}

Future<(_Fixture, DshPhoneSession)> _open({bool handoff = false}) async {
  final f = await _Fixture.start(handoff: handoff);
  final session = await DshPhoneSession.open(f.authenticated, enabled: true, native: f.native);
  addTearDown(() async {
    await session.close();
    await f.close();
  });
  return (f, session);
}

void main() {
  test('disabled does not attach or start a request', () async {
    final f = await _Fixture.start();
    addTearDown(f.close);
    await expectLater(
      DshPhoneSession.open(f.authenticated, enabled: false, native: f.native),
      throwsA(isA<DshPhoneException>()),
    );
    expect(f.native.attachments, 0);
    expect(f.requests, isEmpty);
  });

  test('ordinary action is dispatched once and its native result is acknowledged once', () async {
    final (f, session) = await _open();
    final done = session.updates.firstWhere((s) => s.phase == DshPhonePhase.finished);
    final running = session.run();
    final result = await done.timeout(const Duration(seconds: 2));
    expect(result.accepted, isTrue);
    expect(result.result?.toJson(), _written.toJson());
    expect(f.native.executed, 1);
    expect(f.native.continued, 0);
    await session.close();
    await running;
    expect(f.native.retired, 1);
    expect(f.requests.where((r) => r.$2.containsKey('result')).length, 1);
  });

  test('lost receipt closes the owner and never replays the already dispatched action', () async {
    final (f, session) = await _open();
    f.dropReceipt = true;
    final events = <DshPhoneUpdate>[];
    final sub = session.updates.listen(events.add);
    await session.run().timeout(const Duration(seconds: 2));
    await sub.cancel();
    expect(f.native.executed, 1);
    expect(f.native.retired, 1);
    expect(events.any((s) => s.phase == DshPhonePhase.failed), isTrue);
    expect(events.any((s) => s.phase == DshPhonePhase.finished), isFalse);
    expect(f.requests.where((r) => r.$1.endsWith('/claim')).length, 1);
  });

  test('handoff is progress until the current explicit continue and old buttons then reject', () async {
    final (f, session) = await _open(handoff: true);
    final waiting = session.updates.firstWhere((s) => s.phase == DshPhonePhase.waitingUser && s.nowMs != null);
    final running = session.run();
    await waiting.timeout(const Duration(seconds: 2));
    expect(f.native.executed, 0);
    expect(f.native.continued, 0);
    expect(f.requests.where((r) => r.$2.containsKey('result')), isEmpty);
    await expectLater(session.continueHandoff('old-request'), throwsA(isA<DshPhoneException>()));
    expect(f.native.continued, 0);
    final result = await session.continueHandoff(_id);
    expect(result.accepted, isTrue);
    expect(result.result.evidence, DshPhoneEvidence.userConfirmed);
    await expectLater(session.continueHandoff(_id), throwsA(isA<DshPhoneException>()));
    expect(f.native.continued, 1);
    await session.close();
    await running;
  });

  test('native background refuses handoff continue without inventing success, stop revokes once', () async {
    final (f, session) = await _open(handoff: true);
    f.native.foreground = false;
    final waiting = session.updates.firstWhere((s) => s.phase == DshPhonePhase.waitingUser && s.foreground == false);
    final running = session.run();
    await waiting.timeout(const Duration(seconds: 2));
    await expectLater(session.continueHandoff(_id), throwsA(isA<DshPhoneException>()));
    expect(f.native.continued, 0);
    await session.stop(_id);
    expect(f.native.cancelled, 1);
    expect(f.requests.where((r) => r.$2.containsKey('result')), isEmpty);
    await session.close();
    await running;
  });

  test('native BOOTTIME expiry clears the prompt without user confirmation', () async {
    final (f, session) = await _open(handoff: true);
    f.native.pending = false;
    f.native.nowMs = 601001;
    final finished = session.updates.firstWhere((s) => s.code == 'no_longer_pending');
    final running = session.run();
    await finished.timeout(const Duration(seconds: 2));
    expect(f.native.continued, 0);
    await expectLater(session.continueHandoff(_id), throwsA(isA<DshPhoneException>()));
    await session.close();
    await running;
  });

  test('uncertain confirmation keeps the button locked until native pending state is known', () async {
    final (f, session) = await _open(handoff: true);
    final waiting = session.updates.firstWhere((s) => s.phase == DshPhonePhase.waitingUser && s.nowMs != null);
    final running = session.run();
    await waiting.timeout(const Duration(seconds: 2));
    f.native.throwAfterContinue = true;
    f.native.delayedCheck = Completer<DshPhoneCheck>();
    Object? firstError;
    final first = session
        .continueHandoff(_id)
        .then<void>(
          (_) {},
          onError: (Object error) {
            firstError = error;
          },
        );
    try {
      await f.native.confirmationReplyLost.future;
      await Future<void>.delayed(Duration.zero);
      await expectLater(session.continueHandoff(_id), throwsA(isA<DshPhoneException>()));
      expect(f.native.continueAttempts, 1, reason: 'an uncertain first confirmation cannot invoke native again');
    } finally {
      f.native.delayedCheck!.complete(
        const DshPhoneCheck(pending: false, foreground: true, nowMs: 1000, deadlineMs: 601000),
      );
      await first;
      await session.close();
      await running;
    }
    expect(firstError, isA<DshPhoneException>());
    expect(f.native.continued, 1);
  });

  test('lost local cancel reply still reaches the Node cancellation within a bounded interval', () async {
    final (f, session) = await _open(handoff: true);
    final waiting = session.updates.firstWhere((s) => s.phase == DshPhonePhase.waitingUser && s.nowMs != null);
    final running = session.run();
    await waiting.timeout(const Duration(seconds: 2));
    f.native.delayedCancel = Completer<bool?>();
    final stopping = session.stop(_id).then<void>((_) {}, onError: (Object _) {});
    try {
      await f.cancelReceived.future.timeout(const Duration(seconds: 6));
    } finally {
      f.native.delayedCancel!.complete(false);
      await session.close();
      await stopping;
      await running;
    }
    expect(f.native.cancelled, 1);
  });

  test('closing from the synchronous waiting update creates no callback timer', () async {
    final timers = <Timer>[];
    final origins = <Timer, String>{};
    addTearDown(() {
      for (final timer in timers) {
        timer.cancel();
      }
    });
    await runZoned(
      () async {
        final (f, session) = await _open(handoff: true);
        final sub = session.updates.listen((s) {
          if (s.phase == DshPhonePhase.waitingUser) unawaited(session.close());
        });
        await session.run().timeout(const Duration(seconds: 2));
        await sub.cancel();
        expect(f.native.continued, 0);
        expect(f.native.retired, 1);
        // HttpClient has its own periodic pool bookkeeping. Bind this check
        // to callback timers, rather than misreporting unrelated SDK timers.
        final owned = timers.where((timer) => origins[timer]!.contains('DshPhoneSession._pump')).toList();
        print(
          jsonEncode({
            'createdPeriodicTimers': origins.values.toList(),
            'callbackTimers': owned.length,
            'activeCallbackTimers': owned.where((timer) => timer.isActive).length,
          }),
        );
        expect(owned, isEmpty, reason: 'no callback timer may be created after synchronous close');
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          origins[timer] = StackTrace.current.toString();
          return timer;
        },
      ),
    );
  });
}
