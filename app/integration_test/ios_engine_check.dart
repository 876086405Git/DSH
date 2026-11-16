// A build target of its own (flutter build ios -t), run on the Simulator by
// tooling/ios/engine-smoke/app-check.mjs: drives the engine through the real channels of
// the real app bundle, which the smoke test beside it can't, since that one has no app.
// Results go to a file in the app's temporary directory, which the Simulator shares with the
// Mac. They never include the token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _runtime = MethodChannel('dsh/runtime');
const _events = EventChannel('dsh/runtime/events');

final _reports = File('${Directory.systemTemp.path}/dsh-app-check.jsonl');
final _client = HttpClient();
const _toolMarker = 'iOS lifecycle tool fixture';

Future<void> _report(String step, Map<String, Object?> data) =>
    _reports.writeAsString('${jsonEncode({'step': step, ...data})}\n', mode: FileMode.append, flush: true);

/// A channel that never answers has to end in a report, not in a check that waits forever.
Future<T> _answer<T>(String method, Future<T> call, [Duration limit = const Duration(seconds: 90)]) =>
    call.timeout(limit, onTimeout: () => throw StateError('dsh/runtime $method: no answer after ${limit.inSeconds} s'));

Future<Map<Object?, Object?>> _status() async =>
    await _answer<Map<Object?, Object?>?>('getStatus', _runtime.invokeMapMethod<Object?, Object?>('getStatus')) ??
    const {};

