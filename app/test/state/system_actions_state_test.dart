// 系统操作's session as the app drives it: real DshPhoneSession and loopback HTTP,
// a stand-in native side and engine. It opens with the switch, the engine and the
// screen; a call already under way outlives leaving the screen; nothing replays.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/system_actions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Real loopback sockets, as the session insists; no external network is used.
class _LocalSocketBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _nonce = '55555555-5555-4555-8555-555555555555';
const _opened = DshPhoneResult(
  status: DshPhoneStatus.succeeded,
  effect: DshPhoneEffect.openedUi,
  evidence: DshPhoneEvidence.openedUi,
  dispatched: true,
  code: 'opened_ui',
  message: '已请求打开目标界面，未确认其中的操作完成。',
);
const _confirmed = DshPhoneResult(
  status: DshPhoneStatus.succeeded,
  effect: DshPhoneEffect.none,
  evidence: DshPhoneEvidence.userConfirmed,
  dispatched: true,
  code: 'user_confirmed',
  message: '用户已回到 DSH 并确认继续。',
);

class _Native implements DshPhoneNative {
  _Native(this.base);
  final Uri base;
  int attaches = 0, retires = 0, executed = 0, continued = 0, cancelled = 0;
  Object? attachError;
  bool pending = true;

  @override
  Future<DshPhoneOwner> attach() async {
    attaches++;
    if (attachError case final error?) throw error;
    return DshPhoneOwner.fromNative({
      'v': 1,
      'engineId': 'engine',
      'bridgeGeneration': attaches,
      'baseUrl': base.toString(),
      'owner': 'a' * 64,
    });
  }

  @override
  Future<void> retire(DshPhoneOwner owner) async => retires++;

  @override
  Future<DshPhoneResult> execute(DshPhoneClaim claim) async {
    executed++;
    return _opened;
  }

  @override
  Future<DshPhoneResult> continueHandoff(DshPhoneClaim claim) async {
    continued++;
    pending = false;
    return _confirmed;
  }

  @override
  Future<bool?> cancel(DshPhoneClaim claim) async {
    cancelled++;
    pending = false;
    return false;
  }

  @override
  Future<DshPhoneCheck> check(DshPhoneClaim claim) async =>
      DshPhoneCheck(pending: pending, foreground: true, nowMs: 1000, deadlineMs: claim.request.deadlineMs);
}

/// The engine's phone routes, enough of them: a queue of calls, long polls that
/// wait, and the receipts it got.
class _Engine {
  _Engine._(this.server) : uri = Uri.parse('http://127.0.0.1:${server.port}') {
    server.listen(_serve);
  }
  static Future<_Engine> start() async => _Engine._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;
  final Uri uri;
  final queued = <Map<String, Object?>>[];
  final results = <Map<String, Object?>>[];
  final cancels = <String>[];
  final _polls = <Completer<void>>[];
  bool dropReceipt = false;
  int claims = 0;

  DshConnection connection() => DshConnection(
    uri,
    cookie: DshCookie(name: 'dsh-auth-test', value: 'signed', authority: uri.authority),
  );

  void enqueue(String id, String tool, Map<String, Object?> args, int generation) {
    final handoff = tool == 'mcp__phone__handoff';
    queued.add({
      'v': 1,
      'engineId': 'engine',
      'bridgeGeneration': generation,
      'requestId': id,
      'sessionId': 'session',
      'callId': 'call-$id',
      'tool': tool,
      'args': args,
      'timeoutMs': handoff ? 600000 : 30000,
      'deadlineMs': handoff ? 601000 : 31000,
    });
    for (final poll in _polls.toList()) {
      if (!poll.isCompleted) poll.complete();
    }
  }

  Future<void> _serve(HttpRequest req) async {
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, Object?>;
    Object answer;
    switch (req.uri.path.split('/').last) {
      case 'next':
        if (queued.isEmpty) {
          final poll = Completer<void>();
          _polls.add(poll);
          await poll.future;
        }
        if (queued.isEmpty) return;
        final request = queued.first;
        // The session's owner moved on from the generation the call was queued for.
        if (request['bridgeGeneration'] != body['bridgeGeneration']) {
          request['bridgeGeneration'] = body['bridgeGeneration'];
        }
        answer = {'v': 1, 'request': request};
      case 'claim':
        claims++;
        answer = {'request': queued.removeAt(0), 'executionNonce': _nonce};
      case 'cancel':
        cancels.add(body['requestId'] as String);
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
          results.add(body);
          answer = {'accepted': true, 'result': body['result']};
        }
      default:
        throw StateError('unexpected request');
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(answer));
    await req.response.close();
  }

  Future<void> close() async {
    for (final poll in _polls) {
      if (!poll.isCompleted) poll.complete();
    }
    await server.close(force: true);
  }
}

