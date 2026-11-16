#!/usr/bin/env python3
"""Execute the real Dart MethodChannel switch with only Flutter transport doubled."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--dart', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
flutter = out / 'flutter'
(flutter / 'lib').mkdir(parents=True)
(flutter / 'lib/services.dart').write_text('''
class MissingPluginException implements Exception {}
class PlatformException implements Exception {
  PlatformException({required this.code, this.message, this.details});
  final String code;
  final String? message;
  final Object? details;
}
class MethodChannel {
  const MethodChannel(this.name);
  final String name;
  static Future<Object?> Function(String, String, Object?)? handler;
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final call = handler;
    if (call == null) throw MissingPluginException();
    return await call(name, method, arguments) as T?;
  }
}
''')
config = out / 'package_config.json'
config.write_text(json.dumps({'configVersion': 2, 'packages': [{
    'name': 'flutter', 'rootUri': flutter.as_uri() + '/',
    'packageUri': 'lib/', 'languageVersion': '3.11',
}]}, indent=2) + '\n')
channel = repo / 'app/lib/runtime/authorized_workspaces_channel.dart'
model = repo / 'app/lib/runtime/authorized_workspaces.dart'
driver = out / 'channel.dart'
driver.write_text('''
import 'dart:convert';
import 'package:flutter/services.dart';
import 'CHANNEL_URI';
import 'MODEL_URI';

void check(bool value, String label) {
  if (!value) throw StateError(label);
}
Future<void> main() async {
  final calls = <Map<String, Object?>>[];
  MethodChannel.handler = (name, method, arguments) async {
    check(name == 'dsh/authorized-workspaces', 'exact channel');
    calls.add({'method': method, 'arguments': arguments});
    if (method == 'capabilities') {
      return {'protocol': 1, 'engineAttached': false, 'folderSelection': true,
        'folderAuthorization': true, 'persistencePermission': 'unknown'};
    }
    return {'protocol': 1, 'engineAttached': false, 'bootId': 'fixture', 'workspaces': []};
  };
  final client = MethodAuthorizedWorkspaces();
  final attached = await client.attach('exact-id', userGesture: true);
  check(!attached.engineAttached, 'transport success does not attach the engine');
  await client.attach('exact-id', userGesture: false);
  check(jsonEncode(calls) == jsonEncode([
    {'method': 'attach', 'arguments': {'id': 'exact-id', 'userGesture': true}},
    {'method': 'attach', 'arguments': {'id': 'exact-id', 'userGesture': false}},
  ]), 'attach must preserve opaque identity and the actual gesture flag');
  await client.capabilities();
  await client.list();
  await client.select(userGesture: false);
  await client.persist('exact-id', userGesture: true);
  await client.activate('exact-id', userGesture: true);
  await client.deactivate('exact-id', userGesture: true);
  await client.revoke('exact-id', userGesture: true);
  await client.forget('exact-id', userGesture: true);
  await client.cancel();
  check(calls.map((c) => c['method']).join(',') ==
    'attach,attach,capabilities,list,select,persist,activate,deactivate,revoke,forget,cancel',
    'existing methods remain routed');
  final details = {'reason': 'needsReauthorization'};
  MethodChannel.handler = (_, _, _) async => throw PlatformException(
    code: 'permission_denied', message: 'reselect', details: details);
  try {
    await client.attach('exact-id', userGesture: true);
    throw StateError('platform failure was swallowed');
  } on AuthorizedWorkspaceFailure catch (error) {
    check(error.code == 'permission_denied' && error.message == 'reselect' &&
      identical(error.details, details), 'platform error identity');
  }
  MethodChannel.handler = null;
  check(!(await client.capabilities()).available, 'missing-plugin capability fallback');
  try {
    await client.attach('exact-id', userGesture: true);
    throw StateError('missing plugin was swallowed');
  } on AuthorizedWorkspaceFailure catch (error) {
    check(error.code == 'unsupported', 'missing plugin attach error');
  }
  print(jsonEncode({'status': 'PASS_SCOPED', 'actualDartChannelCalls': calls.length,
    'engineAttached': false, 'platformErrors': 2,
    'scope': 'Actual production Dart switch and decoder; MethodChannel is the only test double; no Flutter engine or device.'}));
}
'''.replace('CHANNEL_URI', channel.as_uri()).replace('MODEL_URI', model.as_uri()))
command = [str(args.dart.resolve()), '--packages=' + str(config), str(driver)]
result = subprocess.run(command, cwd=repo, capture_output=True, text=True, timeout=60)
(out / 'stdout.log').write_text(result.stdout)
(out / 'stderr.log').write_text(result.stderr)
(out / 'RESULT.json').write_text(json.dumps({
    'command': command, 'exitCode': result.returncode,
    'sourceSha256': {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [channel, model, Path(__file__).resolve()]},
    'scope': 'Dart production channel execution; only the Flutter transport API is doubled',
}, indent=2) + '\n')
print(result.stdout, end='')
print(result.stderr, end='')
raise SystemExit(result.returncode)
