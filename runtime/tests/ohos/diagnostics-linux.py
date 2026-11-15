#!/usr/bin/env python3
"""Run actual ETS against real Linux files, plus the unmodified Dart channel consumer.

OH platform facts, Flutter transport and OH errno translation are explicit fixtures.
This is not ArkTS/SDK or device verification. No network or Dart package installation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--node', required=True)
p.add_argument('--typescript-prefix', required=True)
p.add_argument('--output', required=True)
p.add_argument('--dart')
p.add_argument('--zlib-addon', required=True)
a = p.parse_args()
repo = Path(__file__).resolve().parents[3]
out = Path(a.output).resolve()
out.mkdir(parents=True, exist_ok=False)
node, prefix = str(Path(a.node).resolve()), str(Path(a.typescript_prefix).resolve())
env = dict(os.environ, OHOS_TYPESCRIPT_PREFIX=prefix,
           OHOS_TEST_ZLIB_ADDON=str(Path(a.zlib_addon).resolve()),
           DIAGNOSTICS_CONSUMER_INPUT=str(out / 'consumer-input.json'),
           DIAGNOSTICS_TMP_PARENT=str(out), DIAGNOSTICS_FIFO_PATH=str(out / 'fixture-fifo'))
os.mkfifo(out / 'fixture-fifo', 0o600)
commands = []

def run(argv, name, extra_env=None):
    started = time.monotonic()
    try:
        result = subprocess.run(argv, cwd=repo, env=extra_env or env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
    except subprocess.TimeoutExpired as error:
        result = subprocess.CompletedProcess(argv, 124, (error.stdout or b'') + b'\nDiagnostic fixture exceeded its 180-second command limit.\n')
    (out / (name + '.log')).write_bytes(result.stdout)
    commands.append({'argv': argv, 'cwd': str(repo), 'exit': result.returncode,
                     'seconds': time.monotonic() - started})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    print(result.stdout.decode('utf-8', errors='replace'))
    return result.returncode

sources = [
    'app/ohos/entry/src/main/ets/runtime/PersistedRuntimeLog.ets',
    'app/ohos/entry/src/main/ets/plugins/DiagnosticsPlugin.ets',
    'app/ohos/entry/src/main/ets/plugins/OhosDeviceFacts.ets',
    'app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets',
    'app/ohos/entry/src/main/ets/runtime/RuntimeController.ets',
    'app/ohos/entry/src/main/ets/runtime/RuntimeLifecycle.ets',
    'app/ohos/entry/src/main/ets/runtime/RuntimeZip.ets',
    'app/ohos/entry/src/main/ets/runtime/OhosRuntimeArchive.ets',
    'app/ohos/entry/src/main/ets/runtime/OhosRuntimeStorage.ets',
    'tooling/ohos/tests/runtime-archive-fixture.mjs',
    'app/lib/diagnostics/diagnostics_channel.dart',
    'runtime/tests/ohos/diagnostics-fixture.mjs',
    'runtime/tests/ohos/diagnostics.test.mjs',
    'runtime/tests/ohos/diagnostics-cold.mjs',
    'runtime/tests/ohos/diagnostics-linux.py',
]
(out / 'inputs.json').write_text(json.dumps({
    'scope': 'Actual ETS + real Linux filesystem/fds; actual unmodified Dart consumer with explicit Flutter/Riverpod API stubs. NOT ArkTS/device.',
    'sources': {s: hashlib.sha256((repo / s).read_bytes()).hexdigest() for s in sources},
    'node': {'path': node, 'sha256': hashlib.sha256(Path(node).read_bytes()).hexdigest()},
    'typescriptPrefix': prefix,
    'zlibAddon': {'path': env['OHOS_TEST_ZLIB_ADDON'],
                  'sha256': hashlib.sha256(Path(env['OHOS_TEST_ZLIB_ADDON']).read_bytes()).hexdigest()},
}, indent=2) + '\n')
# This executor denies Node child-process creation, including the --test default
# subprocess isolation. node:test executes the same registered tests in-process.
status = run([node, 'runtime/tests/ohos/diagnostics.test.mjs'], 'node-test')
if status == 0:
    for mode in ['write', 'read']:
        status = run([node, 'runtime/tests/ohos/diagnostics-cold.mjs', mode, str(out / 'cold-root'), str(out)], 'cold-' + mode)
        if status != 0:
            break
if status == 0 and a.dart:
    stubs = out / 'dart-stubs'
    for name in ['flutter', 'flutter_riverpod']:
        (stubs / name / 'lib').mkdir(parents=True)
    (stubs / 'flutter/lib/services.dart').write_text('''
class MissingPluginException implements Exception {}
class MethodChannel {
  const MethodChannel(this.name);
  final String name;
  Future<Map<K,V>?> invokeMapMethod<K,V>(String method, [Object? arguments]) async => throw MissingPluginException();
  Future<List<T>?> invokeListMethod<T>(String method, [Object? arguments]) async => throw MissingPluginException();
}
''')
    (stubs / 'flutter_riverpod/lib/flutter_riverpod.dart').write_text('''
class Provider<T> { const Provider(T Function(Object) create); }
''')
    config = out / 'package_config.json'
    config.write_text(json.dumps({'configVersion': 2, 'packages': [
        {'name': name, 'rootUri': (stubs / name).as_uri() + '/', 'packageUri': 'lib/', 'languageVersion': '3.11'}
        for name in ['flutter', 'flutter_riverpod']
    ]}, indent=2) + '\n')
    consumer = (repo / 'app/lib/diagnostics/diagnostics_channel.dart').as_uri()
    driver = out / 'consumer.dart'
    driver.write_text('''
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'CONSUMER_URI';
void check(bool pass, String name) { if (!pass) throw StateError(name); print('PASS ' + name); }
class SnapshotChannel extends MethodChannel {
  SnapshotChannel(this.value): super('dsh/diagnostics');
  final Map<String,dynamic> value;
  String? method;
  Object? arguments;
  @override Future<Map<K,V>?> invokeMapMethod<K,V>(String name, [Object? args]) async {
    method=name; arguments=args; return (value['info'] as Map).cast<K,V>();
  }
  @override Future<List<T>?> invokeListMethod<T>(String name, [Object? args]) async {
    method=name; arguments=args; return (value['lines'] as List).cast<T>();
  }
}
Future<void> main(List<String> args) async {
  final input=jsonDecode(await File(args.single).readAsString()) as Map<String,dynamic>;
  final raw=SnapshotChannel(input), channel=DiagnosticsChannel(raw);
  final info=await channel.info();
  check(raw.method=='info' && info.app['versionCode']==42, 'actual native info maps into real Dart consumer');
  check(info.device['platform']=='ohos' && info.device['apiVersion']==26 && !info.device.containsKey('sdkInt') && !info.device.containsKey('android'), 'OH facts never become Android SDK metadata');
  check(info.manifest['files']==8 && info.manifest['uncompressedBytes']==116, 'actual validated manifest summary survives the codec');
  final lines=await channel.engineLog(maxBytes:12345);
  check(raw.method=='engineLog' && (raw.arguments as Map)['maxBytes']==12345 && lines.join('|')=='第一行|tail', 'engineLog method, byte argument and UTF-8 list');
  final empty=await const DiagnosticsChannel().info();
  check(empty.app.isEmpty && empty.device.isEmpty && (await const DiagnosticsChannel().engineLog()).isEmpty, 'missing plugin retains existing fallback');
  final redacted=NativeDiagnostics.fromMap({'voice': {'transcript':'hidden', 'audio':'hidden', 'recognizerAvailable':true, 'recentFailures':[{'code':42,'transcript':'hidden'}]}}).voice;
  check(!jsonEncode(redacted).contains('hidden') && redacted['recognizerAvailable']==true, 'real Dart voice allowlist rejects content');
}
'''.replace('CONSUMER_URI', consumer))
    dart = str(Path(a.dart).resolve())
    status = run([dart, '--packages=' + str(config), str(driver), str(out / 'consumer-input.json')], 'dart-consumer')
    (out / 'dart-inputs.json').write_text(json.dumps({
        'executable': dart, 'sha256': hashlib.sha256(Path(dart).read_bytes()).hexdigest(),
        'actualConsumer': consumer, 'fixtures': [str(stubs), str(driver), str(config)],
        'scope': 'Actual unmodified Dart consumer. MethodChannel and Provider are declared API doubles; no Flutter engine.'
    }, indent=2) + '\n')
(out / 'report.json').write_text(json.dumps({'exit': status, 'commands': len(commands),
    'notRun': ['HarmonyOS SDK / ArkTS', 'device lifecycle', 'real OH filesystem API', 'Flutter engine transport']}, indent=2) + '\n')
raise SystemExit(status)
