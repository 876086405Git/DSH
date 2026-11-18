#!/usr/bin/env python3
"""OHOS-only permission overlay and private, post-build HAP signing."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

RESTRICTED = ('ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM', 'ohos.permission.READ_PASTEBOARD',
              # Needs AGC's agent reminder service before it does anything, so the first install stays without it.
              'ohos.permission.PUBLISH_AGENT_REMINDER')


class Refused(ValueError):
    """Our own message: it names a setting, never a value, so it's safe to print."""


def permissions(document, distribution):
    module = document['module']
    requested = [row for row in module.get('requestPermissions', []) if row['name'] not in RESTRICTED]
    entry = next(row for row in module['abilities'] if row['name'] == 'EntryAbility')
    modes = [mode for mode in entry.get('backgroundModes', []) if mode != 'taskKeeping']
    if distribution != 'store':
        if not any(row['name'] == 'ohos.permission.KEEP_BACKGROUND_RUNNING' for row in requested):
            requested.append({'name': 'ohos.permission.KEEP_BACKGROUND_RUNNING'})
        requested.append({'name': RESTRICTED[0]})
        requested.append({'name': RESTRICTED[1], 'reason': '$string:dsh_pasteboard_reason',
                          'usedScene': {'abilities': ['EntryAbility'], 'when': 'inuse'}})
        requested.append({'name': RESTRICTED[2]})
        modes.append('taskKeeping')
    module['requestPermissions'] = requested
    if modes:
        entry['backgroundModes'] = modes
    else:
        entry.pop('backgroundModes', None)
    return document


def material():
    names = ('KEYSTORE', 'CERTIFICATE', 'PROFILE', 'KEY_ALIAS', 'KEY_PASSWORD', 'STORE_PASSWORD')
    values = {}
    for name in names:
        value = os.environ.get('DSH_OHOS_SIGN_' + name)
        if not value:
            raise Refused('Set DSH_OHOS_SIGN_' + name)
        values[name] = value
    for name in ('KEYSTORE', 'CERTIFICATE', 'PROFILE'):
        path = Path(values[name]).expanduser().resolve()
        if path.is_relative_to(Path(__file__).resolve().parents[2]):
            raise Refused('Signing files must be outside the checkout')
        if not path.is_file():
            raise Refused('DSH_OHOS_SIGN_' + name + ' must name a file')
        values[name] = str(path)
    tool = os.environ.get('DSH_OHOS_SIGN_TOOL')
    if not tool or not Path(tool).is_file():
        raise Refused('Set DSH_OHOS_SIGN_TOOL to the SDK hap-sign-tool.jar')
    java = str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else shutil.which('java')
    if not java or not Path(java).is_file():
        raise Refused('Java is unavailable; set JAVA_HOME')
    return values, str(Path(tool).resolve()), java


def quote_java(value):
    # Java launcher @argfile syntax, not shell quoting. Newlines remain values.
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'


def sign(unsigned, output):
    values, tool, java = material()
    unsigned, output = unsigned.resolve(), output.resolve()
    if not unsigned.is_file() or unsigned == output:
        raise Refused('A separate existing unsigned HAP is required')
    output.parent.mkdir(parents=True, exist_ok=True)
    # No credentials or signing-tool output are written inside the checkout.
    with tempfile.TemporaryDirectory(prefix='dsh-hap-sign-', dir='/tmp') as temporary:
        work = Path(temporary)
        logging = work / 'log4j2.xml'
        logging.write_text('<Configuration status="OFF"><Loggers><Root level="OFF"/></Loggers></Configuration>')
        signed = work / 'signed.hap'
        args = ['-Dlog4j.configurationFile=' + str(logging), '-jar', tool, 'sign-app', '-mode', 'localSign',
                '-keyAlias', values['KEY_ALIAS'], '-keyPwd', values['KEY_PASSWORD'],
                '-keystoreFile', values['KEYSTORE'], '-keystorePwd', values['STORE_PASSWORD'],
                '-appCertFile', values['CERTIFICATE'], '-profileFile', values['PROFILE'],
                '-profileSigned', '1', '-signAlg', 'SHA256withECDSA', '-compatibleVersion', '26',
                '-inFile', str(unsigned), '-outFile', str(signed)]
        argfile = work / 'arguments'
        with os.fdopen(os.open(argfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
            stream.write('\n'.join(quote_java(value) for value in args))
        result = subprocess.run([java, '@' + str(argfile)], cwd=work, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode or not signed.is_file():
            raise Refused('HAP signing failed; check matching certificate, signed Profile, key alias and passwords')
        verify = [java, '-Dlog4j.configurationFile=' + str(logging), '-jar', tool, 'verify-app',
                  '-inFile', str(signed), '-outCertChain', str(work / 'chain.cer'), '-outProfile', str(work / 'profile.p7b')]
        result = subprocess.run(verify, cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            raise Refused('Signed HAP verification failed')
        shutil.copyfile(signed, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    overlay = sub.add_parser('permissions')
    overlay.add_argument('--distribution', choices=('debug', 'device', 'store'), required=True)
    overlay.add_argument('--input', type=Path, required=True)
    overlay.add_argument('--output', type=Path, required=True)
    sub.add_parser('check-signing')
    signer = sub.add_parser('sign')
    signer.add_argument('--input', type=Path, required=True)
    signer.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'permissions':
            result = permissions(json.loads(args.input.read_text()), args.distribution)
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        elif args.command == 'check-signing':
            material()
        else:
            sign(args.input, args.output)
    except Refused as error:
        parser.exit(1, 'hap-distribution: ' + str(error) + '\n')
    except (ValueError, OSError, KeyError, StopIteration):
        # Do not print exceptions from parsers/files/tools: inputs may include secrets.
        parser.exit(1, 'hap-distribution: configuration or signing failed; verify input paths, environment and matching signing materials\n')


if __name__ == '__main__':
    main()
