// A build target of its own (flutter build ios -t), run on the Simulator by
// tooling/ios/engine-smoke/app-check.mjs: drives the engine through the real channels of
// the real app bundle, which the smoke test beside it can't, since that one has no app.
// Results go to a file in the app's temporary directory, which the Simulator shares with the
// Mac. They never include the token.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _runtime = MethodChannel('dsh/runtime');
const _events = EventChannel('dsh/runtime/events');

final _reports = File('${Directory.systemTemp.path}/dsh-app-check.jsonl');
final _client = HttpClient();

Future<void> _report(String step, Map<String, Object?> data) =>
    _reports.writeAsString('${jsonEncode({'step': step, ...data})}\n', mode: FileMode.append, flush: true);

/// A channel that never answers has to end in a report, not in a check that waits forever.
Future<T> _answer<T>(String method, Future<T> call, [Duration limit = const Duration(seconds: 90)]) =>
    call.timeout(limit, onTimeout: () => throw StateError('dsh/runtime $method: no answer after ${limit.inSeconds} s'));

Future<Map<Object?, Object?>> _status() async =>
    await _answer<Map<Object?, Object?>?>('getStatus', _runtime.invokeMapMethod<Object?, Object?>('getStatus')) ?? const {};

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

Future<Map<String, Object?>> _capabilities(String baseUrl, String cookie) async {
  final request = await _client.getUrl(Uri.parse('$baseUrl/dsh-go/v1/runtime-capabilities'));
  request.headers.set(HttpHeaders.cookieHeader, cookie);
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return {'status': response.statusCode, if (response.statusCode == 200) ...jsonDecode(body) as Map<String, Object?>};
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
  await _answer('start', _runtime.invokeMethod<void>('start', {'env': <String, String>{}, 'phoneStorage': false, 'visualReplies': true}));
  final first = await _until('first start', (phase) => phase == 'running', const Duration(minutes: 4));
  final firstUrl = first['baseUrl']! as String;
  final firstToken = first['token']! as String;
  await _report('start', {'ms': clock.elapsedMilliseconds, 'phase': first['phase'], 'mode': first['currentExecutionMode']});

  final login = await _login(firstUrl, firstToken);
  await _report('login', {'status': login.status, 'cookie': login.cookie != null});
  final capabilities = await _capabilities(firstUrl, login.cookie!);
  await _report('capabilities', {
    'status': capabilities['status'],
    'v': capabilities['v'],
    'platform': capabilities['platform'],
    'shell': capabilities['shell'],
    'nodeScripts': capabilities['nodeScripts'],
    'publication': capabilities['publication'],
  });
  final logs = await _answer('getLogSnapshot', _runtime.invokeMapMethod<Object?, Object?>('getLogSnapshot', {'lines': 50}));
  await _report('logs', {'entries': (logs?['entries'] as List?)?.length, 'through': logs?['throughSeq']});

  clock.reset();
  await _answer('stop', _runtime.invokeMethod<void>('stop'));
  final stopped = await _until('stop', (phase) => phase == 'installed', const Duration(minutes: 1));
  await _report('stop', {'ms': clock.elapsedMilliseconds, 'phase': stopped['phase']});

  clock.reset();
  await _answer('start', _runtime.invokeMethod<void>('start', {'env': <String, String>{}, 'phoneStorage': false, 'visualReplies': true}));
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
  await _answer('reset', _runtime.invokeMethod<void>('reset', {'keep': ['uiAndSkills']}), const Duration(minutes: 3));
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
  await _answer('start', _runtime.invokeMethod<void>('start', {'env': <String, String>{}, 'phoneStorage': false, 'visualReplies': true}));
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
    await _report('failed', {'error': '$error', 'stack': '$stack'.split('\n').take(6).join(' | ')});
  }
}