Future<Map<Object?, Object?>> _until(String what, bool Function(Object? phase) done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (true) {
    final status = await _status();
    if (done(status['phase'])) return status;
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('$what: still ${status['phase']} after ${limit.inSeconds} s; error: ${status['error']}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<({int status, String? cookie})> _login(String baseUrl, String token) async {
  final request = await _client.getUrl(Uri.parse('$baseUrl/?token=$token'));
  request.followRedirects = false;
  final response = await request.close();
  await response.drain<void>();
  final cookie = response.cookies.where((c) => c.name.startsWith('dsh-auth-')).map((c) => '${c.name}=${c.value}');
  return (status: response.statusCode, cookie: cookie.isEmpty ? null : cookie.first);
}

Future<Map<String, Object?>> _engineJson(String baseUrl, String cookie, String endpoint) async {
  final request = await _client.getUrl(Uri.parse('$baseUrl/dsh-go/v1/$endpoint'));
  request.headers.set(HttpHeaders.cookieHeader, cookie);
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return {'status': response.statusCode, if (response.statusCode == 200) ...jsonDecode(body) as Map<String, Object?>};
}

Future<void> _start(String label) => _answer(
  label,
  _runtime.invokeMethod<void>('start', {'env': <String, String>{}, 'phoneStorage': false, 'visualReplies': true}),
);

Future<int> _foreground(String token, {int afterRevision = 0, Duration timeout = const Duration(seconds: 15)}) async {
  final limit = Stopwatch()..start();
  while (limit.elapsed < timeout) {
    final status = await _status();
    if (status['token'] != token) throw StateError('Foreground restored a different engine');
    final lifecycle = status['lifecycle'] as Map?;
    final revision = lifecycle?['revision'];
    if (lifecycle?['foreground'] == true &&
        lifecycle?['error'] == null &&
        revision is int &&
        revision > afterRevision &&
        lifecycle?['acknowledgedRevision'] == revision) {
      return revision;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('The running engine did not acknowledge the foreground observation');
}

class _BackgroundCycle with WidgetsBindingObserver {
  final paused = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !paused.isCompleted) {
      // Write before iOS can suspend Dart. The driver then activates this same app.
      _reports.writeAsStringSync('{"step":"background paused"}\n', mode: FileMode.append, flush: true);
      paused.complete();
    }
  }
}

Future<void> _round(DshClient client, String sessionId, String step) async {
  final events = StreamIterator(
    client.watch(sessionId, options: const WatchOptions(includeHostEvents: false, includeConnectionEvents: false)),
  );
  final clock = Stopwatch()..start();
  Future<bool> next() => events.moveNext().timeout(const Duration(seconds: 45) - clock.elapsed);
  try {
    while (true) {
      if (!await next()) throw StateError('$step could not subscribe to the session');
      if (events.current is SessionSnapshotEvent) break;
    }
    final sentRequest = await client.prompt(sessionId, '[DSH_IOS_SMOKE:app] $step');
    var dequeued = false;
    final streamed = StringBuffer();
    String? readCall;
    var toolRead = false;
    while (await next()) {
      switch (events.current) {
        case UserMessageEvent(:final requestId) when requestId != null:
          if (requestId == sentRequest) dequeued = true;
        case AssistantChunkEvent(chunk: TextDeltaChunk(:final text)):
          streamed.write(text);
        case ToolCallEvent(name: 'read', :final callId):
          readCall = callId;
        case ToolResultEvent(:final callId, :final message, :final isError) when callId == readCall:
          toolRead = !isError && message.text.contains(_toolMarker);
        case TurnEndedEvent(:final reason):
          if (!reason.isCompleted) {
            throw StateError(
              '$step ended with ${reason.kind}: ${reason.error ?? reason.cancelCause ?? 'no detail'} '
              '(dequeued=$dequeued streamed=${streamed.length} toolRead=$toolRead)',
            );
          }
          if (!dequeued || streamed.toString() != 'iOS app round complete.' || !toolRead) {
            throw StateError(
              '$step missed observations: dequeued=$dequeued streamed=${streamed.length} toolRead=$toolRead',
            );
          }
          await _report(step, {'dequeued': true, 'streamed': true, 'toolRead': true});
          return;
        default:
          break;
      }
    }
    throw StateError('$step ended before turn completion');
  } finally {
    await events.cancel();
  }
}

Future<void> _check() async {
  final clock = Stopwatch()..start();
  final seen = <String>{};
  var progress = 0;
  final events = _events.receiveBroadcastStream().listen((event) {
    final map = event as Map<Object?, Object?>;
    seen.add('${map['type']}');
    if (map['type'] == 'progress') progress++;
  });

  final root = await _answer('guestRoot', _runtime.invokeMethod<String>('guestRoot'));
  await _report('guest root', {'absolute': root?.startsWith('/') ?? false});
  final before = await _status();
  await _report('status', {
    'phase': before['phase'],
    'bundled': before['bundledVersion'],
    'node': before['nodeVersion'],
    'error': before['error'],
  });

  clock.reset();
  await _answer('install', _runtime.invokeMethod<void>('install'), const Duration(minutes: 10));
  final installed = await _status();
  await _report('install', {'ms': clock.elapsedMilliseconds, 'phase': installed['phase'], 'progressEvents': progress});

  clock.reset();
  await _answer('install', _runtime.invokeMethod<void>('install'), const Duration(minutes: 10));
  await _report('install again', {'ms': clock.elapsedMilliseconds, 'phase': (await _status())['phase']});

  clock.reset();
  await _start('start');
  final first = await _until('first start', (phase) => phase == 'running', const Duration(minutes: 4));
  final firstUrl = first['baseUrl']! as String;
  final firstToken = first['token']! as String;
  await _report('start', {
    'ms': clock.elapsedMilliseconds,
    'phase': first['phase'],
    'mode': first['currentExecutionMode'],
  });

  final login = await _login(firstUrl, firstToken);
  await _report('login', {'status': login.status, 'cookie': login.cookie != null});
  final capabilities = await _engineJson(firstUrl, login.cookie!, 'runtime-capabilities');
  await _report('capabilities', {
    'status': capabilities['status'],
    'v': capabilities['v'],
    'platform': capabilities['platform'],
    'shell': capabilities['shell'],
    'nodeScripts': capabilities['nodeScripts'],
    'publication': capabilities['publication'],
  });
  final workspace = '$root/root/workspace';
  await File('$workspace/ios-app-check.txt').writeAsString(_toolMarker);
  final modelUrl = await File('${_reports.parent.path}/dsh-app-check-model-url').readAsString();
  final client = await DshClient.connect(baseUri: Uri.parse(firstUrl), token: firstToken);
  late final String sessionId;
  const provider = 'custom-ios-app-check';
  const model = 'ohos-script';
  final keyRef = deriveProviderKeyRef(provider);
  try {
    await client.saveProvider(
      ProviderProfile(
        route: provider,
        api: ProviderApi.openaiCompletions.wire,
        baseUrl: modelUrl,
        apiKeyEnv: keyRef,
        models: const [
          ProviderModelSpec(id: model, contextWindow: 32768, maxTokens: 4096, extra: {'reasoningEfforts': false}),
        ],
      ),
    );
    await client.setProviderKey('local-simulator-fixture', ref: keyRef);
    sessionId = (await client.createSession(cwd: workspace, agentPreset: 'standard')).sessionId;
    await client.setModel(sessionId, provider: provider, model: model);
    // The first queued prompt can expose a closed gate even if HTTP startup works.
    await _round(client, sessionId, 'first round');
    final revision = await _foreground(firstToken);
    final cycle = _BackgroundCycle();
    WidgetsBinding.instance.addObserver(cycle);
    try {
      await _report('background ready', {});
      await cycle.paused.future.timeout(const Duration(seconds: 90));
    } finally {
      WidgetsBinding.instance.removeObserver(cycle);
    }
    await _foreground(firstToken, afterRevision: revision + 1, timeout: const Duration(seconds: 90));
    await _round(client, sessionId, 'foreground round');
  } finally {
    await client.close();
  }
  final logs = await _answer(
    'getLogSnapshot',
    _runtime.invokeMapMethod<Object?, Object?>('getLogSnapshot', {'lines': 50}),
  );
  await _report('logs', {'entries': (logs?['entries'] as List?)?.length, 'through': logs?['throughSeq']});

  clock.reset();
  await _answer('stop', _runtime.invokeMethod<void>('stop'));
  final stopped = await _until('stop', (phase) => phase == 'installed', const Duration(minutes: 1));
  await _report('stop', {'ms': clock.elapsedMilliseconds, 'phase': stopped['phase']});

  clock.reset();
  await _start('restart');
  final second = await _until('second start', (phase) => phase == 'running', const Duration(minutes: 4));
  final secondUrl = second['baseUrl']! as String;
  final secondToken = second['token']! as String;
  final again = await _login(secondUrl, secondToken);
  final stale = await _login(secondUrl, firstToken);
  await _report('restart', {
    'ms': clock.elapsedMilliseconds,
    'newToken': secondToken != firstToken,
    'login': again.status,
    'cookie': again.cookie != null,
    'oldTokenLogin': stale.status,
    'oldTokenCookie': stale.cookie != null,
  });
  final revision = await _foreground(secondToken);
  final control = await _engineJson(secondUrl, again.cookie!, 'lifecycle');
  final nativeRevision = (control['nativeHost'] as Map?)?['revision'];
  if (nativeRevision is! int || nativeRevision == revision || control['paused'] != false) {
    throw StateError('Restart did not acknowledge distinct native and observation revisions');
  }
  final restartedClient = await DshClient.connect(baseUri: Uri.parse(secondUrl), token: secondToken);
  try {
    await _round(restartedClient, sessionId, 'restart round');
  } finally {
    await restartedClient.close();
  }

  const performance = MethodChannel('dsh/performance');
  final snapshot = await _answer('snapshot', performance.invokeMapMethod<Object?, Object?>('snapshot'));
  await _report('performance', {'tier': (snapshot?['device'] as Map?)?['tier']});

  await _answer('stop', _runtime.invokeMethod<void>('stop'));
  final finalStop = await _until('second stop', (phase) => phase == 'installed', const Duration(minutes: 1));
  await _report('stop again', {'phase': finalStop['phase']});

  // A reset keeps what it's told to and nothing else, and the engine comes back from it.
  final kept = File('$root/root/.dsh/skills/dsh-app-check.txt')..createSync(recursive: true);
  final gone = File('$root/root/workspace/dsh-app-check.txt')..createSync(recursive: true);
  clock.reset();
  await _answer(
    'reset',
    _runtime.invokeMethod<void>('reset', {
      'keep': ['uiAndSkills'],
    }),
    const Duration(minutes: 3),
  );
  await _report('reset', {
    'ms': clock.elapsedMilliseconds,
    'phase': (await _status())['phase'],
    'kept': kept.existsSync(),
    'gone': !gone.existsSync(),
  });
  clock.reset();
  await _answer('install', _runtime.invokeMethod<void>('install'), const Duration(minutes: 10));
  await _report('install after reset', {'ms': clock.elapsedMilliseconds, 'phase': (await _status())['phase']});
  clock.reset();
  await _start('start after reset');
  final third = await _until('start after reset', (phase) => phase == 'running', const Duration(minutes: 4));
  final thirdLogin = await _login(third['baseUrl']! as String, third['token']! as String);
  await _report('start after reset', {'ms': clock.elapsedMilliseconds, 'login': thirdLogin.status});
  await _answer('stop', _runtime.invokeMethod<void>('stop'));
  final thirdStop = await _until('stop after reset', (phase) => phase == 'installed', const Duration(minutes: 1));
  await _report('stop after reset', {'phase': thirdStop['phase']});

  await events.cancel();
  await _report('events', {'seen': seen.toList()..sort()});
}

Future<void> main() async {
  // First, so that silence later can't be mistaken for Dart never having run.
  await _report('main', {});
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    await _check();
    await _report('done', {});
  } catch (error, stack) {
    final safeError = '$error'.replaceAllMapped(
      RegExp(r'([?&]token=|dsh-auth-[A-Za-z0-9_-]+=)[A-Za-z0-9_.-]+'),
      (match) => '${match[1]}<redacted>',
    );
    await _report('failed', {'error': safeError, 'stack': '$stack'.split('\n').take(6).join(' | ')});
  }
}