class _Local extends LocalConnectionController {
  _Local(this.client);
  final DshClient? client;
  @override
  Future<HostConnection?> build() async => client == null ? null : HostConnection(client: client!, isLocal: true);

  void use(DshClient? next) => state = AsyncData(next == null ? null : HostConnection(client: next, isLocal: true));
}

class _Rig {
  _Rig(this.engine, this.native, this.container, this.local);
  final _Engine engine;
  final _Native native;
  final ProviderContainer container;
  final _Local local;

  SystemActionsController get actions => container.read(systemActionsProvider.notifier);
  SystemActionsState get state => container.read(systemActionsProvider);
}

Future<void> _until(bool Function() ok, {Duration within = const Duration(seconds: 4), String? what}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('never happened: ${what ?? ok}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<_Rig> _rig({
  bool on = true,
  Map<String, Object> prefs = const {},
  Object? attachError,
  bool connected = true,
}) async {
  SharedPreferences.setMockInitialValues({if (on) SystemActionsController.enabledKey: true, ...prefs});
  final engine = await _Engine.start();
  final native = _Native(engine.uri)..attachError = attachError;
  final client = DshClient(engine.connection());
  late final _Local local;
  final container = ProviderContainer(
    overrides: [
      systemActionsNativeProvider.overrideWithValue(native),
      localConnectionProvider.overrideWith(() => local = _Local(connected ? client : null)),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await engine.close();
    _setLifecycle(AppLifecycleState.resumed);
  });
  final rig = _Rig(engine, native, container, (container.read(localConnectionProvider), local).$2);
  container.read(systemActionsProvider);
  await container.read(localConnectionProvider.future);
  return rig;
}

void _setLifecycle(AppLifecycleState next) {
  // Through the states between, as the platform reports them.
  const order = [AppLifecycleState.resumed, AppLifecycleState.inactive, AppLifecycleState.hidden];
  final binding = WidgetsBinding.instance;
  final from = order.indexOf(binding.lifecycleState ?? AppLifecycleState.resumed);
  final to = order.indexOf(next);
  final step = to > from ? 1 : -1;
  for (var i = from; i != to; i += step) {
    binding.handleAppLifecycleStateChanged(order[i + step]);
  }
}

