#!/usr/bin/env python3
"""Compile and execute the real host libpython probe; no simulated Python process."""
import argparse
import os
from pathlib import Path
import subprocess
import sysconfig
import sys
import json
import hashlib
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--node-headers', type=Path, required=True)
parser.add_argument('--production', action='store_true')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
compiler = shutil.which('cc')
node = shutil.which('node')
openssl = shutil.which('openssl') if args.production else None
if not compiler or not node or (args.production and not openssl):
    raise SystemExit('BLOCKED: host C compiler, Node, or production TLS fixture OpenSSL is missing')
args.output.mkdir(parents=True, exist_ok=True)
lib = Path(sysconfig.get_config_var('LIBDIR')) / sysconfig.get_config_var('LDLIBRARY')
if not lib.exists():
    lib = Path(sysconfig.get_config_var('LIBDIR')) / sysconfig.get_config_var('INSTSONAME')
if not lib.exists():
    lib = Path(sys.base_prefix) / 'lib' / sysconfig.get_config_var('INSTSONAME')
if not lib.exists():
    raise SystemExit('BLOCKED: host Python shared library is missing')
addon = args.output.resolve() / 'python-probe.node'
defines = []
commands = []
def execute(command, **kwargs):
    commands.append(list(map(str, command)))
    return subprocess.run(command, check=True, **kwargs)

if args.production:
    cert, key = args.output.resolve() / 'tls-cert.pem', args.output.resolve() / 'tls-key.pem'
    system_cert, system_key = args.output.resolve() / 'system-cert.pem', args.output.resolve() / 'system-key.pem'
    for ca_cert, ca_key, subject in ((cert, key, 'bundled-root'), (system_cert, system_key, 'system-root')):
        execute([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=' + subject, '-addext', 'subjectAltName=IP:127.0.0.1',
                        '-keyout', str(ca_key), '-out', str(ca_cert)], capture_output=True)
    certificates = args.output.resolve() / 'system-certs'
    certificates.mkdir(exist_ok=True)
    name = subprocess.check_output([openssl, 'x509', '-in', str(system_cert), '-hash', '-noout'], text=True).strip()
    (certificates / (name + '.0')).write_bytes(system_cert.read_bytes())
    defines.append('-DDSH_PYTHON_SSL_CERT_DIR=' + json.dumps(str(certificates)))
execute([compiler, '-shared', '-fPIC', '-std=c11',
                *defines,
                '-I' + str(args.node_headers), '-I' + sysconfig.get_path('include'),
                str(root / ('runtime/ohos/python/host.c' if args.production else 'runtime/ohos/python/probe.c')), str(lib),
                '-Wl,-rpath,' + str(lib.parent), '-lpthread', '-ldl', '-lm', '-o', str(addon)])
env = {**os.environ, 'OHOS_PYTHON_PROBE': str(addon)}
if args.production:
    # An existing empty store is still a negative trust input, without making
    # the same Node process's system-CA scan warn about a nonexistent directory.
    empty_certs = args.output.resolve() / 'empty-default-certs'
    empty_certs.mkdir(exist_ok=True)
    empty_ca = args.output.resolve() / 'empty-default-ca.pem'
    empty_ca.write_bytes(b'')
    env['SSL_CERT_DIR'] = str(empty_certs)
    env['SSL_CERT_FILE'] = str(empty_ca)
    env['OHOS_PYTHON_TLS_CERT'] = str(cert)
    env['OHOS_PYTHON_TLS_KEY'] = str(key)
    env['OHOS_PYTHON_SYSTEM_TLS_CERT'] = str(system_cert)
    env['OHOS_PYTHON_SYSTEM_TLS_KEY'] = str(system_key)
    extension = args.output.resolve() / ('_dsh_link_probe' + sysconfig.get_config_var('EXT_SUFFIX'))
    # Deliberately no libpython link: distro extensions resolve its public ABI
    # from the embedding process. Builtin-only Python distributions hid this.
    execute([compiler, '-shared', '-fPIC', '-std=c11', '-I' + sysconfig.get_path('include'),
             str(root / 'runtime/tests/ohos/python-link-probe.c'), '-o', str(extension)])
    env['OHOS_PYTHON_HOST_CONFIG'] = json.dumps({'addon': str(addon), 'home': sys.base_prefix, 'caFile': str(cert), 'paths': [sysconfig.get_path('stdlib'), str(Path(sysconfig.get_path('stdlib')) / 'lib-dynload'), str(args.output.resolve())]})
    tests = ['python-production.test.mjs', 'python-owner.test.mjs', 'python-native-symbols.test.mjs']
else:
    tests = ['python-native.test.cjs', 'python-host.test.mjs']
test_command = [node, '--test', *[str(root / 'runtime/tests/ohos' / name) for name in tests]]
(args.output / 'host-inputs.json').write_text(json.dumps({'scope': 'Host shared-library test inputs; not OHOS cross-compiled libpython or device proof',
    'pythonExecutable': sys.executable, 'pythonVersion': sys.version, 'pythonHome': sys.base_prefix,
    'pythonInclude': sysconfig.get_path('include'), 'pythonStdlib': sysconfig.get_path('stdlib'),
    'pythonLibrary': str(lib), 'pythonLibrarySha256': hashlib.sha256(lib.read_bytes()).hexdigest(),
    'nodeHeaders': str(args.node_headers.resolve()), 'compileCommands': commands, 'testCommand': test_command,
    'certificateDirectories': {'compiledSystemStore': str(certificates), 'initialEmptyStore': str(empty_certs)} if args.production else None,
    'nativeLinkProbeSha256': hashlib.sha256(extension.read_bytes()).hexdigest() if args.production else None,
    'addonSha256': hashlib.sha256(addon.read_bytes()).hexdigest()}, indent=2) + '\n')
execute(test_command, env=env)
