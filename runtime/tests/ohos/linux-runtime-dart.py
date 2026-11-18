#!/usr/bin/env python3
"""Execute the actual OH Linux Dart consumer with an explicit MethodChannel boundary."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SERVICES = '''class MissingPluginException implements Exception {}
class PlatformException implements Exception {
  PlatformException({required this.code, this.message, this.details});
  final String code; final String? message; final Object? details;
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
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    service = out / 'flutter/lib/services.dart'
    service.parent.mkdir(parents=True)
    service.write_text(SERVICES)
    config = out / 'package_config.json'
    config.write_text(json.dumps({'configVersion': 2, 'packages': [
        {'name': 'flutter', 'rootUri': (out / 'flutter').as_uri() + '/', 'packageUri': 'lib/', 'languageVersion': '3.3'}
    ]}, indent=2) + '\n')
    files = [ROOT / 'app/lib/runtime/ohos_linux_runtime.dart', Path(__file__).with_name('linux-runtime-probe.dart')]
    for source in files:
        shutil.copy2(source, out / source.name)
    argv = [str(args.dart.resolve()), '--enable-asserts', '--packages=' + str(config), str(out / 'linux-runtime-probe.dart')]
    result = subprocess.run(argv, capture_output=True, text=True)
    (out / 'stdout.log').write_text(result.stdout)
    (out / 'stderr.log').write_text(result.stderr)
    (out / 'RESULT.json').write_text(json.dumps({'argv': argv, 'exitCode': result.returncode,
        'scope': 'actual Dart consumer; explicit Flutter services boundary; not Flutter engine/OH SDK/device',
        'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files + [Path(__file__), service]}},
        ensure_ascii=False, indent=2) + '\n')
    print(result.stdout, end='')
    print(result.stderr, end='')
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