void main() {
  _LocalSocketBinding();
  setUp(() => _setLifecycle(AppLifecycleState.resumed));

  test('off, nothing attaches however long the engine has been up', () async {
    final r = await _rig(on: false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(r.native.attaches, 0);
    expect(r.state.link, SystemActionsLink.off);
    expect(r.state.loaded, isTrue);
  });

  test('without a connected engine it says so and attaches nothing', () async {
    final r = await _rig(connected: false);
    await _until(() => r.state.link == SystemActionsLink.waitingEngine);
    expect(r.native.attaches, 0);
  });

  test('on, one session claims a call; the log says the page opened and keeps no arguments', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    expect(r.native.attaches, 1);
    r.engine.enqueue('11111111-1111-4111-8111-111111111111', 'mcp__phone__open', {
      'url': 'https://secret.example/x',
    }, 1);
    await _until(() => r.state.log.isNotEmpty);
    expect(r.native.executed, 1);
    expect(r.engine.results, hasLength(1));
    expect(r.state.log.first.rawDecision, 'opened_ui');
    expect(r.state.log.first.tool, 'mcp__phone__open');
    final prefs = await SharedPreferences.getInstance();
    await _until(() => prefs.getStringList(SystemActionsController.logKey)?.length == 1);
    expect(prefs.getStringList(SystemActionsController.logKey)!.join(), isNot(contains('secret.example')));
    await r.actions.setEnabled(false);
    await _until(() => r.native.retires == 1);
    expect(r.state.link, SystemActionsLink.off);
  });

  test('leaving the screen idle retires the owner; coming back opens a new session', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    _setLifecycle(AppLifecycleState.hidden);
    await _until(() => r.native.retires == 1);
    await _until(() => r.state.link == SystemActionsLink.offScreen);
    _setLifecycle(AppLifecycleState.resumed);
    await _until(() => r.state.link == SystemActionsLink.ready);
    expect(r.native.attaches, 2);
  });

  test('a handoff outlives leaving the screen, and only continue succeeds', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    const id = '22222222-2222-4222-8222-222222222222';
    r.engine.enqueue(id, 'mcp__phone__handoff', {'reason': '请完成登录'}, 1);
    await _until(() => r.state.handoff != null);
    expect(r.state.handoff!.requestId, id);
    expect(r.engine.results, isEmpty, reason: 'waiting is not a result');

    _setLifecycle(AppLifecycleState.hidden);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(r.native.retires, 0, reason: 'the person went to do it; the prompt waits');
    expect(r.state.handoff, isNotNull);

    _setLifecycle(AppLifecycleState.resumed);
    expect(await r.actions.continueHandoff(), isTrue);
    await _until(() => r.state.handoff == null);
    expect(r.native.continued, 1);
    expect(r.engine.results.single['result'], containsPair('evidence', 'user_confirmed'));
    expect(r.state.log.first.rawDecision, 'continue');
  });

  test('a handoff still waiting when the app is away ends the session once it ends', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    r.engine.enqueue('33333333-3333-4333-8333-333333333333', 'mcp__phone__handoff', {'reason': 'x'}, 1);
    await _until(() => r.state.handoff != null);
    _setLifecycle(AppLifecycleState.hidden);
    // The native record expired or was revoked: no success is invented.
    r.native.pending = false;
    await _until(() => r.native.retires == 1);
    expect(r.native.continued, 0);
    expect(r.engine.results, isEmpty);
    expect(r.state.handoff, isNull);
    expect(r.state.log.first.rawDecision, 'stopped');
  });

  test('stop revokes the waiting call and leaves no success behind', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    const id = '44444444-4444-4444-8444-444444444444';
    r.engine.enqueue(id, 'mcp__phone__handoff', {'reason': 'x'}, 1);
    await _until(() => r.state.handoff != null);
    expect(await r.actions.stopHandoff(), isTrue);
    await _until(() => r.state.handoff == null);
    expect(r.native.cancelled, 1);
    expect(r.engine.cancels, [id]);
    expect(r.engine.results, isEmpty);
    expect(r.state.log.first.rawDecision, 'stopped');
  });

  test('the engine coming back on a new connection gets a new session and retires the old', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    r.local.use(null);
    await _until(() => r.native.retires == 1);
    await _until(() => r.state.link == SystemActionsLink.waitingEngine);
    r.local.use(DshClient(r.engine.connection()));
    await _until(() => r.state.link == SystemActionsLink.ready);
    expect(r.native.attaches, 2);
  });

  test('a lost receipt is an unknown outcome: reopened later, the old call never runs again', () async {
    final r = await _rig();
    await _until(() => r.state.link == SystemActionsLink.ready);
    r.engine.dropReceipt = true;
    r.engine.enqueue('55555555-5555-4555-8555-555555555555', 'mcp__phone__open', {'url': 'https://x'}, 1);
    await _until(() => r.state.log.isNotEmpty);
    expect(r.state.log.first.rawDecision, 'result_unknown');
    expect(r.state.link, SystemActionsLink.unavailable);
    expect(r.native.executed, 1);
    r.engine.dropReceipt = false;
    await _until(() => r.state.link == SystemActionsLink.ready, what: 'a retry after the wait');
    expect(r.native.executed, 1);
    expect(r.engine.claims, 1);
  });

  test('a build with no native side says so and doesn\'t keep trying', () async {
    final r = await _rig(attachError: const DshPhoneException('unsupported', 0));
    await _until(() => r.state.link == SystemActionsLink.unsupported);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(r.native.attaches, 1);
  });

  test('a refused open retries after a wait, and turning off ends the trying', () async {
    final r = await _rig(attachError: const DshPhoneException('ohos_phone_not_ready', 0));
    await _until(() => r.native.attaches >= 2, what: 'a second attempt');
    expect(r.state.link, SystemActionsLink.unavailable);
    await r.actions.setEnabled(false);
    final attempts = r.native.attaches;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(r.native.attaches, attempts);
    expect(r.state.link, SystemActionsLink.off);
  });

  test('phoneResultDecision only claims what the result says', () {
    DshPhoneResult result(DshPhoneStatus status, String code) => DshPhoneResult(
      status: status,
      effect: DshPhoneEffect.none,
      evidence: DshPhoneEvidence.unknown,
      dispatched: false,
      code: code,
      message: '',
    );
    expect(phoneResultDecision(_opened), 'opened_ui');
    expect(
      phoneResultDecision(
        const DshPhoneResult(
          status: DshPhoneStatus.succeeded,
          effect: DshPhoneEffect.reminderScheduled,
          evidence: DshPhoneEvidence.unknown,
          dispatched: true,
          code: 'reminder_scheduled',
          message: 'x',
        ),
      ),
      'reminder_scheduled',
    );
    expect(phoneResultDecision(_confirmed), 'continue');
    expect(phoneResultDecision(result(DshPhoneStatus.unknown, 'sdk_failed')), 'result_unknown');
    expect(phoneResultDecision(result(DshPhoneStatus.failed, 'unsupported')), 'unsupported');
    expect(phoneResultDecision(result(DshPhoneStatus.failed, 'permission_denied')), 'error');
    expect(phoneResultDecision(result(DshPhoneStatus.timedOut, 'deadline_expired')), 'timeout');
    expect(phoneResultDecision(result(DshPhoneStatus.cancelled, 'user_stopped')), 'stopped');
  });
}
